module Network.Server.ScalableServer (
    -- * Introduction
    -- $intro

    runServer,
    RequestPipeline(..), RequestCreator,
    RequestProcessor) where

import Blaze.ByteString.Builder (Builder)
import Data.ByteString
import Data.Conduit
import Data.Conduit.List as CL
import Data.Conduit.Network
import Data.Conduit.Attoparsec
import Data.Conduit.Blaze
import Network.BSD
import qualified Data.Attoparsec as Atto

-- $intro
--
-- 'ScalableServer' is a library that attempts to capture current best
-- practices for writing fast/scalable socket servers in Haskell.
--
-- Currently, that involves providing the right glue for hooking up
-- to conduit/network-conduit/attoparsec-conduit/blaze-builder
--
-- It provides a relatively simple parse/generate toolchain for
-- plugging into these engines
--
-- Server written using this library also can be invoked with +RTS -NX
-- invocation for multicore support

-- |The 'RequestPipeline' acts as a specification for your service,
-- indicating both a parser/request object generator, the RequestCreator,
-- and the processor of these requests, one that ultimately generates a
-- response expressed by a blaze 'Builder'
data RequestPipeline a = RequestPipeline (RequestCreator a) (RequestProcessor a)

-- |The RequestCreator is an Attoparsec parser that yields some request
-- object 'a'
type RequestCreator a = Atto.Parser a

-- |The RequestProcessor is a function in the IO monad (for DB access, etc)
-- that returns a builder that can generate the response
type RequestProcessor a = a -> IO Builder

-- |Given a pipeline specification and a port, run TCP traffic using the
-- pipeline for parsing, processing and response.
--
-- Note: there is currently no way for a server to specific the socket
-- should be disconnected
runServer :: RequestPipeline a -> PortNumber -> IO ()
runServer pipe port = do
    let app = (processRequest pipe)
    runTCPServer (ServerSettings (fromIntegral port) HostAny) app

processRequest :: RequestPipeline a -> Source IO ByteString -> Sink ByteString IO () -> IO ()
processRequest (RequestPipeline parser handler) source sink = do
    source $$ (conduitParser parser) =$= CL.map snd =$=
        CL.mapM handler =$=
        builderToByteStringWith (allNewBuffersStrategy 0) =$
        sink
