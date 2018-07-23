module Main (
  main,
) where

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

import System.Directory (removeDirectoryRecursive)

import qualified KeyTests

import qualified TestJson
import qualified TestXML
import qualified TestWire
import qualified TestBinary
import qualified TestPaillier
import qualified TestTxAsset
import qualified TestStorage
import qualified TestDB
import qualified TestTx
import qualified TestScript
import qualified TestNetwork

import qualified DB.LevelDB as DB
import qualified Reference

-------------------------------------------------------------------------------
-- test Suite
-------------------------------------------------------------------------------

suite :: TestTree
suite = testGroup "Test Suite" [
  -- Database Tests
    TestDB.dbTests
  , TestDB.postgresDatatypeTests
  , TestDB.storageBackendURITests

  -- Cryptography Tests
  , KeyTests.keyTests

  -- JSON Serialize Tests
  , TestJson.jsonTests

  -- XML Serialize Tests
  , TestXML.xmlTests

  -- Script parser/pretty printer Tests
  , TestScript.scriptPropTests

  -- Script compilation and evaluation Tests
  , TestScript.scriptCompilerTests

  -- Binary Serialization Tests
  , TestBinary.binaryTests

  -- Pallier Encryption Tests
  , TestPaillier.paillierTests

  -- Wire Protocol Tests
  , TestWire.wireTests

  -- Asset Transaction Testes
  , TestTxAsset.txAssetTests

  -- Contract Storage Tests
  , TestStorage.storageTests

  -- Transaction Serialization Tests
  , TestTx.cerealTests

  -- Network Tests
  , TestNetwork.networkTests
  ]

-------------------------------------------------------------------------------
-- Test Runner
-------------------------------------------------------------------------------

main :: IO ()
main = defaultMain suite
