-- | Bootstrap del backend: construye el 'Env' a partir de la 'Config' (INFRA).
--
-- El 'Env' transporta la configuración y el estado mutable compartido entre
-- handlers. Fase 3: gana la cache en memoria (STM) de live timing, poblada por
-- 'Handler.Live.Context' con la última respuesta buena de OpenF1. El pool de
-- PostgreSQL y otros clientes externos aterrizan aquí conforme lleguen.
module App where

import           Common.Types           (LiveTimingRow, TyreStint)
import           Config                 (Config)
import           Control.Concurrent.STM (TVar, newTVarIO)

data Env = Env
  { envConfig    :: Config
  , envLiveCache :: TVar (Maybe [LiveTimingRow])
    -- ^ Última respuesta buena de @/api/live@ (respaldo si OpenF1 falla).
  , envTyreCache :: TVar (Maybe [TyreStint])
    -- ^ Última respuesta buena de @/api/tyre-strategy@ (respaldo si OpenF1 falla).
  }

mkEnv :: Config -> IO Env
mkEnv cfg = do
  liveCache <- newTVarIO Nothing
  tyreCache <- newTVarIO Nothing
  pure (Env cfg liveCache tyreCache)
