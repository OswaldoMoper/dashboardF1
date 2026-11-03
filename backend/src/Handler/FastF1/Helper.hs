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

import           Control.Monad         (guard)
import           Data.Aeson            (eitherDecodeStrict, withObject, (.:))
import           Data.Aeson.Types      (parseEither)
import qualified Data.ByteString       as BS
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Data.Time.Clock       (NominalDiffTime, UTCTime, addUTCTime)
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           Outcome               (Rejection (..))

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

-- | Lo que hay en @f1auth_token.json@, el fichero en que FastF1 guarda el token de F1TV.
data TokenFile
  = TokenMissing
  | TokenUnreadable          -- ^ Vacío, de otra versión o algo que no es el fichero del token.
  | TokenExpires UTCTime     -- ^ Desde cuándo FastF1 deja de usarlo ('fastf1ExpiryMargin').
  deriving (Eq, Show)

-- | Cuánto antes de @expires_at@ da FastF1 el token por caducado y vuelve a iniciar
-- sesión: el @EXPIRY_MARGIN@ de @fastf1.internals.f1account.tokens@ (3.9.0). Si FastF1
-- lo cambia, esta copia se queda atrás.
fastf1ExpiryMargin :: NominalDiffTime
fastf1ExpiryMargin = 300

-- | Hasta cuándo sirve el token: @expires_at@ menos 'fastf1ExpiryMargin', solo de un
-- fichero con @version@ 1 (FastF1 ignora los de otra). __Solo devuelve la hora__: @value@
-- lleva datos del suscriptor y no se lee.
tokenExpiry :: BS.ByteString -> Maybe UTCTime
tokenExpiry raw = do
  (version, expires) <- either (const Nothing) Just (eitherDecodeStrict raw >>= parseEither fields)
  guard (version == (1 :: Int))
  pure (addUTCTime (negate fastf1ExpiryMargin) (posixSecondsToUTCTime (realToFrac (expires :: Double))))
  where
    fields = withObject "token" (\o -> (,) <$> o .: "version" <*> o .: "expires_at")

tokenFile :: BS.ByteString -> TokenFile
tokenFile = maybe TokenUnreadable TokenExpires . tokenExpiry
