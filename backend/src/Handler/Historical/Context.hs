-- | Área estadísticas históricas — orquestación del caso de uso.
--
-- Coordina los fetch a Jolpica ('Handler.Historical.Manager') y el mapeo puro
-- ('Handler.Historical.Helper'). Sin @?session=@, con la cache STM del 'Env': lo guardado
-- hace menos de 'Handler.Historical.Helper.historicalFreshFor' se sirve sin volver a
-- Jolpica; si no, intenta el fetch real; si funciona, refresca la cache y devuelve; ante
-- fallo o lista vacía, 'Handler.Historical.Helper.servedToday'. Con una clave, 'getAfter'.
module Handler.Historical.Context where

import           App                        (Env (..))
import           Common.Types               (HistoricalStat)
import           Config                     (Config)
import           Control.Concurrent.STM     (atomically, modifyTVar',
                                             readTVarIO, writeTVar)
import           Control.Exception          (SomeException, throwIO, try)
import qualified Data.Map.Strict            as Map
import           Data.Text                  (Text)
import           Data.Time.Clock            (getCurrentTime)
import           Handler.Historical.Helper  (StandingsAt (..),
                                             assembleConstructorStats,
                                             assembleStats, keptStandings,
                                             keptToday, resolveStandings,
                                             servedToday)
import qualified Handler.Historical.Manager as Manager
import           Outcome                    (Outcome (..))
import           Sync                       (joinFlight)

-- | Lo que pide @?session=@ ('resolveStandings'): sin él, la temporada a hoy
-- ('getToday'); con una clave, la clasificación tras su ronda ('getAfter').
getHistorical :: Env -> Maybe Text -> IO (Outcome [HistoricalStat])
getHistorical env session = case resolveStandings session of
  Left rejection               -> pure (Refused rejection)
  Right StandingsToday         -> Served <$> getToday env
  Right (StandingsAfter y rnd) -> Served <$> getAfter env y rnd

-- | Tras esa ronda: la guardada si aún se sirve ('keptStandings'); si no, la de Jolpica, que
-- se guarda con su hora. Antes de la primera ronda o en una aún no corrida, la lista vacía,
-- que es la verdad y no un fallo. Si Jolpica falla y no hay nada que servir, la excepción
-- sube: la página ve el error y no un ejemplo inventado. Las que llegan a la vez con la
-- misma ronda reciben un solo resultado ('App.envHistoricalFlights').
getAfter :: Env -> Int -> Int -> IO [HistoricalStat]
getAfter env year rnd
  | rnd < 1 = pure []
  | otherwise = joinFlight (envHistoricalFlights env) (Just (year, rnd)) $ do
      now <- getCurrentTime
      cached <- Map.lookup (year, rnd) <$> readTVarIO (envStandingsCache env)
      case keptStandings now =<< cached of
        Just rows -> pure rows
        Nothing -> do
          rows <- fetchStatsAfter (envConfig env) year rnd
          atomically (modifyTVar' (envStandingsCache env) (Map.insert (year, rnd) (now, rows)))
          pure rows

-- | 'fetchStats' tras una ronda: los mismos dos GET y el mismo orden.
fetchStatsAfter :: Config -> Int -> Int -> IO [HistoricalStat]
fetchStatsAfter cfg year rnd = do
  drivers      <- assembleStats <$> Manager.fetchStandingsAfter cfg year rnd
  constructors <- assembleConstructorStats <$> Manager.fetchConstructorStandingsAfter cfg year rnd
  pure (drivers <> constructors)

-- | La temporada a hoy, sin @?session=@: la guardada mientras aún se sirve ('keptToday');
-- si no, la de Jolpica, que se guarda con su hora cuando trae alguna fila. Lo que se sirve
-- cuando falla o viene vacía, 'servedToday': si Jolpica falla y no hay nada guardado, la
-- excepción sube, como en 'getAfter'. Las que llegan a la vez reciben un solo resultado
-- ('App.envHistoricalFlights').
getToday :: Env -> IO [HistoricalStat]
getToday env = joinFlight (envHistoricalFlights env) Nothing $ do
  now <- getCurrentTime
  cached <- readTVarIO (envHistoricalCache env)
  case keptToday now cached of
    Just rows -> pure rows
    Nothing -> do
      result <-
        try (fetchStats (envConfig env)) :: IO (Either SomeException [HistoricalStat])
      case result of
        Right rows | not (null rows) ->
          atomically (writeTVar (envHistoricalCache env) (Just (now, rows)))
        _ -> pure ()
      either throwIO pure (servedToday cached result)

-- | Las __dos__ clasificaciones en una sola lista, en orden determinista (pilotos y
-- luego constructores). Vive dentro del mismo 'try' del llamador a propósito: si
-- cualquiera de los dos fetch falla, se degrada a la última respuesta buena
-- __completa__ en vez de servir media lista.
--
-- Que sean 2 GET en serie hace que su techo de duración sea el __doble__ que el de
-- las otras dos áreas; el techo por GET lo pone la
-- 'Config' vía 'Handler.PublicApi.Manager'.
fetchStats :: Config -> IO [HistoricalStat]
fetchStats cfg = do
  drivers      <- assembleStats <$> Manager.fetchStandings cfg
  constructors <- assembleConstructorStats <$> Manager.fetchConstructorStandings cfg
  pure (drivers <> constructors)
