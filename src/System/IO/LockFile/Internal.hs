{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
-- |
-- Module:       $HEADER$
-- Description:  Low-level API for providing exclusive access to a resource
--               using lock file.
-- Copyright:    (c) 2013 Peter Trsko
-- License:      BSD3
--
-- Maintainer:   peter.trsko@gmail.com
-- Stability:    experimental
-- Portability:  non-portable (CPP, DeriveDataTypeable)
--
-- Low-level API for providing exclusive access to a resource using lock file.
module System.IO.LockFile.Internal
    (
    -- * Locking primitives
      lock
    , unlock

    -- * Configuration
    , LockingParameters(..)
    , RetryStrategy(..)

    -- * Exceptions
    , LockingException(..)
    )
    where

import Control.Applicative ((<$>))
import Control.Concurrent (threadDelay)
import Control.Exception (IOException)
import Control.Monad (when)
import Data.Bits ((.|.))
import Data.Data (Data)
import Data.Typeable (Typeable)
import Data.Word (Word8, Word64)
import Foreign.C (eEXIST, errnoToIOError, getErrno)
import GHC.IO.Handle.FD (fdToHandle)
import System.IO (Handle, hClose, hFlush, hPutStrLn)
import System.Posix.Internals
    ( c_close
    , c_getpid
    , c_open
    , o_BINARY
    , o_CREAT
    , o_EXCL
    , o_NOCTTY
    , o_NONBLOCK
    , o_RDWR
    , withFilePath
    )

import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.TaggedException
    ( Exception
    , MonadException(throw)
    , Throws
    , mapException
    , onException'
    )
#if MIN_VERSION_tagged_exception_core(1,1,0)
import Control.Monad.TaggedException.Hidden (HiddenException)
#else
import Control.Monad.TaggedException.Hidden (HidableException)
#endif
import Data.Default.Class (Default(def))
import System.Directory (removeFile)


data RetryStrategy
    = No
    -- ^ Don't retry at all.
    | Indefinitely
    -- ^ Retry indefinitely.
    | NumberOfTimes Word8
    -- ^ Retry only specified number of times.
    -- If equal to zero then it is interpreted as 'No'.
  deriving (Data, Eq, Show, Read, Typeable)

-- | @def = 'Indefinitely'@
instance Default RetryStrategy where
    def = Indefinitely

data LockingParameters = LockingParameters
    { retryToAcquireLock :: RetryStrategy
    , sleepBetweenRetires :: Word64
    -- ^ Sleep interval is in microseconds.
    }
  deriving (Data, Eq, Show, Read, Typeable)

-- | @def = 'LockingParameters' def 8000000@
--
-- Sleep interfal is inspired by @lockfile@ command line utility that is part
-- of Procmail.
instance Default LockingParameters where
    def = LockingParameters
        { retryToAcquireLock = def
        , sleepBetweenRetires = 8000000 -- 8 s
        }

data LockingException
    = UnableToAcquireLockFile FilePath
    -- ^ Wasn't able to aquire lock file specified as an argument.
    | CaughtIOException IOException
    -- ^ 'IOException' occurred while creating or removing lock file.
  deriving (Typeable)

instance Show LockingException where
    showsPrec _ e = case e of
        UnableToAcquireLockFile fp -> shows' "Unable to acquire lock file" fp
        CaughtIOException ioe -> shows' "Caught IO exception" ioe
      where shows' str x = showString str . showString ": " . shows x

instance Exception LockingException
#if MIN_VERSION_tagged_exception_core(1,1,0)
instance HiddenException LockingException
#else
instance HidableException LockingException
#endif

-- | Map 'IOException' to 'LockingException'.
wrapIOException
    :: (MonadException m)
    => Throws IOException m a -> Throws LockingException m a
wrapIOException = mapException CaughtIOException

-- | Lift @IO@ and map any raised 'IOException' to 'LockingException'.
io :: (MonadException m, MonadIO m) => IO a -> Throws LockingException m a
io = wrapIOException . liftIO

-- | Open lock file write PID of a current process in to it and return its
-- handle.
--
-- If operation doesn't succeed, then 'LockingException' is raised. See also
-- 'LockingParameters' and 'RetryStrategy' for details.
lock
    :: (MonadException m, MonadIO m)
    => LockingParameters
    -> FilePath
    -> Throws LockingException m Handle
lock params = lock' $ case retryToAcquireLock params of
    NumberOfTimes 0 -> params{retryToAcquireLock = No}
    _ -> params
  where
    openLockFile lockFileName = io $ do
        fd <- withFilePath lockFileName $ \ fp -> c_open fp openFlags 0o644
        if fd > 0
            then Just <$> fdToHandle fd `onException'` c_close fd
            else do
                errno <- getErrno
                when (errno /= eEXIST) . ioError
                    . errnoToIOError "lock" errno Nothing $ Just lockFileName
                -- Failed to open lock file because it already exists
                return Nothing
      where
        openFlags = o_NONBLOCK .|. o_NOCTTY .|. o_RDWR .|. o_CREAT .|. o_EXCL
            .|. o_BINARY

    lock' params' lockFileName
      | retryToAcquireLock params' == NumberOfTimes 0 = failedToAcquireLockFile
      | otherwise = do
            lockFileHandle <- openLockFile lockFileName
            case lockFileHandle of
                Nothing -> case retryToAcquireLock params' of
                    No -> failedToAcquireLockFile
                    _ -> do
                        io $ threadDelay sleepBetweenRetires'
                        lock' paramsDecRetries lockFileName
                Just h -> io $ do
                    c_getpid >>= hPutStrLn h . ("PID=" ++) . show
                    hFlush h
                    return h
      where
        sleepBetweenRetires' = fromIntegral $ sleepBetweenRetires params'
        failedToAcquireLockFile = throw $ UnableToAcquireLockFile lockFileName

        paramsDecRetries = case retryToAcquireLock params' of
            NumberOfTimes n ->
                params'{retryToAcquireLock = NumberOfTimes $ n - 1}
            _ -> params'

-- | Close lock file handle and then delete it.
unlock
    :: (MonadException m, MonadIO m)
    => FilePath
    -> Handle
    -> Throws LockingException m ()
unlock lockFileName lockFileHandle =
    io $ hClose lockFileHandle >> removeFile lockFileName
