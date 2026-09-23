-- | Lo puro que comparten los consumidores del microservicio FastF1
-- ('Handler.Telemetry', 'Handler.Comparison' y 'Handler.Drivers'): la lectura
-- de los @QueryParam@ que viajan como segmentos de su URL.
module Handler.FastF1.Helper
  ( queryParam
  , sessionParam
  ) where

import           Data.Text (Text)
import qualified Data.Text as T
import           Outcome   (Rejection (..))

-- | Un @QueryParam@ opcional, resuelto: ausente → el valor por defecto; escrito
-- pero vacío (@?name=@) → 'BadRequest', porque viajaría como segmento vacío de
-- la URL del microservicio; con contenido → tal cual.
--
-- Solo es vacío la cadena vacía: un valor de espacios pasa como cualquier otro.
--
-- El motivo del rechazo es @«name está vacío: omítelo para …»@, completado con
-- @hint@.
queryParam :: Text -> Text -> Text -> Maybe Text -> Either Rejection Text
queryParam _ _ def Nothing = Right def
queryParam name hint _ (Just value)
  | T.null value = Left (BadRequest (name <> " está vacío: omítelo para " <> hint))
  | otherwise    = Right value

-- | El @?session=@ de las tres áreas, con su motivo de rechazo.
sessionParam :: Text -> Maybe Text -> Either Rejection Text
sessionParam = queryParam "session" "usar la sesión por defecto"
