-- | La lectura de los @QueryParam@ opcionales que comparten las áreas: uno escrito pero
-- vacío se rechaza en todas con 400 y con el mismo motivo.
module Handler.Query.Helper
  ( queryParam
  , sessionParam
  , sessionValue
  , sessionKeyParam
  ) where

import           Common.Session (SessionKey, readSessionKey)
import           Data.Maybe     (fromMaybe)
import           Data.Text      (Text)
import qualified Data.Text      as T
import           Outcome        (Rejection (..))

-- | Un @QueryParam@ opcional, resuelto: ausente → el valor por defecto; escrito
-- pero vacío (@?name=@) → 'BadRequest' (en las áreas de FastF1 viajaría como segmento
-- vacío de la URL del microservicio); con contenido → tal cual.
--
-- Solo es vacío la cadena vacía: un valor de espacios pasa como cualquier otro.
--
-- El motivo del rechazo es @«name está vacío: omítelo para …»@, completado con
-- @hint@.
queryParam :: Text -> Text -> Text -> Maybe Text -> Either Rejection Text
queryParam name hint def = fmap (fromMaybe def) . optionalParam name hint

-- | El @?session=@ de las áreas, con su motivo de rechazo.
sessionParam :: Text -> Maybe Text -> Either Rejection Text
sessionParam = queryParam "session" sessionHint

-- | El @?session=@ sin valor por defecto: ausente sigue ausente; vacío, el mismo rechazo
-- que 'sessionParam'.
sessionValue :: Maybe Text -> Either Rejection (Maybe Text)
sessionValue = optionalParam "session" sessionHint

-- | El @?session=@ que solo admite una clave @AÑO-RONDA-SESIÓN@: ausente sigue ausente;
-- vacío, el rechazo de 'sessionValue'; @latest@ o lo que no es una clave, 'BadRequest'.
sessionKeyParam :: Maybe Text -> Either Rejection (Maybe SessionKey)
sessionKeyParam param = sessionValue param >>= traverse key
  where
    key v =
      maybe
        (Left (BadRequest ("session no es una clave AÑO-RONDA-SESIÓN (p. ej. 2026-13-R): " <> v)))
        Right
        (readSessionKey v)

sessionHint :: Text
sessionHint = "usar la sesión por defecto"

optionalParam :: Text -> Text -> Maybe Text -> Either Rejection (Maybe Text)
optionalParam _ _ Nothing = Right Nothing
optionalParam name hint (Just value)
  | T.null value = Left (BadRequest (name <> " está vacío: omítelo para " <> hint))
  | otherwise    = Right (Just value)
