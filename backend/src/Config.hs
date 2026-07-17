-- | Configuración del backend desde variables de entorno (INFRA).
--
-- Fase 1: solo el puerto (@PORT@, default 8080). Credenciales de PostgreSQL,
-- secretos y URLs de servicios externos (OpenF1/Jolpica/FastF1) aterrizan aquí
-- con el mismo patrón @loadConfig@ conforme lleguen (Fases 3–6).
module Config where

import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

newtype Config = Config
  { cfgPort :: Int -- ^ PORT (default 8080)
  }
  deriving (Show)

loadConfig :: IO Config
loadConfig = do
  mport <- lookupEnv "PORT"
  pure (Config (fromMaybe 8080 (mport >>= readMaybe)))
