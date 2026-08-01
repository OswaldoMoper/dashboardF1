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
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Text              (Text)

data Env = Env
  { envConfig          :: Config
  , envLiveCache       :: TVar (Maybe [LiveTimingRow])
    -- ^ Última respuesta buena de @/api/live@ (respaldo si OpenF1 falla).
  , envTyreCache       :: TVar (Maybe [TyreStint])
    -- ^ Última respuesta buena de @/api/tyre-strategy@ (respaldo si OpenF1 falla).
  , envHistoricalCache :: TVar (Maybe [HistoricalStat])
    -- ^ Última respuesta buena de @/api/historical@ (respaldo si Jolpica falla).
  , envTelemetryCache  :: TVar (Map (Text, Text) [TelemetryPoint])
    -- ^ Última respuesta buena de @/api/telemetry@ __por clave__ @(sesión,
    -- piloto)@ ya resuelta (respaldo si el microservicio FastF1 no responde).
    --
    -- Es la única de las cuatro cajas que no es un @Maybe@, y la diferencia no
    -- es de rendimiento sino de __correctitud__: desde que el endpoint acepta
    -- parámetros (2026-08-01), una caja única serviría la
    -- última respuesta buena de @all@ a quien pidió un piloto concreto — datos
    -- de otros coches presentados como suyos. Con clave, una combinación nunca
    -- pedida degrada al dummy, que es honesto.
  }

mkEnv :: Config -> IO Env
mkEnv cfg = do
  liveCache <- newTVarIO Nothing
  tyreCache <- newTVarIO Nothing
  historicalCache <- newTVarIO Nothing
  telemetryCache <- newTVarIO Map.empty
  pure (Env cfg liveCache tyreCache historicalCache telemetryCache)
