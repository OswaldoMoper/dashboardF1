-- | Configuración del backend desde variables de entorno (INFRA).
--
-- Fase 2: el puerto (@PORT@, default 8080) y el directorio del bundle del
-- frontend (@STATIC_DIR@, default @result@) que el backend sirve como SPA.
-- Fase 4: la dirección del microservicio FastF1 en __dos__ campos
-- (@TELEMETRY_HOST@, @TELEMETRY_PORT@) y no como URL completo — el cliente @req@
-- compone el @Url@ por piezas y lleva el puerto en una @Option@, así que parsear
-- un URL exigiría @modern-uri@ (dependencia nueva) más el manejo del fallo de
-- parseo (2026-07-31). Credenciales de PostgreSQL y
-- secretos aterrizan aquí con el mismo patrón @loadConfig@ conforme lleguen.
module Config where

import           Data.Maybe         (fromMaybe)
import           Data.Text          (Text)
import qualified Data.Text          as T
import           System.Environment (lookupEnv)
import           Text.Read          (readMaybe)

data Config = Config
  { cfgPort          :: Int      -- ^ PORT (default 8080)
  , cfgStaticDir     :: FilePath -- ^ STATIC_DIR: bundle del frontend a servir (default @result@)
  , cfgTelemetryHost :: Text     -- ^ TELEMETRY_HOST: host del microservicio FastF1 (default @127.0.0.1@)
  , cfgTelemetryPort :: Int      -- ^ TELEMETRY_PORT: puerto del microservicio FastF1 (default 8000)
  }
  deriving (Show)

loadConfig :: IO Config
loadConfig = do
  mport  <- lookupEnv "PORT"
  mdir   <- lookupEnv "STATIC_DIR"
  mhost  <- lookupEnv "TELEMETRY_HOST"
  mtport <- lookupEnv "TELEMETRY_PORT"
  pure
    Config
      { cfgPort          = fromMaybe 8080 (mport >>= readMaybe)
      , cfgStaticDir     = fromMaybe "result" mdir
        -- 'lookupEnv' da 'String', no 'Text': de ahí el 'T.pack' en vez del
        -- 'fromMaybe' directo de los otros campos.
      , cfgTelemetryHost = maybe "127.0.0.1" T.pack mhost
      , cfgTelemetryPort = fromMaybe 8000 (mtport >>= readMaybe)
      }
