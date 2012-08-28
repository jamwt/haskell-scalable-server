module Network.Server.ScalableServer (
    -- * Introduction
    -- $intro

    runServer,
    RequestPipeline(..), RequestCreator,
    RequestProcessor) where

import Network.Socket
import Network.Socket.Enumerator (enumSocket)
import qualified Network.Socket.ByteString as BinSock
import Network.BSD
import Control.Exception (finally, try, throwIO, SomeException)
import Control.Monad (forever, liftM, replicateM, void, when)
import Control.Monad.Trans (liftIO)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (atomically, retry)
import Control.Concurrent.STM.TVar (newTVarIO, readTVar, writeTVar, modifyTVar', TVar)
import Control.Concurrent.STM.TChan (newTChanIO, readTChan, writeTChan, TChan)
import Data.Enumerator (($$), run_)
import qualified Data.Enumerator as E
import Data.Attoparsec.Enumerator (iterParser)
import Blaze.ByteString.Builder (toByteStringIO, Builder)
import Data.Enumerator (yield, continue, Iteratee, Stream(..))
import qualified Data.Attoparsec as Atto
import qualified Data.Attoparsec.Char8 as AttoC
import qualified Data.ByteString.Char8 as S
import qualified Data.ByteString as WS
import qualified Data.ByteString.Lazy.Char8 as B

-- $intro
--
-- 'ScalableServer' is a library that attempts to capture current best
-- practices for writing fast/scalable socket servers in Haskell.
--
-- Currently, that involves providing the right glue for hooking up
-- to enumerator/attoparsec-enumerator/blaze-builder and network-bytestring
--
-- It provides a relatively simple parse/generate toolchain for
-- plugging into these engines
--
-- Servers written using this library support "pipelining"; that is, a client
-- can issue many requests serially before the server has responded to the
-- first
--
-- Server written using this library also can be invoked with +RTS -NX
-- invocation for multicore support

-- |The 'RequestPipeline' acts as a specification for your service,
-- indicating both a parser/request object generator, the RequestCreator,
-- and the processor of these requests, one that ultimately generates a
-- response expressed by a blaze 'Builder'
data RequestPipeline a = RequestPipeline (RequestCreator a) (RequestProcessor a) PipelineSize

-- |The RequestCreator is an Attoparsec parser that yields some request
-- object 'a'
type RequestCreator a = Atto.Parser a

-- |The RequestProcessor is a function in the IO monad (for DB access, etc)
-- that returns a builder that can generate the response
type RequestProcessor a = a -> IO Builder

type RequestChannel a  = BoundedChan (Maybe a)

type PipelineSize = Int

-- |Given a pipeline specification and a port, run TCP traffic using the
-- pipeline for parsing, processing and response.
--
-- Note: there is currently no way for a server to specific the socket
-- should be disconnected
runServer :: RequestPipeline a -> PortNumber -> IO ()
runServer pipe port = do
    proto <- getProtocolNumber "tcp"
    s <- socket AF_INET Stream proto
    setSocketOption s ReuseAddr 1
    bindSocket s (SockAddrInet port iNADDR_ANY)
    serverListenLoop pipe s

serverListenLoop :: RequestPipeline a -> Socket -> IO ()
serverListenLoop pipe s = do
    listen s 100
    finally (
        forever $ do
            (c, _) <- accept s
            forkIO $ connHandler pipe c
        ) $ sClose s

connHandler :: RequestPipeline a -> Socket -> IO ()
connHandler (RequestPipeline reqParse reqProc size) s = do
    chan <- newBoundedChan size
    (do
        let enum = enumSocket 4096 s
        let parser = iterParser reqParse
        void $ forkIO $ processRequests chan reqProc s
        void $ run_ (enum $$ E.sequence parser $$ requestHandler chan s)
        ) `finally` ( (writeChan chan Nothing) >> sClose s )

requestHandler :: RequestChannel a -> Socket -> Iteratee a IO ()
requestHandler chan s = do
    continue requestConsume
  where
    requestConsume (Chunks mrs) = do
        liftIO $ mapM_ (\m -> writeChan chan $ Just m) mrs
        continue requestConsume
    requestConsume EOF = do
        yield () EOF

processRequests :: RequestChannel a -> RequestProcessor a -> Socket -> IO ()
processRequests chan proc s = do
    next <- readChan chan
    case next of
        Just a -> do
            mresp <- try $ proc a
            case mresp of
                Right resp -> do
                    toByteStringIO (BinSock.sendAll s) $ resp
                    processRequests chan proc s
                Left (e :: SomeException) -> do
                    sClose s
                    throwIO e
        Nothing -> return ()


-- Homebrew bounded channel

type BoundedChan a = (TVar Int, TChan a)

newBoundedChan :: Int -> IO (BoundedChan a)
newBoundedChan sz = do
    a <- newTVarIO sz
    c <- newTChanIO
    return (a, c)

readChan :: BoundedChan a -> IO a
readChan (a, c) = atomically $ do
    v <- readTChan c
    modifyTVar' a (+1)
    return v

writeChan :: BoundedChan a -> a -> IO ()
writeChan (a, c) i = atomically $ do
    count <- readTVar a
    when (count == 0) retry
    writeTVar a (count - 1)
    writeTChan c i
