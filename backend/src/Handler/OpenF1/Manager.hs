-- | Cliente OpenF1 — plumbing HTTP compartido (capa de efectos).
--
-- Punto único de acceso a la API pública de OpenF1 (@api.openf1.org/v1@, sesión
-- @latest@) con el cliente @req@: base de URL, opción de sesión y el GET genérico
-- 'fetchList' que decodifica un arreglo JSON. Reúne también 'fetchDrivers'
-- (@/drivers@), compartido por 'Handler.Live' y 'Handler.TyreStrategy'. Los GET
-- específicos de un área viven en el @Manager@ de esa área, reusando 'fetchList'.
module Handler.OpenF1.Manager where

import           Data.Aeson            (FromJSON)
import           Data.Text             (Text)
import           Handler.OpenF1.Helper (Of1Driver)
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
