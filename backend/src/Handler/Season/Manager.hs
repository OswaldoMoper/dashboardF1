-- | Cliente del microservicio FastF1 del área temporada: su calendario y sus circuitos de un
-- año.
module Handler.Season.Manager
  ( fetchSchedule
  , fetchCircuits
  ) where

import           Config                 (Config (..))
import qualified Data.Text              as T
import           Handler.FastF1.Manager (fastf1Port, fastf1Timeout, runFastF1)
import           Handler.Season.Helper  (FastF1Circuit, FastF1Event)
import           Network.HTTP.Req

-- | @GET \/fastf1\/schedule\/{año}@, decodificado. Con el techo de la configuración, que
-- no es una sesión que cargar. Lanza si el servicio no contesta, si no tiene el
-- calendario (@503@) o si la respuesta trae otra forma.
fetchSchedule :: Config -> Int -> IO [FastF1Event]
fetchSchedule cfg year = runFastF1 cfg $ do
  res <-
    req
      GET
      (http (cfgTelemetryHost cfg) /: "fastf1" /: "schedule" /: T.pack (show year))
      NoReqBody
      jsonResponse
      (fastf1Port (cfgTelemetryPort cfg) <> fastf1Timeout (cfgTelemetryTimeout cfg))
  pure (responseBody res)

-- | @GET \/fastf1\/circuits\/{año}@, decodificado, como 'fetchSchedule'.
fetchCircuits :: Config -> Int -> IO [FastF1Circuit]
fetchCircuits cfg year = runFastF1 cfg $ do
  res <-
    req
      GET
      (http (cfgTelemetryHost cfg) /: "fastf1" /: "circuits" /: T.pack (show year))
      NoReqBody
      jsonResponse
      (fastf1Port (cfgTelemetryPort cfg) <> fastf1Timeout (cfgTelemetryTimeout cfg))
  pure (responseBody res)
