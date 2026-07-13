module Main (main) where

import Backend.API (homeAPI, server)
import Network.Wai.Handler.Warp (run)
import Servant (serve)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | Puerto de escucha: variable de entorno @PORT@ o 8080 por defecto.
resolvePort :: IO Int
resolvePort = maybe 8080 id . (>>= readMaybe) <$> lookupEnv "PORT"

main :: IO ()
main = do
  port <- resolvePort
  putStrLn $ "F1 Dashboard backend en http://localhost:" <> show port <> "/"
  run port (serve homeAPI server)
