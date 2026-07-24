-- | Área estadísticas históricas — orquestación del caso de uso.
--
-- Coordina el fetch a Jolpica ('Handler.Historical.Manager') y el mapeo puro
-- ('Handler.Historical.Helper'), con la cache STM del 'Env' como respaldo: intenta
-- el fetch real; si funciona, refresca la cache y devuelve; ante fallo o lista
-- vacía sirve la última respuesta buena; sin ninguna, el dummy (espejo de
-- 'Handler.Live.Context'/'Handler.TyreStrategy.Context').
module Handler.Historical.Context where

import           App                        (Env (..))
import           Common.Types               (HistoricalStat (..))
import           Control.Concurrent.STM     (atomically, readTVarIO, writeTVar)
import           Control.Exception          (SomeException, try)
import           Data.Maybe                 (fromMaybe)
import           Handler.Historical.Helper  (assembleStats)
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

fetchStats :: IO [HistoricalStat]
fetchStats = assembleStats <$> Manager.fetchStandings

-- | Estadísticas dummy (respaldo cuando Jolpica nunca dio datos).
dummy :: [HistoricalStat]
dummy =
  [ HistoricalStat "Wins" 63 "races"
  , HistoricalStat "Pole positions" 44 "quali"
  , HistoricalStat "Fastest laps" 34 "laps"
  ]
