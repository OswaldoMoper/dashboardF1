-- | Bootstrap del backend: construye el 'Env' a partir de la 'Config'.
--
-- El 'Env' transporta la configuración y el estado mutable compartido entre
-- handlers. Fase 3: gana la cache en memoria (STM) de live timing, poblada por
-- 'Handler.Live.Context' con la última respuesta buena de OpenF1. Fase 4: la
-- cuarta caja, la de telemetría — importa más que las otras tres porque el
-- microservicio FastF1 es __nuestro__ y estará apagado la mayor parte del
-- tiempo. El pool de PostgreSQL y otros clientes externos aterrizan aquí
-- conforme lleguen.
module App where

import           Common.Types           (HistoricalStat, LiveTimingRow,
                                         TelemetryPoint, TyreStint)
import           Config                 (Config)
import           Control.Concurrent.STM (TVar, newTVarIO)

data Env = Env
  { envConfig          :: Config
  , envLiveCache       :: TVar (Maybe [LiveTimingRow])
    -- ^ Última respuesta buena de @/api/live@ (respaldo si OpenF1 falla).
  , envTyreCache       :: TVar (Maybe [TyreStint])
    -- ^ Última respuesta buena de @/api/tyre-strategy@ (respaldo si OpenF1 falla).
  , envHistoricalCache :: TVar (Maybe [HistoricalStat])
    -- ^ Última respuesta buena de @/api/historical@ (respaldo si Jolpica falla).
  , envTelemetryCache  :: TVar (Maybe [TelemetryPoint])
    -- ^ Última respuesta buena de @/api/telemetry@ (respaldo si el microservicio
    -- FastF1 no responde). Vacía mientras el 'Handler.Telemetry.Context' sirva
    -- solo el dummy.
  }

mkEnv :: Config -> IO Env
mkEnv cfg = do
  liveCache <- newTVarIO Nothing
  tyreCache <- newTVarIO Nothing
  historicalCache <- newTVarIO Nothing
  telemetryCache <- newTVarIO Nothing
  pure (Env cfg liveCache tyreCache historicalCache telemetryCache)
