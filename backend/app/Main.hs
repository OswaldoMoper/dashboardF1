-- | Punto de entrada del backend: carga la 'Config', construye el 'Env' y
-- levanta la app WAI con Warp.
module Main where

import           App                      (mkEnv)
import           Config                   (Config (..), loadConfig, startupMark)
import           Control.Concurrent       (forkIO)
import           Control.Monad            (void)
import           Data.Maybe               (fromMaybe)
import qualified Data.Text                as T
import           Data.Time.Clock          (getCurrentTime)
import           Handler.Live.Context     (liveClock, refreshFeedWindow)
import           Network.Wai.Handler.Warp (run)
import           Provenance               (isoInstant)
import           Server                   (app)
import           System.IO                (BufferMode (..), hSetBuffering,
                                           stdout)

-- El calendario se pide una vez al arrancar, y después solo cuando el feed da una
-- sesión por finalizada. No puede tumbar el arranque: si OpenF1 no contesta —lo que
-- hace durante una sesión— el proceso levanta igual y pregunta al feed siempre,
-- hasta que un refresco posterior salga bien.
--
-- El reloj del directo arranca en reposo y no baja hasta que alguien pregunte, así
-- que un backend levantado y sin nadie delante no gasta presupuesto.
-- La salida va por línea y no por bloques: con @stdout@ a una tubería —que es como
-- se recoge el log— GHC la bufferiza en bloques de kilobytes, así que la línea de
-- arranque no aparece hasta que el proceso termina. @stderr@ no lo necesita porque
-- nace sin búfer, que es por lo que los avisos sí salían.
main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  cfg <- loadConfig
  env <- mkEnv cfg
  refreshFeedWindow env
  void (forkIO (liveClock env))
  now <- getCurrentTime
  putStrLn $
    T.unpack (isoInstant now)
      <> startupMark
      <> show (cfgPort cfg)
      <> "/"
  putStrLn $
    T.unpack (isoInstant now)
      <> " microservicio FastF1 en "
      <> fromMaybe
        (T.unpack (cfgTelemetryHost cfg) <> ":" <> show (cfgTelemetryPort cfg))
        (cfgTelemetrySocket cfg)
  run (cfgPort cfg) (app env)
