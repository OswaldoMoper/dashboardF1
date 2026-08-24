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
import           Config                     (Config)
import           Control.Concurrent.STM     (atomically, readTVarIO, writeTVar)
import           Control.Exception          (SomeException, try)
import           Data.Maybe                 (fromMaybe)
import           Handler.Historical.Helper  (assembleConstructorStats, assembleStats)
import qualified Handler.Historical.Manager as Manager

getHistorical :: Env -> IO [HistoricalStat]
getHistorical env = do
  result <-
    try (fetchStats (envConfig env)) :: IO (Either SomeException [HistoricalStat])
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
--
-- Que sean 2 GET en serie hace que su techo de duración sea el __doble__ que el de
-- las otras dos áreas; el techo por GET lo pone la
-- 'Config' vía 'Handler.PublicApi.Manager'.
fetchStats :: Config -> IO [HistoricalStat]
fetchStats cfg = do
  drivers      <- assembleStats <$> Manager.fetchStandings cfg
  constructors <- assembleConstructorStats <$> Manager.fetchConstructorStandings cfg
  pure (drivers <> constructors)

-- | Estadísticas dummy (respaldo cuando Jolpica nunca dio datos). Misma forma que
-- emiten 'assembleStats' y 'assembleConstructorStats' — identidad estructurada,
-- marca de entidad y una fila por entidad — y con __las dos entidades__, para que
-- las dos tablas del widget sean ejercitables sin red.
--
-- __Norris lleva 'hsWins' en 'Nothing' a propósito__, y es lo único del dummy que
-- no imita a Jolpica: medido el 2026-08-24, Jolpica publica @wins@ para las 34
-- entidades, así que la rama de ausencia __no se alcanza con dato real__. Si el
-- dummy tampoco la trajera, la única forma de ver lo que el widget pinta cuando
-- faltan las victorias sería editar código.
dummy :: [HistoricalStat]
dummy =
  [ HistoricalStat DriverStat "VER" "Max" "Verstappen" 393 (Just 9)
  , HistoricalStat DriverStat "NOR" "Lando" "Norris" 331 Nothing
  , HistoricalStat ConstructorStat "red_bull" "" "Red Bull" 712 (Just 12)
  , HistoricalStat ConstructorStat "mclaren" "" "McLaren" 640 (Just 9)
  ]
