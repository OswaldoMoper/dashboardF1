-- | Lo puro que comparten los consumidores del microservicio FastF1
-- ('Handler.Telemetry', 'Handler.Comparison' y 'Handler.Drivers'): la lectura
-- de los @QueryParam@ que viajan como segmentos de su URL. Y, para quien juzga la
-- cuenta de F1TV con la que FastF1 abre el archivo, lo que dice el fichero del token.
module Handler.FastF1.Helper
  ( queryParam
  , sessionParam
  , TokenFile (..)
  , tokenExpiry
  , tokenFile
  ) where

import           Data.Aeson                 (eitherDecodeStrict, withObject,
                                             (.:))
import           Data.Aeson.Types           (parseEither)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Base64.URL as B64U
import qualified Data.ByteString.Char8      as BS8
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Time.Clock            (UTCTime)
import           Data.Time.Clock.POSIX      (posixSecondsToUTCTime)
import           Outcome                    (Rejection (..))

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

-- | Lo que hay en @f1auth.json@, el fichero en que FastF1 guarda el token de F1TV.
data TokenFile
  = TokenMissing
  | TokenUnreadable          -- ^ Vacío (FastF1 lo crea así) o algo que no es un token.
  | TokenExpires UTCTime
  deriving (Eq, Show)

-- | La caducidad (@exp@) del token, un JWT en texto. __Solo devuelve la hora__: el resto
-- del token lleva datos del suscriptor y no sale de aquí.
tokenExpiry :: BS.ByteString -> Maybe UTCTime
tokenExpiry raw = case BS8.split '.' (BS8.strip raw) of
  [_, payload, _] -> do
    claims <- either (const Nothing) Just (B64U.decodeUnpadded payload)
    secs <- either (const Nothing) Just (eitherDecodeStrict claims >>= parseEither (withObject "token" (.: "exp")))
    pure (posixSecondsToUTCTime (fromInteger secs))
  _ -> Nothing

tokenFile :: BS.ByteString -> TokenFile
tokenFile = maybe TokenUnreadable TokenExpires . tokenExpiry
