-- | Apache style logger for WAI applications.
--
-- An example:
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- > module Main where
-- >
-- > import Blaze.ByteString.Builder (fromByteString)
-- > import Control.Monad.IO.Class (liftIO)
-- > import qualified Data.ByteString.Char8 as BS
-- > import Network.HTTP.Types (status200)
-- > import Network.Wai (Application, responseBuilder)
-- > import Network.Wai.Handler.Warp (run)
-- > import Network.Wai.Logger (withStdoutLogger, ApacheLogger)
-- >
-- > main :: IO ()
-- > main = withStdoutLogger $ \aplogger ->
-- >     run 3000 $ logApp aplogger
-- >
-- > logApp :: ApacheLogger -> Application
-- > logApp aplogger req = do
-- >     liftIO $ aplogger req status (Just len)
-- >     return $ responseBuilder status hdr msg
-- >   where
-- >     status = status200
-- >     hdr = [("Content-Type", "text/plain")
-- >           ,("Content-Length", BS.pack (show len))]
-- >     pong = "PONG"
-- >     len = fromIntegral $ BS.length pong
-- >     msg = toLogStr pong

module Network.Wai.Logger (
  -- * High level functions
    ApacheLogger
  , withStdoutLogger
  -- * Creating a logger
  , ApacheLoggerActions(..)
  , initLogger
  -- * Types
  , IPAddrSource(..)
  , LogType(..)
  , FileLogSpec(..)
  -- * Date cacher
  , clockDateCacher
  , ZonedDate
  , DateCacheGetter
  , DateCacheUpdater
  -- * Utilities
  , logCheck
  , showSockAddr
  ) where

import Control.AutoUpdate (mkAutoUpdate, defaultUpdateSettings,
                           updateAction)
import Control.Exception (handle, SomeException(..), bracket)
import Control.Monad (when, void)
import Network.HTTP.Types (Status)
import Network.Wai (Request)
import System.IO (withFile, hFileSize, IOMode(..))
import System.Log.FastLogger

import Network.Wai.Logger.Apache
import Network.Wai.Logger.Date
import Network.Wai.Logger.IP (showSockAddr)

----------------------------------------------------------------

-- | Executing a function which takes 'ApacheLogger'.
--   This 'ApacheLogger' writes log message to stdout.
--   Each buffer (4K bytes) is flushed every second.
withStdoutLogger :: (ApacheLogger -> IO a) -> IO a
withStdoutLogger app = bracket setup teardown $ \(aplogger, _) ->
    app aplogger
  where
    setup = do
        (getter, _updater) <- clockDateCacher
        apf <- initLogger FromFallback (LogStdout 4096) getter
        let aplogger = apacheLogger apf
            remover = logRemover apf
        return (aplogger, remover)
    teardown (_, remover) = void remover

----------------------------------------------------------------

-- | Apache style logger.
type ApacheLogger = Request -> Status -> Maybe Integer -> IO ()

data ApacheLoggerActions = ApacheLoggerActions {
    apacheLogger :: ApacheLogger
    -- | Rotating log files.
    --   This is explicitly called from your program.
    --   Probably, 10 seconds is proper.
  , logRotator :: IO ()
    -- | Removing resources relating Apache logger.
  , logRemover :: IO ()
  }

-- | Logger Type.
data LogType = LogNone                     -- ^ No logging.
             | LogStdout BufSize           -- ^ Logging to stdout.
                                           --   'BufSize' is a buffer size
                                           --   for each capability.
             | LogFile FileLogSpec BufSize -- ^ Logging to a file.
                                           --   'BufSize' is a buffer size
                                           --   for each capability.
             | LogCallback (LogStr -> IO ()) (IO ())

----------------------------------------------------------------

-- |
-- Creating 'ApacheLogger' according to 'LogType'.
initLogger :: IPAddrSource -> LogType -> DateCacheGetter
           -> IO ApacheLoggerActions
initLogger _     LogNone             _       = noLoggerInit
initLogger ipsrc (LogStdout size)    dateget = stdoutLoggerInit ipsrc size dateget
initLogger ipsrc (LogFile spec size) dateget = fileLoggerInit ipsrc spec size dateget
initLogger ipsrc (LogCallback cb flush) dateget = callbackLoggerInit ipsrc cb flush dateget

----------------------------------------------------------------

noLoggerInit :: IO ApacheLoggerActions
noLoggerInit = return ApacheLoggerActions {
    apacheLogger = noLogger
  , logRotator = noRotator
  , logRemover = noRemover
  }
  where
    noLogger _ _ _ = return ()
    noRotator = return ()
    noRemover = return ()

stdoutLoggerInit :: IPAddrSource -> BufSize -> DateCacheGetter
                 -> IO ApacheLoggerActions
stdoutLoggerInit ipsrc size dateget = do
    lgrset <- newStdoutLoggerSet size
    let logger = apache (pushLogStr lgrset) ipsrc dateget
        noRotator = return ()
        remover = rmLoggerSet lgrset
    return ApacheLoggerActions {
        apacheLogger = logger
      , logRotator = noRotator
      , logRemover = remover
      }

fileLoggerInit :: IPAddrSource -> FileLogSpec -> BufSize -> DateCacheGetter
               -> IO ApacheLoggerActions
fileLoggerInit ipsrc spec size dateget = do
    lgrset <- newFileLoggerSet size $ log_file spec
    let logger = apache (pushLogStr lgrset) ipsrc dateget
        rotator = logRotater lgrset spec
        remover = rmLoggerSet lgrset
    return ApacheLoggerActions {
        apacheLogger = logger
      , logRotator = rotator
      , logRemover = remover
      }

callbackLoggerInit :: IPAddrSource -> (LogStr -> IO ()) -> IO () -> DateCacheGetter
                   -> IO ApacheLoggerActions
callbackLoggerInit ipsrc cb flush dateget = do
    flush' <- mkAutoUpdate defaultUpdateSettings
        { updateAction = flush
        }
    let logger x y z = apache cb ipsrc dateget x y z >> flush'
        noRotator = return ()
        remover = return ()
    return ApacheLoggerActions {
        apacheLogger = logger
      , logRotator = noRotator
      , logRemover = remover
      }

----------------------------------------------------------------

apache :: (LogStr -> IO ()) -> IPAddrSource -> DateCacheGetter -> ApacheLogger
apache cb ipsrc dateget req st mlen = do
    zdata <- dateget
    cb (apacheLogStr ipsrc zdata req st mlen)

----------------------------------------------------------------

logRotater :: LoggerSet -> FileLogSpec -> IO ()
logRotater lgrset spec = do
    over <- isOver
    when over $ do
        rotate spec
        renewLoggerSet lgrset
  where
    file = log_file spec
    isOver = handle (\(SomeException _) -> return False) $ do
        siz <- withFile file ReadMode hFileSize
        return (siz > log_file_size spec)

----------------------------------------------------------------

-- |
-- Checking if a log file can be written if 'LogType' is 'LogFile'.
logCheck :: LogType -> IO ()
logCheck LogNone          = return ()
logCheck (LogStdout _)    = return ()
logCheck (LogFile spec _) = check spec
logCheck (LogCallback _ _) = return ()
