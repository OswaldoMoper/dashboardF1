-- | Configuración del backend desde variables de entorno (INFRA).
--
-- Fase 2: el puerto (@PORT@, default 8080) y el directorio del bundle del
-- frontend (@STATIC_DIR@, default @result@) que el backend sirve como SPA.
-- Credenciales de PostgreSQL, secretos y URLs de servicios externos
-- (OpenF1/Jolpica/FastF1) aterrizan aquí con el mismo patrón @loadConfig@
-- conforme lleguen (Fases 3–6).
module Config where

import           Data.Maybe         (fromMaybe)
import           System.Environment (lookupEnv)
import           Text.Read          (readMaybe)

data Config = Config
  { cfgPort      :: Int      -- ^ PORT (default 8080)
  , cfgStaticDir :: FilePath -- ^ STATIC_DIR: bundle del frontend a servir (default @result@)
  }
  deriving (Show)

loadConfig :: IO Config
loadConfig = do
  mport <- lookupEnv "PORT"
  mdir  <- lookupEnv "STATIC_DIR"
  pure
    Config
      { cfgPort      = fromMaybe 8080 (mport >>= readMaybe)
      , cfgStaticDir = fromMaybe "result" mdir
      }
