module Network.Server.ScalableServer (
    -- * Introduction
    -- $intro

    runServer,
    RequestPipeline(..), RequestCreator,
    RequestProcessor) where

import Blaze.ByteString.Builder (Builder, toByteString)
import Control.Monad.Trans (liftIO)
import Control.Applicative
import Data.ByteString
import Data.Conduit
import Data.Conduit.List as CL
import Data.Conduit.Network
import Data.Conduit.Attoparsec
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

runServer :: RequestPipeline a -> PortNumber -> IO ()
runServer pipe port = do
    let app = (processRequest pipe)
    let settings = serverSettings (fromIntegral port) HostAny
    runTCPServer settings app

processRequest :: RequestPipeline a -> AppData IO -> IO ()
processRequest (RequestPipeline parser handler) appdata = do
    let source = appSource appdata
    let sink = appSink appdata
    source $$ conduitParser parser =$= CL.mapM wrapHandler =$= sink
  where
    wrapHandler (_, n) = toByteString <$> handler n
