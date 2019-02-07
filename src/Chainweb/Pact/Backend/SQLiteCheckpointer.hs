-- |
-- Module: Chainweb.Pact.Backend.SQLiteCheckpointer
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: See LICENSE file
-- Maintainer: Emmanuel Denloye-Ito <emmanuel@kadena.io>
-- Stability: experimental
-- Pact SQLite checkpoint module for Chainweb
module Chainweb.Pact.Backend.SQLiteCheckpointer where

import Data.Bifunctor
import qualified Data.ByteString as B
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HMS
import qualified Data.List as L
import Data.List.Split
import Data.Monoid
import Data.Serialize
import Data.String

import Control.Concurrent.MVar
import Control.Lens
import Control.Monad.Except

import System.Directory
import System.IO.Extra

import Text.Printf

import qualified Pact.Persist as P
import qualified Pact.Persist.SQLite as P
import qualified Pact.PersistPactDb as P
import qualified Pact.Types.Logger as P
import qualified Pact.Types.Runtime as P
import qualified Pact.Types.Server as P

-- internal modules
import Chainweb.BlockHeader
import Chainweb.Pact.Backend.Types

initSQLiteCheckpointEnv :: P.CommandConfig -> P.Logger -> P.GasEnv -> IO CheckpointEnv
initSQLiteCheckpointEnv cmdConfig logger gasEnv = do
    inmem <- newMVar mempty
    return $
        CheckpointEnv
            { _cpeCheckpointer =
                  Checkpointer
                      { restore = restore' inmem
                      , save = save' inmem
                      }
            , _cpeCommandConfig = cmdConfig
            , _cpeLogger = logger
            , _cpeGasEnv = gasEnv
            }

type Store = HashMap (BlockHeight, BlockPayloadHash) FilePath

reinitDbEnv :: P.Loggers -> P.Persister P.SQLite -> SaveData P.SQLite -> IO (Either String PactDbState)
reinitDbEnv loggers funrec savedata = runExceptT $ do
    db <- ExceptT $ maybe err (fmap Right . (`P.initSQLite` loggers)) (_sSQLiteConfig savedata)
    return (PactDbState (EnvPersist' (PactDbEnvPersist P.pactdb (mkDbEnv db))) (_sCommandState savedata))
    where
    mkDbEnv db = P.DbEnv db persist logger txRecord txId
    err = return $ Left $ "SQLiteCheckpointer.reinitDbEnv: Configuration exception"
    persist = funrec
    logger = P.newLogger loggers (fromString "<to fill with something meaningful>") -- TODO: Needs a better message
    txRecord = _sTxRecord savedata
    txId = _sTxId savedata

-- This should open a connection with the assumption that there is not
--  any connection open. There should be tests that assert this
--  essential aspect of the 'restore' semantics.
restore' :: MVar Store -> BlockHeight -> BlockPayloadHash -> IO (Either String PactDbState)
restore' lock height hash = do
  withMVar lock $ \store -> do
    case HMS.lookup (height, hash) store of
      Just chk_file -> do

        --check that filename has the right version.
        flip (maybe (return $ Left (err_version "nothing" saveDataVersion))) (versionCheck chk_file) $
             \version ->
               if version /= saveDataVersion
                  then return $ Left (err_version version saveDataVersion)
                  else runExceptT $ do

                       -- read back SaveData from copied file
                       cdata <- do
                         bytes <- liftIO $ B.readFile chk_file
                         ExceptT $ return $ (first err_decode $ decode bytes)

                       ExceptT $ withTempFile $ \copy_sqlite_file -> do

                         -- create copy of the sqlite file
                         let copy_data = over (sSQLiteConfig . _Just) (changeSQLFilePath copy_sqlite_file const) cdata

                         -- Open a database connection.
                         reinitDbEnv P.neverLog P.persister copy_data

      Nothing -> err_restore
  where
    err_version = printf "Version exception %s %s"
    err_decode = printf "SQLiteCheckpointer.restore': Checkpoint decode exception= %s"
    err_restore = return $ Left "SQLiteCheckpointException.restore': Restore not found exception"
    versionCheck filename = getFirst $ foldMap (First . L.stripPrefix "version=") $ splitOn "_" filename
    {-go bytes = do
      decoded <- decode bytes
      return (bytes, decoded)-}

changeSQLFilePath :: FilePath -> (FilePath -> FilePath -> FilePath) -> P.SQLiteConfig -> P.SQLiteConfig
changeSQLFilePath fp f (P.SQLiteConfig dbFile pragmas) =
    P.SQLiteConfig (f fp dbFile) pragmas

-- This should close the database connection currently open upon
-- arrival in this function. The database should either be closed (or
-- throw an error) before departure from this function. There should
-- be tests that assert this essential aspect of the 'save' semantics.
save' :: MVar Store -> BlockHeight -> BlockPayloadHash -> PactDbState -> IO (Either String ())
save' lock height hash pactdbstate =
  withMVar lock $ \store ->
    case HMS.lookup (height, hash) store of
      Just _ -> return $ Left msgSaveKeyError
      Nothing -> do

        -- Those existentials make us do some unslightly unpacking. Can't put
        -- lipstick on this pig.
        case (_pdbsDbEnv pactdbstate) of
          EnvPersist' (pactdbenvpersist@(PactDbEnvPersist _ _dbEnv)) ->
            case _dbEnv of
              dbEnv -> do

              -- First, close the database connection.
               closeDb (P._db dbEnv)

               -- Then "save" it. Really we're computing the SaveData
               -- data and the valid prefix for naming the file
               -- containing serialized Pact values.
               (mf, toSave) <- saveDb pactdbenvpersist (_pdbsState pactdbstate)
               let dbFile = P.dbFile <$> (_sSQLiteConfig toSave)
                   newdbFile = properName <$ dbFile

               flip (maybe (return $ Left msgPrefixError)) mf $
                    \prefix -> do

                      -- Save serialized Pact values.
                      let sd = encode toSave
                      B.writeFile (prefix ++ properName) sd

                      -- Copy the database file (the connection SHOULD
                      -- be dead as roadkill).
                      tempfile <- fst <$> newTempFileWithin "./" -- should we use Path instead of FilePath here?
                      runExceptT $ do

                         -- We write to a temporary file THEN rename it to
                         -- get an atomic copy of the database file.
                         contents <- helper msgDbFileError B.readFile dbFile
                         -- onError
                         liftIO $ B.writeFile tempfile contents
                         helper msgWriteDbError (renameFile tempfile) newdbFile
  where
    properName = printf "chk.%s.%s" (show hash) (show height)
    helper f g = ExceptT . maybe (return $ Left f) (fmap Right . g)
    msgPrefixError = "SQLiteCheckpointer.save': Prefix not set exception"
    msgDbFileError = "SQLiteCheckpointer.save': Copy dbFile error"
    msgWriteDbError = "SQLiteCheckpointer.save': Write db error"
    msgSaveKeyError = "SQLiteCheckpointer.save': Save key not found exception"
