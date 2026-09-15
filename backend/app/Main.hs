-- | Punto de entrada del backend: carga la 'Config', construye el 'Env' y
-- levanta la app WAI con Warp.
module Main where

import           App                      (mkEnv)
import           Config                   (Config (..), loadConfig)
import           Handler.Live.Context     (refreshFeedWindow)
import           Network.Wai.Handler.Warp (run)
import           Server                   (app)

-- El calendario se pide una vez al arrancar, y después solo cuando el feed da una
-- sesión por finalizada. No puede tumbar el arranque: si OpenF1 no contesta —lo que
-- hace durante una sesión— el proceso levanta igual y pregunta al feed siempre,
-- hasta que un refresco posterior salga bien.
main :: IO ()
main = do
  cfg <- loadConfig
  env <- mkEnv cfg
  refreshFeedWindow env
  putStrLn $ "F1 Dashboard backend en http://localhost:" <> show (cfgPort cfg) <> "/"
  run (cfgPort cfg) (app env)
