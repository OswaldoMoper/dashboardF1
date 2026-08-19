-- | Cliente OpenF1 — plumbing HTTP compartido (capa de efectos).
--
-- Punto único de acceso a la API pública de OpenF1 (@api.openf1.org/v1@, sesión
-- @latest@) con el cliente @req@: base de URL, opción de sesión y el GET genérico
-- 'fetchList' que decodifica un arreglo JSON. Reúne también 'fetchDrivers'
-- (@/drivers@), compartido por 'Handler.Live' y 'Handler.TyreStrategy'. Los GET
-- específicos de un área viven en el @Manager@ de esa área, reusando 'fetchList'.
--
-- La __política de fallo__ (techo por intento y número de intentos) no está aquí
-- sino en 'Handler.PublicApi.Manager', porque es la misma que la de Jolpica y no
-- puede divergir entre las dos.
module Handler.OpenF1.Manager where

import           Config                    (Config)
import           Data.Aeson                (FromJSON)
import           Data.Text                 (Text)
import           Handler.OpenF1.Helper     (Of1Driver)
import           Handler.PublicApi.Manager (publicApiConfig, publicApiOptions)
import           Network.HTTP.Req

-- | Base de la API pública de OpenF1.
openf1Base :: Url 'Https
openf1Base = https "api.openf1.org" /: "v1"

-- | Todos los endpoints se piden para la sesión en curso.
latestSession :: Option 'Https
latestSession = "session_key" =: ("latest" :: Text)

-- | GET a un endpoint de OpenF1 que devuelve un arreglo JSON, decodificado.
--
-- Recibe la 'Config' porque de ella sale el techo de duración
-- ('Handler.PublicApi.Manager.publicApiOptions'); el 'Env' la transporta, así que
-- los @Context@ la pasan con @envConfig@ (mismo patrón que
-- 'Handler.Drivers.Manager.fetchDrivers').
fetchList :: FromJSON a => Config -> Text -> IO [a]
fetchList cfg path = runReq publicApiConfig $ do
  res <-
    req
      GET
      (openf1Base /: path)
      NoReqBody
      jsonResponse
      (latestSession <> publicApiOptions cfg)
  pure (responseBody res)

fetchDrivers :: Config -> IO [Of1Driver]
fetchDrivers cfg = fetchList cfg "drivers"
