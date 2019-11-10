{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module PMLB
  ( SetType (..),
    Config (Config),
    defaultConfig,
    url,
    file,
    tsep,
    bsep,
    runBS,
    runLine,
    runProducer,
    runRows,
    toLineStream,
    bytes,
    bsCheck,
    rangeFold,
    runFold,
    discreteFreqCounts,
  )
where

import Control.Category (id, (>>>))
import qualified Control.Foldl as L
import Control.Lens hiding (Unwrapped, Wrapped, elements, runFold, (|>))
import Control.Monad.Managed (Managed, managed, runManaged, with)
import qualified Data.Attoparsec.ByteString.Char8 as AC
import qualified Data.Attoparsec.ByteString.Streaming as S
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Streaming.Char8 as B
import qualified Data.ByteString.Streaming.HTTP as HTTP
import Data.Generics.Labels ()
import qualified Data.Map as Map
import Data.Scientific
import Data.String (String)
import qualified Data.Text as Text
import NumHask.Space
import Options.Generic (ParseField)
import PMLB.Csv as C
import PMLB.DataSets
import qualified Pipes as P
import qualified Pipes.Prelude as P
import Protolude
import qualified Streaming.Prelude as S
import Streaming.Zip (gunzip)
import System.Directory (doesFileExist)
import Test.QuickCheck (Arbitrary (..), elements, frequency)

data SetType
  = Classification
  | Regression
  deriving (Show, Generic, Eq, Read, ParseField)

data Config
  = Config
      { urlRoot :: Text,
        dataType :: SetType,
        dataSet :: Text,
        suffixRemote :: Text,
        -- | data is stored uncompressed locally to fit in with Frames methods
        -- since a csv file is needed locally to discover types, remote data is always cached.
        suffixLocal :: Text,
        localCache :: Text,
        csep :: Char,
        -- | length of the continuating bytestream to report on an error
        errStream :: Int,
        -- | maximum number of lines when splitting the stream
        maxLines :: Int,
        -- | number of rows to get initial statistical calcs with
        firstRows :: Int
      }
  deriving (Show, Generic, Eq)

defaultConfig :: Config
defaultConfig =
  Config
    "https://github.com/EpistasisLab/penn-ml-benchmarks/raw/master/datasets"
    Classification
    "Hill_Valley_with_noise"
    ".tsv.gz"
    ".csv"
    "./other"
    '\t'
    500
    100000
    100

url :: Config -> FilePath
url cfg =
  cfg ^. #urlRoot <> "/"
    <> Text.toLower (show (cfg ^. #dataType))
    <> "/"
    <> cfg ^. #dataSet
    <> "/"
    <> cfg ^. #dataSet
    <> cfg ^. #suffixRemote
    & Text.unpack

file :: Config -> FilePath
file cfg =
  cfg ^. #localCache
    <> "/"
    <> Text.toLower (show $ cfg ^. #dataType)
    <> "/"
    <> cfg ^. #dataSet
    <> cfg ^. #suffixLocal
      & Text.unpack

tsep :: Config -> Text
tsep cfg = cfg ^. #csep & Text.singleton

bsep :: Config -> ByteString
bsep cfg = cfg ^. #csep & C.singleton

-- | resources
withUrlStream :: String -> Managed (B.ByteString IO ())
withUrlStream u =
  managed $ \f -> do
    req <- HTTP.parseRequest u
    man <- HTTP.newManager HTTP.tlsManagerSettings
    HTTP.withHTTP req man $ \resp -> f (HTTP.responseBody resp)

withFileAppend :: FilePath -> Managed Handle
withFileAppend f = managed (withFile f AppendMode)

withFileStream :: MonadIO m => FilePath -> Managed (B.ByteString m ())
withFileStream fp = managed $ \f -> withFile fp ReadMode (f . B.hGetContents)

toCache :: Config -> IO ()
toCache cfg =
  runManaged $ do
    inUrl <- withUrlStream (url cfg)
    outFile <- withFileAppend (file cfg)
    inUrl & gunzip & B.hPut outFile & liftIO

cacheUrl :: Config -> IO ()
cacheUrl cfg = do
  e <- file cfg & doesFileExist
  unless e (toCache cfg)

withStream :: Config -> Managed (B.ByteString IO ())
withStream cfg = do
  liftIO $ cacheUrl cfg
  withFileStream (file cfg)

-- * continuation processing

-- | bytestring stream continuation
--
-- >>> bytes & runBS defaultConfig
-- 839165
runBS :: Config -> (B.ByteString IO () -> IO r) -> IO r
runBS cfg = with (withStream cfg)

-- | take a ByteString (A streaming library bytestring) and make a text stream separated by the usual end-of-line conventions.
-- this will break if the dataset includes linebreaks within a quoted text field
toLineStream :: Monad m => Int -> B.ByteString m r -> S.Stream (S.Of Text) m ()
toLineStream n s =
  s
    & B.lines
    & B.denull
    & S.take n
    & S.mapped B.toStrict -- the strict wall of pain
    & S.map decodeUtf8
    & S.filter (/= "")

-- | text line continuation
--
-- >>> (S.length >>> fmap S.fst') & runLine defaultConfig
-- 1213
runLine :: Config -> (S.Stream (S.Of Text) IO () -> IO r) -> IO r
runLine cfg s = (toLineStream (cfg ^. #maxLines) >>> s) & runBS cfg

-- | pipes line continuation
--
-- >>> runProducer defaultConfig P.length
-- 1213
runProducer :: Config -> (P.Producer Text IO () -> IO r) -> IO r
runProducer cfg p = (P.unfoldr S.next >>> p) & runLine cfg

-- | taking a parser, run a stream computation over n rows
--
-- >>> runRows defaultConfig 2 doubles S.toList_ & fmap (fmap (take 4))
-- [[39.02,36.49,38.2,38.85],[1.83,1.71,1.77,1.77]]
runRows :: Config -> Int -> (Char -> AC.Parser a) -> (S.Stream (S.Of a) IO () -> IO r) -> IO r
runRows cfg n p s = runBS cfg (streamCsv_ HasHeader n (cfg ^. #csep) p s)

-- | taking a parser, run a foldl over n rows
--
-- >>> runFold defaultConfig 1000 doubles rangeFold & fmap (drop 95)
-- [Range 0.89 112037.22,Range 0.89 115110.42,Range 0.86 116431.96,Range 0.91 113291.96,Range 0.89 114533.76,Range 0.0 1.0]
runFold :: Config -> Int -> (Char -> AC.Parser a) -> L.Fold a b -> IO b
runFold cfg n p f = runBS cfg (streamCsv_ HasHeader n (cfg ^. #csep) p (L.purely S.fold f >>> fmap S.fst'))

-- * various computation streams

-- | number of raw bytes
bytes :: B.ByteString IO () -> IO Int
bytes s = s & B.length & fmap S.fst'

instance Arbitrary Config where
  arbitrary =
    frequency
      [ ( 1,
          (\x -> defaultConfig & #dataType .~ Classification & #dataSet .~ x)
            <$> elements classificationNames
        ),
        ( 1,
          (\x -> defaultConfig & #dataType .~ Regression & #dataSet .~ x)
            <$> elements regressionNames
        )
      ]

-- | records of a csv as raw bytestrings
--
-- >>> (Right recs) <- runBS defaultConfig (bsAll defaultConfig)
-- >>> recs & all (length >>> (== 101))
-- True
--
-- >>> recs & length
-- 1213
bsAll ::
  Monad m =>
  Config ->
  B.ByteString m () ->
  m (Either (Text, ByteString) [[ByteString]])
bsAll cfg bs = do
  res <- parseCsvBody (csep cfg) (cfg ^. #errStream) C.record bs
  case res of
    Left err -> pure $ Left err
    Right (bss, _) -> pure $ Right bss

-- check bytestring for rectangularity
--
-- >>> bsCheck defaultConfig 100 (B.fromLazy "a\tb\tc\nd\te\tf\n")
-- Right (2,3)
--
-- >>>  bsCheck defaultConfig 100 (B.fromLazy "a\tb\tc\nd\te\n")
-- Left "non-equal record length"
--
-- >>> bsCheck defaultConfig 100 (B.fromLazy "")
-- Left "empty: "
--
-- >>> bsCheck defaultConfig 100 (B.fromLazy "\n")
-- Right (1,1)
--
bsCheck :: (Monad m) => Config -> Int -> B.ByteString m r -> m (Either Text (Int, Int))
bsCheck cfg n bs = do
  res <- parseCsv_ NoHeader n (csep cfg) C.record bs
  case res of
    [] -> "empty: prolly a parser issue" & Left & pure
    (x : xs) ->
      if all (\y -> length y == length x) xs
        then (length xs + 1, length x) & Right & pure
        else "non-equal record lengths" & Left & pure

-- | an issue with the PMLB datasets is that it is not immediately obvious which columns are:
--
-- - Int: Discrete but an Ord instance, and/or where magnitude is meaningful
-- - Categorical: not an Ord and magnitude of the Int isn't meaningful
-- - Binary: No way of telling if 0,1 values are boolean until you have all the rows
data V = Continuous Float | Discrete Int | Binary Bool deriving (Show)

-- | convert a Scientific value to a V
toV :: Scientific -> V
toV s = case floatingOrInteger s of
  Left r -> Continuous r
  Right i -> Discrete i

isDiscrete :: V -> Bool
isDiscrete (Discrete _) = True
isDiscrete (Continuous _) = False
isDiscrete (Binary _) = False

-- fromNames :: [Text] -> Map.Map Text Int

rangeFold :: (Ord a) => L.Fold [a] [Range a]
rangeFold = L.Fold step [] id
  where
    step [] as = (\a -> Range a a) <$> as
    step rs as = zipWith (<>) rs $ (\a -> Range a a) <$> as

discreteCols :: Config -> Int -> IO [Int]
discreteCols cfg n = do
  rs <- runBS cfg (parseCsv_ HasHeader n (cfg ^. #csep) scis)
  rs & transpose & fmap (all (isDiscrete . toV))
    & zip [0 ..]
    & filter snd
    & fmap fst
    & pure

countFold :: (Ord a) => L.Fold a (Map.Map a Int)
countFold = L.Fold step Map.empty identity
  where
    step x a = Map.insertWith (+) a 1 x

countsFold :: (Ord a) => Int -> L.Fold [a] [Map.Map a Int]
countsFold n = L.Fold step (replicate n Map.empty) identity
  where
    step = zipWith (\x a -> Map.insertWith (+) a 1 x)

nrows :: Config -> IO Int
nrows cfg =
  runBS cfg (parseCsvHeader_ (cfg ^. #csep)) & fmap length

discreteFreqCounts :: Config -> Int -> IO [(Text, [(Scientific, Int)])]
discreteFreqCounts cfg topn = do
  nr <- nrows cfg
  dc <- discreteCols cfg (cfg ^. #firstRows)
  freqs <- runFold cfg (cfg ^. #maxLines) (cols (const AC.scientific) nr dc) (countsFold nr)
  (Left hs, _) <- runBS cfg (S.parse (cols field nr dc (cfg ^. #csep)))
  pure $ zip (decodeUtf8 <$> hs) $ take topn . sortOn (Down . snd) . Map.toList <$> freqs
