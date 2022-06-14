{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module: Chainweb.Test.Pact.SQLite
-- Copyright: Copyright © 2022 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.Test.Pact.SQLite
( tests
) where

import Control.Concurrent.MVar
import Control.Monad
import Control.Monad.Trans.State

import Data.Bifunctor
import qualified Data.ByteString as B
import qualified Data.ByteString.Short as BS
import Data.Coerce
import qualified Data.Hash.SHA3 as SHA3
import qualified Data.List as L
import Data.String

import Pact.Types.SQLite

import System.IO.Unsafe
import System.Random (genByteString, getStdRandom)

import Test.Hash.SHA3
import Test.Tasty
import Test.Tasty.HUnit

-- internal modules

import Chainweb.Pact.Backend.Types
import Chainweb.Test.Utils

-- TODO: we should consider submitting all queries for a file in a single sql statememt?
-- We could turn the file contents into a table and implement the checks in SQL
--
tests :: TestTree
tests = withInMemSQLiteResource $ \dbIO ->
    withResource (dbIO >>= newMVar) mempty $ \dbVarIO ->
        let run = runMsgTest dbVarIO []
            runMonte = runMonteTest dbVarIO []

            -- Split input
            runVar = runMsgTest dbVarIO [1,2,17]
            runMonteVar = runMonteTest dbVarIO [1,2,17]

        in testGroup "SQL Tests"
            [ testGroup "sha3 single argument"
                [ testGroup "ShortMsg"
                    [ testCase "-" $ run 0 sha3_256ShortMsg
                    , testCase "224" $ run 224 sha3_224ShortMsg
                    , testCase "256" $ run 256 sha3_256ShortMsg
                    , testCase "384" $ run 384 sha3_384ShortMsg
                    , testCase "512" $ run 512 sha3_512ShortMsg
                    ]
                , testGroup "LongMsg"
                    [ testCase "-" $ run 0 sha3_256LongMsg
                    , testCase "224" $ run 224 sha3_224LongMsg
                    , testCase "256" $ run 256 sha3_256LongMsg
                    , testCase "384" $ run 384 sha3_384LongMsg
                    , testCase "512" $ run 512 sha3_512LongMsg
                    ]
                , testGroup "Monte"
                    [ testCase "-" $ runMonte 0 sha3_256Monte
                    , testCase "224" $ runMonte 224 sha3_224Monte
                    , testCase "256" $ runMonte 256 sha3_256Monte
                    , testCase "384" $ runMonte 384 sha3_384Monte
                    , testCase "512" $ runMonte 512 sha3_512Monte
                    ]
                ]
            , testGroup "sha3 multiple arguments"
                [ testGroup "ShortMsg"
                    [ testCase "-" $ runVar 0 sha3_256ShortMsg
                    , testCase "224" $ runVar 224 sha3_224ShortMsg
                    , testCase "256" $ runVar 256 sha3_256ShortMsg
                    , testCase "384" $ runVar 384 sha3_384ShortMsg
                    , testCase "512" $ runVar 512 sha3_512ShortMsg
                    ]
                , testGroup "LongMsg"
                    [ testCase "-" $ runVar 0 sha3_256LongMsg
                    , testCase "224" $ runVar 224 sha3_224LongMsg
                    , testCase "256" $ runVar 256 sha3_256LongMsg
                    , testCase "384" $ runVar 384 sha3_384LongMsg
                    , testCase "512" $ runVar 512 sha3_512LongMsg
                    ]
                , testGroup "Monte"
                    [ testCase "-" $ runMonteVar 0 sha3_256Monte
                    , testCase "224" $ runMonteVar 224 sha3_224Monte
                    , testCase "256" $ runMonteVar 256 sha3_256Monte
                    , testCase "384" $ runMonteVar 384 sha3_384Monte
                    , testCase "512" $ runMonteVar 512 sha3_512Monte
                    ]
                ]
            , withAggTable dbVarIO 512 128 $ \tbl -> testGroup "sha3 aggregation"
                [ testCase "-" $ testAgg 0 dbVarIO tbl
                , testCase "224" $ testAgg 224 dbVarIO tbl
                , testCase "256" $ testAgg 256 dbVarIO tbl
                , testCase "384" $ testAgg 384 dbVarIO tbl
                , testCase "512" $ testAgg 512 dbVarIO tbl
                ]
            , testCase "sha3 msgTable" $ msgTableTest dbVarIO
            ]

runMsgTest :: IO (MVar SQLiteEnv) -> [Int] -> Int -> MsgFile -> IO ()
runMsgTest dbVarIO splitArg n f = do
    dbVar <- dbVarIO
    withMVar dbVar $ \db -> do
        msgAssert (\_ a b -> a @?= b) (sqliteSha3 db n splitArg) f

runMonteTest :: IO (MVar SQLiteEnv) -> [Int] -> Int -> MonteFile -> IO ()
runMonteTest dbVarIO splitArg n f = do
    dbVar <- dbVarIO
    withMVar dbVar $ \db -> do
        monteAssert (\_ a b -> a @?= b) (sqliteSha3 db n splitArg) f

-- -------------------------------------------------------------------------- --
-- Incremental use in a query:

msgTableTest :: IO (MVar SQLiteEnv) -> IO ()
msgTableTest dbVarIO = do
    msgTable dbVarIO "msgShort256" sha3_256ShortMsg
    dbVar <- dbVarIO
    withMVar dbVar $ \db -> do
        rows <- qry_ (_sConn db) query [RInt]
        h <- case rows of
            [[SInt r]] -> return r
            [[x]] -> error $ "unexpected return value: " <> show x
            [a] -> error $ "unexpected number of result fields: " <> show (length a)
            a -> error $ "unexpected number of result rows: " <> show (length a)
        h @?= 0
  where
    query = "SELECT sum(sha3(substr(msg,1,len)) != md) FROM msgShort256;"


msgTable :: IO (MVar SQLiteEnv) -> String -> MsgFile -> IO ()
msgTable dbVarIO name msgFile = do
    dbVar <- dbVarIO
    withMVar dbVar $ \db -> do
        exec_ (_sConn db) ("CREATE TABLE " <> tbl <> " (len INT, msg BLOB, md BLOB)")
        forM_ (_msgVectors msgFile) $ \i -> do
            let l = fromIntegral $ _msgLen i
            exec'
                (_sConn db)
                ("INSERT INTO " <> tbl <> " VALUES (?, ?, ?)")
                [SInt l, SBlob (_msgMsg i), SBlob (_msgMd i)]
  where
    tbl = fromString name

-- -------------------------------------------------------------------------- --
-- Aggregate functions
--
-- split a large input accross table rows

withAggTable
    :: IO (MVar SQLiteEnv)
    -> Int
    -> Int
    -> (IO (String, [B.ByteString]) -> TestTree)
    -> TestTree
withAggTable dbVarIO rowCount chunkSize =
    withResource createAggTable (const $ return ())
  where
    tbl = "bytesTbl"
    createAggTable = do
        dbVar <- dbVarIO
        withMVar dbVar $ \db -> do
            input <- getStdRandom $ runState $
                replicateM rowCount $ state (genByteString chunkSize)
            exec_ (_sConn db) ("CREATE TABLE " <> fromString tbl <> " (bytes BLOB)")
            forM_ input $ \i ->
                exec' (_sConn db) ("INSERT INTO " <> fromString tbl <> " VALUES(?)") [SBlob i]
            return (tbl, input)

testAgg :: Int -> IO (MVar SQLiteEnv) -> IO (String, [B.ByteString]) -> IO ()
testAgg n dbVarIO tblIO = do
    dbVar <- dbVarIO
    (tbl, input) <- first fromString <$> tblIO
    withMVar dbVar $ \db -> do
        rows <- qry_ (_sConn db) ("SELECT " <> sha n <> "(bytes) FROM " <> tbl) [RBlob]
        h <- case rows of
            [[SBlob r]] -> return r
            [[x]] -> error $ "unexpected return value: " <> show x
            [a] -> error $ "unexpected number of result fields: " <> show (length a)
            a -> error $ "unexpected number of result rows: " <> show (length a)

        h @?= hash n (mconcat input)
  where
    hash 0 = hashToByteString . SHA3.hashByteString @SHA3.Sha3_256
    hash 224 = hashToByteString . SHA3.hashByteString @SHA3.Sha3_224
    hash 256 = hashToByteString . SHA3.hashByteString @SHA3.Sha3_256
    hash 384 = hashToByteString . SHA3.hashByteString @SHA3.Sha3_384
    hash 512 = hashToByteString . SHA3.hashByteString @SHA3.Sha3_512
    hash x = error $ "unsupported SHA3 digest size: " <> show x

    sha :: IsString a => Monoid a => Int -> a
    sha 0 = "sha3a"
    sha i = "sha3a_" <> fromString (show i)

hashToByteString :: SHA3.Hash a => Coercible a BS.ShortByteString => a -> B.ByteString
hashToByteString = BS.fromShort . coerce

-- -------------------------------------------------------------------------- --
-- SHA3 Implementation

sqliteSha3 :: SQLiteEnv -> Int -> [Int] -> B.ByteString -> B.ByteString
sqliteSha3 db n argSplit arg = unsafePerformIO $ do
    rows <- qry (_sConn db) queryStr params [RBlob]
    case rows of
        [[SBlob r]] -> return r
        [[x]] -> error $ "unexpected return value: " <> show x
        [a] -> error $ "unexpected number of result fields: " <> show (length a)
        a -> error $ "unexpected number of result rows: " <> show (length a)
  where
    argN = length argSplit
    argStr = fromString $ L.intercalate "," $ replicate (argN + 1) "?"

    queryStr = "select " <> sha n <> "(" <> argStr <> ")"

    params = go argSplit arg

    go [] l = [SBlob l]
    go (h:t) bs = let (a,b) = B.splitAt h bs in SBlob a : go t b

    sha :: IsString a => Monoid a => Int -> a
    sha 0 = "sha3"
    sha i = "sha3_" <> fromString (show i)

