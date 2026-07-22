-- | Área Live timing — capa de efectos.
--
-- Único punto con IO/HTTP del caso de uso: consulta los endpoints de OpenF1
-- (sesión @latest@) con el cliente @req@ y decodifica a los tipos crudos de
-- 'Handler.Live.Helper'. Sin lógica de negocio: la orquestación vive en
-- 'Handler.Live.Context' y el mapeo puro en 'Handler.Live.Helper'.
module Handler.Live.Manager where

import           Data.Aeson          (FromJSON)
import           Data.Text           (Text)
import           Handler.Live.Helper (Of1Driver, Of1Interval, Of1Lap,
                                      Of1Position)
import           Network.HTTP.Req

-- | Base de la API pública de OpenF1.
openf1Base :: Url 'Https
openf1Base = https "api.openf1.org" /: "v1"

-- | Todos los endpoints se piden para la sesión en curso.
latestSession :: Option 'Https
latestSession = "session_key" =: ("latest" :: Text)

-- | GET a un endpoint de OpenF1 que devuelve un arreglo JSON, decodificado.
fetchList :: FromJSON a => Text -> IO [a]
fetchList path = runReq defaultHttpConfig $ do
  res <- req GET (openf1Base /: path) NoReqBody jsonResponse latestSession
  pure (responseBody res)

fetchDrivers :: IO [Of1Driver]
fetchDrivers = fetchList "drivers"

fetchPositions :: IO [Of1Position]
fetchPositions = fetchList "position"

fetchIntervals :: IO [Of1Interval]
fetchIntervals = fetchList "intervals"

fetchLaps :: IO [Of1Lap]
fetchLaps = fetchList "laps"
