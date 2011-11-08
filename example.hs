{-# LANGUAGE OverloadedStrings #-}

import qualified Data.Attoparsec as Atto
import qualified Data.ByteString.Char8 as S

import Control.Monad (void, forever)
import Control.Concurrent (forkIO, threadDelay)

import Blaze.ByteString.Builder.ByteString (copyByteString, fromByteString)
import Blaze.ByteString.Builder (Builder)

import Network.Server.ScalableServer

data PingPongRequest = Request S.ByteString

parseRequest :: Atto.Parser PingPongRequest
parseRequest = do
    w <- Atto.takeTill (==13)
    _ <- Atto.string "\r\n"
    return $ Request w

handler :: PingPongRequest -> IO Builder
handler req = return $ handle req

handle :: PingPongRequest -> Builder
handle (Request "PING") = do
    copyByteString "PONG\r\n"

handle (Request _) = do
    copyByteString "ERROR\r\n"

main = testServer

testServer = do
    let definition = RequestPipeline parseRequest handler
    void $ forkIO $ runServer definition 6004
    forever $ threadDelay (1000000 * 60)
