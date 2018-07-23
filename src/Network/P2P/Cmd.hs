{-|

Intraprocess protocol used to mediate communication between P2P and RPC
interfaces. This process is _not_ designed to interact with external nodes,
and sends/receives messages to/from local processes only.

--}

{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Network.P2P.Cmd (
  Cmd(..),
  CmdResult(..),

  ExternalCmd(..),

  TestCmd(..),
  handleTestCmd,

  commTasksProc,
  commTasksProc',

  newTransaction,
  nsendTransaction,

) where

import Protolude hiding (put, get, newChan)

import Control.Distributed.Process.Lifted
import Control.Distributed.Process.Lifted.Class

import qualified Data.Map as Map

import Data.Binary (Binary)
import qualified Data.Text as Text

import Node.Peer
import NodeState
import SafeString as SS
import qualified Account
import Address (Address, AAccount, rawAddr)
import qualified Asset
import qualified DB
import qualified Encoding
import qualified Ledger
import qualified Hash
import qualified Contract
import qualified Key
import qualified Transaction as Tx
import qualified Transaction.RandomGen as TxGen
import qualified Validate as V
import qualified Utils
import Network.Utils
import Network.P2P.Service (Service(..), ServiceSpec(..))
import Network.P2P.SignedMsg (nsendPeerSigned, nsendPeersSigned, nsendPeersManySigned)
import Network.P2P.Controller (doDiscover)
import qualified Network.P2P.Logging as Log
import qualified Network.P2P.Message as M

-------------------------------------------------------------------------------
-- Service Definition
-------------------------------------------------------------------------------

data ExternalCmd = ExternalCmd
  deriving (Show, Generic, Binary)

instance Service ExternalCmd where
  serviceSpec _ = Worker externalCmdProc

-------------------------------------------------------------------------------
-- P2P Commands
-------------------------------------------------------------------------------

data Cmd
  = Test TestCmd      -- ^ Test commands
  | Transaction Tx.Transaction -- ^ Transaction
  | ListAccounts
  | ListAssets
  | ListContracts
  | Discover
  | Reconnect
  | ListPeers
  | AddPeer Text
  | Ping
  | PingPeer Text
  deriving (Eq, Show, Generic, Binary)

-- | A datatype defining Cmds that should only be able to be
-- executed when the node is booted in a test state with '--test'
data TestCmd

  -- | Cmd to reset mempool of entire network.
  = ResetMemPool

  -- | Cmd to reset node DB
  | ResetDB
    { address   :: Address AAccount             -- ^ Address of pubkey used to sign this tx
    , signature :: Encoding.Base64PByteString   -- ^ Signature of address to prove possesion of priv key
    }

  -- | Query a node's internal state
  | QueryNodeState

  -- | Tell a node to generate a random valid transaction
  | GenerateTransaction

  -- | Tell a node to discover peers with the given node ids
  | DiscoverPeers [NodeId]

  deriving (Eq, Show, Generic, Binary, Typeable)

data CmdResult
  = CmdSuccess
  | Accounts [Account.Account]
  | Assets [Asset.Asset]
  | Contracts [Contract.Contract]
  | PeerList Peers
  | CmdFail Text
  | GeneratedTransaction (Either Tx.InvalidTransaction ())
  | TestData
      { lastBlockHash :: Hash.Hash Encoding.Base16ByteString
      , ledgerState   :: Ledger.World
      }
  deriving (Show, Eq, Generic, Binary, Typeable)-- XXX

-------------------------------------------------------------------------------
-- P2P ExternalCmd Proc
-------------------------------------------------------------------------------

-- | Process that receives commands from external processes like the RPC server
-- and/or the Console process. These commands get evaluated and then a CmdResult
-- is returned
externalCmdProc
  :: forall m. (MonadProcessBase m, DB.MonadReadWriteDB m)
  => NodeT m ()
externalCmdProc =
    forever $ onConsoleMsg =<< expect
  where
    onConsoleMsg :: (Cmd, SendPort CmdResult) -> NodeT m ()
    onConsoleMsg (cmd, sp) = do
      Log.info $ "Recieved Cmd:\n\t" <> show cmd
      res <- handleCmd cmd
      sendChan sp res


-- | Issue a Cmd to the "tasks" process and wait for a CmdResult
-- Note: This function is blocking and will wait forever for a response. Use
-- `commCmdProc'` to specify a timeout for how long to wait for a response.
commTasksProc :: MonadProcessBase m => Cmd -> m CmdResult
commTasksProc cmd = do
  (sp,rp) <- newChan
  nsend (show ExternalCmd) (cmd, sp)
  receiveChan rp

-- | Issue a Cmd to the "tasks" process and wait for a CmdResult
-- Note: This function is blocking and will wait `timeout` ms for a response.
commTasksProc' :: MonadProcessBase m => Int -> Cmd -> m (Maybe CmdResult)
commTasksProc' timeout cmd = do
  (sp,rp) <- newChan
  nsend (show ExternalCmd) (cmd, sp)
  receiveChanTimeout timeout rp

-------------------------------------------------------------------------------
-- P2P Command handlers
-------------------------------------------------------------------------------

-- | This function handles Cmd messages originating from either the shell
-- or the RPC interface which translates RPCCmds into Cmds
handleCmd
  :: (MonadProcessBase m, DB.MonadReadWriteDB m)
  => Cmd
  -> NodeT m CmdResult
handleCmd cmd =
  case cmd of
    ListAccounts -> do
      world <- NodeState.getLedger
      return $ Accounts $ Map.elems $ Ledger.accounts world
    ListAssets -> do
      world <- NodeState.getLedger
      return $ Assets $ Map.elems $ Ledger.assets world
    ListContracts -> do
      world <- NodeState.getLedger
      return $ Contracts $ Map.elems $ Ledger.contracts world
    Transaction tx -> do
      nsendTransaction M.Messaging tx
      return CmdSuccess
    Test testCmd   -> do
      testNode <- NodeState.isTestNode
      if testNode
        then handleTestCmd testCmd
        else return $ CmdFail "Node is not in test mode. Command ignored."
    Discover -> do
      peers <-  getPeerNodeIds
      mapM_ doDiscover peers
      return CmdSuccess
    Reconnect -> do
      pid <- getSelfPid
      reconnect pid
      return CmdSuccess
    Ping -> do
      peers <- getPeerNodeIds
      nodeId <- liftP extractNodeId
      forM_ peers $ \peer -> do
        let msg = SS.fromBytes' (toS nodeId)
        nsendPeerSigned peer M.Messaging $ M.Ping msg
      return CmdSuccess
    (PingPeer host) -> do
      nodeId <- extractNodeId
      let msg = SS.fromBytes' (toS nodeId)
      eNodeId <- liftIO $ mkNodeId (toS host)
      case eNodeId of
        Left err     -> Log.warning err
        Right nodeId -> nsendPeerSigned nodeId M.Messaging $ M.Ping msg

      return CmdSuccess
    ListPeers -> do
      peers <- NodeState.getPeers
      return $ PeerList peers
    (AddPeer host) -> do
      eNodeId <- liftIO $ mkNodeId (toS host)
      case eNodeId of
        Left err     -> do
          Log.warning err
          return $ CmdFail err
        Right nodeId -> do
          doDiscover nodeId
          return CmdSuccess


handleTestCmd
  :: (MonadProcessBase m, DB.MonadReadWriteDB m)
  => TestCmd
  -> NodeT m CmdResult
handleTestCmd testCmd =
  case testCmd of
    ResetMemPool -> do
      Log.info "Resetting MemPool..."
      NodeState.resetTxMemPool
      return CmdSuccess

    ResetDB addr sig' -> do
      case Key.decodeSig sig' of
        Left err -> Log.warning $ show err
        Right sig -> do

          let addrBS = rawAddr addr
          nodeAcc  <- NodeState.askAccount
          nodeKeys <- NodeState.askKeyPair

          if not (Key.verify (fst nodeKeys) sig addrBS)
            then do
              let errMsg = Text.intercalate "\n    "
                    [ "Error resetting DB:"
                    , "Could not verify the signature of the address sent in ResetDB TestCmd."
                    , "Please sign the address associated with the uplink node account using the uplinks node's private key"
                    ]
              Log.warning errMsg
            else do
              -- Wipe DB entirely, keeping Node Keys and Node Acc
              eRes <- lift $ first show <$> DB.resetDB
              case eRes of
                Left err -> Log.critical $
                  "Failed to reset Databases on ResetDB TestCmd: " <> err
                Right _ ->
                  -- Wipe entire node state except for peers (fresh world contains
                  -- preallocated accounts specified in config)
                  NodeState.resetNodeState
      return CmdSuccess

    QueryNodeState -> do
      ledger <- getLedger
      lastBlock <- getLastBlock
      let hashedBlock = Hash.toHash lastBlock :: Hash.Hash Encoding.Base16ByteString
      pure $ TestData hashedBlock ledger

    GenerateTransaction -> do
      Log.info "Received GenerateTransaction msg"
      addr <- askSelfAddress
      Log.info (show addr :: Text)
      (pubKey, privKey) <- askKeyPair
      world <- pollAccountInLedger (100 * 1000000) 0 addr =<< getLedger
      tx <- liftIO $ TxGen.genRandTransaction addr privKey world
      Log.info $ "Transaction generated: " <> Utils.ppShow tx
      pure $ GeneratedTransaction (V.verifyTransaction world tx)

    DiscoverPeers nids -> do
      Log.info "Received 'DiscoverPeer' msg"
      mapM_ doDiscover nids
      return CmdSuccess


pollAccountInLedger
  :: (MonadProcessBase m, DB.MonadReadWriteDB m)
  => Int
  -> Int
  -> Address AAccount
  -> Ledger.World
  -> NodeT m Ledger.World
pollAccountInLedger timeout accDelay addr world =
  case Ledger.lookupAccount addr world of
    Left _    ->
      if accDelay >= timeout
        then pure world
        else do
          let delay = 1000000
          liftIO $ threadDelay delay
          liftIO $ putText "Can't find self address in ledger"
          newWorld <- getLedger
          pollAccountInLedger timeout (accDelay + delay) addr newWorld
    Right acc -> pure world

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

nsendTransaction
  :: (MonadProcessBase m, Service s)
  => s
  -> Tx.Transaction
  -> NodeT m ()
nsendTransaction service tx = do
  let message = M.SendTx (M.SendTransactionMsg tx)
  -- Don't need to `nsendCapable` because incapable
  -- peers simply won't process the transaction
  nsendPeersSigned service message

nsendTransactionMany
  :: (MonadProcessBase m, Service s)
  => s
  -> [Tx.Transaction]
  -> NodeT m ()
nsendTransactionMany service txs = do
  let messages = [M.SendTx (M.SendTransactionMsg tx) | tx <- txs]
  -- Don't need to `nsendCapable` because incapable
  -- peers simply won't process the transaction
  nsendPeersManySigned service messages

-- | Creates new transaction using current node account and private key
newTransaction
  :: MonadIO m
  => Tx.TransactionHeader
  -> NodeT m Tx.Transaction
newTransaction txHeader = do
  privKey <- askPrivateKey
  accAddr <- askSelfAddress
  liftIO $ Tx.newTransaction accAddr privKey txHeader

getTransaction :: Tx.Transaction -> Process ()
getTransaction tx = putText "Writing transaction"
