-- | Área estadísticas históricas — orquestación del caso de uso.
--
-- Coordina el fetch a Jolpica ('Handler.Historical.Manager') y el mapeo puro
-- ('Handler.Historical.Helper'), con cache STM en 'Env' y respaldo al dummy.
-- Paso intermedio (Commit A): aún sin red, devuelve el dummy; el @try@→cache→dummy
-- llega en el Commit B (espejo de 'Handler.Live.Context'/'Handler.TyreStrategy.Context').
module Handler.Historical.Context
  ( getHistorical
  ) where

import           App          (Env)
import           Common.Types (HistoricalStat (..))

getHistorical :: Env -> IO [HistoricalStat]
getHistorical _env = pure dummy

-- | Estadísticas dummy (respaldo cuando Jolpica no da datos).
dummy :: [HistoricalStat]
dummy =
  [ HistoricalStat "Wins" 63 "races"
  , HistoricalStat "Pole positions" 44 "quali"
  , HistoricalStat "Fastest laps" 34 "laps"
  ]
