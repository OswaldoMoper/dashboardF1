-- | Punto de entrada del backend: carga la 'Config', construye el 'Env' y
-- levanta la app WAI con Warp.
module Main where

import App (mkEnv)
import Config (Config (..), loadConfig)
import Network.Wai.Handler.Warp (run)
import Server (app)

main :: IO ()
main = do
  cfg <- loadConfig
  env <- mkEnv cfg
  putStrLn $ "F1 Dashboard backend en http://localhost:" <> show (cfgPort cfg) <> "/"
  run (cfgPort cfg) (app env)
