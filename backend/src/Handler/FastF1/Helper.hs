-- | Lo puro que comparten los consumidores del microservicio FastF1
-- ('Handler.Comparison' y 'Handler.Drivers'): la lectura
-- de los @QueryParam@ que viajan como segmentos de su URL, y la escalera con procedencia
-- de las áreas que guardan lo traído por clave ('fastf1Step'). Y, para quien juzga la
-- cuenta de F1TV con la que FastF1 abre el archivo, lo que dice el fichero del token.
module Handler.FastF1.Helper
  ( queryParam
  , sessionParam
  , fastf1Step
  , TokenFile (..)
  , tokenExpiry
  , tokenFile
  , accountFrom
  ) where

import           Common.Origin         (Origin (..), Source (..))
import           Common.Types          (F1TVAccount (..))
import           Control.Monad         (guard)
import           Data.Aeson            (eitherDecodeStrict, withObject, (.:))
import           Data.Aeson.Types      (parseEither)
import qualified Data.ByteString       as BS
import           Data.Map.Strict       (Map)
import qualified Data.Map.Strict       as Map
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Data.Time.Clock       (NominalDiffTime, UTCTime, addUTCTime)
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           Outcome               (Rejection (..))
import           Provenance            (Provenanced (..), isoInstant)

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

-- | El peldaño de la escalera de un consumidor de FastF1 y la cache que queda, para una
-- clave: lo traído ('Nothing' si el fetch falló) que pasa @valid@ se sirve fresco y se
-- guarda con la hora de ahora; si no, lo guardado de __esa misma clave__, con su hora, y
-- la cache no cambia. 'Nothing' en el primer componente es que no hay nada que servir, y
-- quien llama pone el ejemplo.
fastf1Step
  :: Ord k
  => (a -> Bool)
  -> UTCTime
  -> k
  -> Maybe a
  -> Map k (UTCTime, a)
  -> (Maybe (Provenanced a), Map k (UTCTime, a))
fastf1Step valid now key (Just x) cache
  | valid x = (Just (Provenanced Fresh (Just FastF1) Nothing x), Map.insert key (now, x) cache)
fastf1Step _ _ key _ cache = (fromEntry <$> Map.lookup key cache, cache)
  where
    fromEntry (fetchedAt, x) = Provenanced Cached (Just FastF1) (Just fetchedAt) x

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

-- | Lo que la página sabe de la cuenta en ese instante. Caducada desde la hora de
-- 'tokenExpiry' inclusive, el mismo corte que la comprobación del automatismo.
accountFrom :: UTCTime -> TokenFile -> F1TVAccount
accountFrom _ TokenMissing    = F1TVMissing
accountFrom _ TokenUnreadable = F1TVUnreadable
accountFrom now (TokenExpires e)
  | e <= now  = F1TVExpired (isoInstant e)
  | otherwise = F1TVValid (isoInstant e)
