-- | Área estadísticas históricas — orquestación del caso de uso.
--
-- Coordina los fetch a Jolpica ('Handler.Historical.Manager') y el mapeo puro
-- ('Handler.Historical.Helper'), con la cache STM del 'Env' como respaldo: intenta
-- el fetch real; si funciona, refresca la cache y devuelve; ante fallo o lista
-- vacía sirve la última respuesta buena; sin ninguna, el dummy (espejo de
-- 'Handler.Live.Context'/'Handler.TyreStrategy.Context').
module Handler.Historical.Context where

import           App                        (Env (..))
import           Common.Types               (HistoricalStat (..), StatEntity (..))
import           Control.Concurrent.STM     (atomically, readTVarIO, writeTVar)
import           Control.Exception          (SomeException, try)
import           Data.Maybe                 (fromMaybe)
import           Handler.Historical.Helper  (assembleConstructorStats, assembleStats)
import qualified Handler.Historical.Manager as Manager

getHistorical :: Env -> IO [HistoricalStat]
getHistorical env = do
  result <- try fetchStats :: IO (Either SomeException [HistoricalStat])
  case result of
    Right rows | not (null rows) -> do
      atomically (writeTVar (envHistoricalCache env) (Just rows))
      pure rows
    _ -> do
      cached <- readTVarIO (envHistoricalCache env)
      pure (fromMaybe dummy cached)

-- | Las __dos__ clasificaciones en una sola lista, en orden determinista (pilotos y
-- luego constructores). Vive dentro del mismo 'try' del llamador a propósito: si
-- cualquiera de los dos fetch falla, se degrada a la última respuesta buena
-- __completa__ en vez de servir media lista.
fetchStats :: IO [HistoricalStat]
fetchStats = do
  drivers      <- assembleStats <$> Manager.fetchStandings
  constructors <- assembleConstructorStats <$> Manager.fetchConstructorStandings
  pure (drivers <> constructors)

-- | Estadísticas dummy (respaldo cuando Jolpica nunca dio datos). Misma forma que
-- emiten 'assembleStats' y 'assembleConstructorStats' — identidad estructurada,
-- marca de entidad y unidades @points@\/@wins@ — y con __las dos entidades__, para
-- que el filtro del widget sea ejercitable sin red.
dummy :: [HistoricalStat]
dummy =
  [ HistoricalStat DriverStat "VER" "Max" "Verstappen" 393 "points"
  , HistoricalStat DriverStat "VER" "Max" "Verstappen" 9 "wins"
  , HistoricalStat DriverStat "NOR" "Lando" "Norris" 331 "points"
  , HistoricalStat ConstructorStat "red_bull" "" "Red Bull" 712 "points"
  , HistoricalStat ConstructorStat "mclaren" "" "McLaren" 640 "points"
  ]
