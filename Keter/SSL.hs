{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Keter.SSL
    ( SslConfig (..)
    , setDir
    , runTCPServerSsl
    ) where

import Keter.Prelude ((++))
import Prelude hiding ((++), FilePath, readFile)
import Data.Yaml (FromJSON (parseJSON), (.:), (.:?), (.!=), Value (Object))
import Control.Applicative ((<$>), (<*>))
import Control.Monad (mzero, forever)
import Data.String (fromString)
import Filesystem.Path.CurrentOS ((</>), FilePath)
import Filesystem (readFile)
import qualified Data.ByteString.Lazy as L
import qualified Data.Certificate.KeyRSA as KeyRSA
import qualified Data.PEM as PEM
import qualified Network.TLS as TLS
import qualified Data.Certificate.X509 as X509
import Data.Conduit.Network (HostPreference, Application, bindPort, sinkSocket)
import Data.Conduit (($$), yield)
import qualified Data.Conduit.List as CL
import Data.Either (rights)
import Keter.PortManager (Port)
import Network.Socket (sClose, accept)
import Network.Socket.ByteString (recv)
import Control.Exception (bracket, finally)
import Control.Concurrent (forkIO)
import Control.Monad.Trans.Class (lift)
import qualified Network.TLS.Extra as TLSExtra
import Crypto.Random

data SslConfig = SslConfig
    { sslHost :: HostPreference
    , sslPort :: Port
    , sslCertificate :: FilePath
    , sslKey :: FilePath
    }

setDir :: FilePath -> SslConfig -> SslConfig
setDir dir ssl = ssl
    { sslCertificate = dir </> sslCertificate ssl
    , sslKey = dir </> sslKey ssl
    }

instance FromJSON SslConfig where
    parseJSON (Object o) = SslConfig
        <$> (fmap fromString <$> o .:? "host") .!= "*"
        <*> o .:? "port" .!= 443
        <*> (fromString <$> o .: "certificate")
        <*> (fromString <$> o .: "key")
    parseJSON _ = mzero

runTCPServerSsl :: SslConfig -> Application IO -> IO ()
runTCPServerSsl SslConfig{..} app = do
    certs <- readCertificates sslCertificate
    key <- readPrivateKey sslKey
    bracket
        (bindPort sslPort sslHost)
        sClose
        (forever . serve certs key)
  where
    serve certs key lsocket = do
        (socket, _addr) <- accept lsocket -- FIXME exception safety
        _ <- forkIO $ handle socket
        return ()
      where
        handle socket = do
            gen <- newGenIO
            ctx <- TLS.serverWith
                params
                (gen :: SystemRandom)
                socket
                (return ()) -- flush
                (\bs -> yield bs $$ sinkSocket socket)
                (recv socket)

            TLS.handshake ctx
            {-
            let conn = Connection
                    { connSendMany = TLS.sendData ctx . L.fromChunks
                    , connSendAll = TLS.sendData ctx . L.fromChunks . return
                    , connSendFile = \fp offset len _th headers -> do
                        TLS.sendData ctx $ L.fromChunks headers
                        C.runResourceT $ sourceFileRange fp (Just offset) (Just len) C.$$ CL.mapM_ (TLS.sendData ctx . L.fromChunks . return)
                    , connClose = do
                        TLS.bye ctx
                        sClose s
                    , connRecv = TLS.recvData ctx
                    }
            return (conn, sa)
            -}

            let src = lift (TLS.recvData ctx) >>= yield >> src
                sink = CL.mapM_ $ TLS.sendData ctx . L.fromChunks . return

            app src sink `finally` sClose socket

        params = TLS.defaultParams
            { TLS.pWantClientCert = False
            , TLS.pAllowedVersions = [TLS.SSL3,TLS.TLS10,TLS.TLS11,TLS.TLS12]
            , TLS.pCiphers         = ciphers
            , TLS.pCertificates    = zip certs $ Just key : repeat Nothing
            }

-- taken from stunnel example in tls-extra
ciphers :: [TLS.Cipher]
ciphers =
    [ TLSExtra.cipher_AES128_SHA1
    , TLSExtra.cipher_AES256_SHA1
    , TLSExtra.cipher_RC4_128_MD5
    , TLSExtra.cipher_RC4_128_SHA1
    ]

readCertificates :: FilePath -> IO [X509.X509]
readCertificates filepath = do
    certs <- rights . parseCerts . PEM.pemParseBS <$> readFile filepath
    case certs of
        []    -> error "no valid certificate found"
        (_:_) -> return certs
    where parseCerts (Right pems) = map (X509.decodeCertificate . L.fromChunks . (:[]) . PEM.pemContent)
                                  $ filter (flip elem ["CERTIFICATE", "TRUSTED CERTIFICATE"] . PEM.pemName) pems
          parseCerts (Left err) = error $ "cannot parse PEM file: " ++ err

readPrivateKey :: FilePath -> IO TLS.PrivateKey
readPrivateKey filepath = do
    pk <- rights . parseKey . PEM.pemParseBS <$> readFile filepath
    case pk of
        []    -> error "no valid RSA key found"
        (x:_) -> return x

    where parseKey (Right pems) = map (fmap (TLS.PrivRSA . snd) . KeyRSA.decodePrivate . L.fromChunks . (:[]) . PEM.pemContent)
                                $ filter ((== "RSA PRIVATE KEY") . PEM.pemName) pems
          parseKey (Left err) = error $ "Cannot parse PEM file: " ++ err
