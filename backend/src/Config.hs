-- | Configuración del backend, leída de variables de entorno al arrancar (INFRA).
--
-- Una variable que falta, o un número que no se puede leer, cae al default __en
-- silencio__. La dirección del microservicio son dos campos y no un URL
-- (2026-07-31). Los techos de duración se cambian sin recompilar (2026-08-04,
-- 2026-08-19); el número de reintentos no
-- ('Handler.PublicApi.Manager.publicApiRetries').
--
-- __Lleva además una pieza viva que no sale de ninguna variable__: la memoria del
-- freno de OpenF1, creada aquí porque la configuración es lo que reciben todas las
-- peticiones ('Handler.OpenF1.Manager.fetchListWith').
module Config where

import           Control.Concurrent.MVar (MVar, newMVar)
import           Data.Maybe              (fromMaybe)
import           Data.Text               (Text)
import qualified Data.Text               as T
import           Data.Time.Clock         (UTCTime)
import           System.Environment      (lookupEnv)
import           Text.Read               (readMaybe)

data Config = Config
  { cfgPort             :: Int      -- ^ PORT (default 8080)
  , cfgStaticDir        :: FilePath -- ^ STATIC_DIR: bundle del frontend a servir (default @result@)
  , cfgTelemetryHost    :: Text     -- ^ TELEMETRY_HOST: host del microservicio FastF1 (default @127.0.0.1@)
  , cfgTelemetryPort    :: Int      -- ^ TELEMETRY_PORT: puerto del microservicio FastF1 (default 8000)
  , cfgTelemetrySocket  :: Maybe FilePath -- ^ TELEMETRY_SOCKET: socket Unix del microservicio; si está, sustituye a host y puerto
  , cfgTelemetryTimeout :: Int   -- ^ TELEMETRY_TIMEOUT: segundos de espera por intento (default 5)
  , cfgPublicApiTimeout :: Int   -- ^ PUBLIC_API_TIMEOUT: segundos de espera por intento en OpenF1/Jolpica (default 5)
  , cfgOpenF1Log        :: Bool     -- ^ OPENF1_LOG: con cualquier valor no vacío, una línea por cada petición a OpenF1 y no solo por sus fallos
  , cfgOpenF1Brake      :: MVar [UTCTime] -- ^ las horas de las últimas salidas a OpenF1, la más reciente primero ('Handler.OpenF1.Helper.brakeWait')
  }

-- | Lo que la línea de arranque del backend dice tras su instante, y antes del puerto.
-- Es por lo que el automatismo reconoce en el log dónde empieza la instancia que corre
-- ('Auto.Helper.sinceLastStart').
startupMark :: String
startupMark = " F1 Dashboard backend en http://localhost:"

loadConfig :: IO Config
loadConfig = do
  mport  <- lookupEnv "PORT"
  mdir   <- lookupEnv "STATIC_DIR"
  mhost  <- lookupEnv "TELEMETRY_HOST"
  mtport <- lookupEnv "TELEMETRY_PORT"
  msock  <- lookupEnv "TELEMETRY_SOCKET"
  mtout  <- lookupEnv "TELEMETRY_TIMEOUT"
  mptout <- lookupEnv "PUBLIC_API_TIMEOUT"
  mlog   <- lookupEnv "OPENF1_LOG"
  brake  <- newMVar []
  pure
    Config
      { cfgPort          = fromMaybe 8080 (mport >>= readMaybe)
      , cfgStaticDir     = fromMaybe "result" mdir
      , cfgTelemetryHost = maybe "127.0.0.1" T.pack mhost
      , cfgTelemetryPort = fromMaybe 8000 (mtport >>= readMaybe)
      , cfgTelemetrySocket = telemetrySocket msock
        -- 5 s sirve al servicio caído (degradado rápido). Una sesión sin cargar
        -- necesita más ('Handler.FastF1.Manager.fastf1Timeout').
      , cfgTelemetryTimeout = fromMaybe 5 (mtout >>= readMaybe)
        -- 5 s deja el techo total en 15 s con los 3 intentos de
        -- 'Handler.PublicApi.Manager', y sobra sobre el camino feliz medido
        -- (0.15–3.4 s). Subirlo si una de las dos APIs va lenta; bajarlo
        -- convierte una red viva pero lenta en un dummy.
      , cfgPublicApiTimeout = fromMaybe 5 (mptout >>= readMaybe)
      , cfgOpenF1Log = openF1Log mlog
      , cfgOpenF1Brake = brake
      }

-- | El socket del microservicio a partir de @TELEMETRY_SOCKET@. Vacía cuenta como no
-- definida, y entonces el backend habla por TCP.
telemetrySocket :: Maybe String -> Maybe FilePath
telemetrySocket (Just "") = Nothing
telemetrySocket msock     = msock

-- | Si @OPENF1_LOG@ enciende el registro completo. Vacía cuenta como no definida,
-- igual que en 'telemetrySocket'.
openF1Log :: Maybe String -> Bool
openF1Log = maybe False (not . null)
