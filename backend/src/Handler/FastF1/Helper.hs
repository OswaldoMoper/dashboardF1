-- | Lo puro que comparten los consumidores del microservicio FastF1
-- ('Handler.Comparison' y 'Handler.Drivers'): la escalera con procedencia de las áreas
-- que guardan lo traído por clave ('fastf1Step'). Y, para quien juzga la cuenta de F1TV
-- con la que FastF1 abre el archivo, lo que dice el fichero del token. La lectura de sus
-- @QueryParam@ vive en 'Handler.Query.Helper', con la de las demás áreas.
module Handler.FastF1.Helper
  ( fastf1Step
  , sessionTimeout
  , chosenSessionTimeout
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
import           Data.Time.Clock       (NominalDiffTime, UTCTime, addUTCTime)
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           Provenance            (Provenanced (..), isoInstant)

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

-- | El techo de un intento al microservicio para una sesión, en segundos: con @latest@, el
-- de la configuración; con una sesión elegida, 'chosenSessionTimeout', o el de la
-- configuración si es mayor (2026-11-17 (f)).
sessionTimeout :: Int -> Text -> Int
sessionTimeout configured key
  | key == "latest" = configured
  | otherwise       = max configured chosenSessionTimeout

-- | El techo con sesión elegida: FastF1 carga una sesión que no tiene en memoria en
-- 8–13 s, y la página espera 35 (2026-11-12 (d)).
chosenSessionTimeout :: Int
chosenSessionTimeout = 30

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
