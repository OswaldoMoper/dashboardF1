-- | Las columnas de Live Timing y cuáles se pueden cerrar desde «Columnas ▾»
-- (2026-10-02): «Pos» y «Driver» nunca, y de Gap, Interval, Last Lap, Best Lap y
-- Estado siempre queda al menos una abierta; «Team» se cierra sin condición. Puro;
-- quien pinta es 'Widgets.LiveTiming'.
module Common.Columns
  ( LiveColumn (..)
  , liveColumnsInOrder
  , liveColumnLabel
  , liveColumnClass
  , menuColumns
  , canClose
  , toggleColumn
  , shownColumns
  ) where

import           Data.Set  (Set)
import qualified Data.Set  as Set
import           Data.Text (Text)

-- | Una columna de la tabla.
data LiveColumn
  = ColPos | ColDriver | ColTeam | ColGap | ColInterval | ColLastLap | ColBestLap | ColState
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Las columnas en el orden de la tabla.
liveColumnsInOrder :: [LiveColumn]
liveColumnsInOrder = [minBound .. maxBound]

-- | La cabecera de cada columna.
liveColumnLabel :: LiveColumn -> Text
liveColumnLabel ColPos      = "Pos"
liveColumnLabel ColDriver   = "Driver"
liveColumnLabel ColTeam     = "Team"
liveColumnLabel ColGap      = "Gap"
liveColumnLabel ColInterval = "Interval"
liveColumnLabel ColLastLap  = "Last Lap"
liveColumnLabel ColBestLap  = "Best Lap"
liveColumnLabel ColState    = "Estado"

-- | La clase de las celdas de cada columna: la hoja las estila por clase y no por
-- posición, porque cerrar una columna movería las posiciones.
liveColumnClass :: LiveColumn -> Text
liveColumnClass ColPos      = "live-timing__pos"
liveColumnClass ColDriver   = "live-timing__driver"
liveColumnClass ColTeam     = "live-timing__team"
liveColumnClass ColGap      = "live-timing__gap"
liveColumnClass ColInterval = "live-timing__interval"
liveColumnClass ColLastLap  = "live-timing__last"
liveColumnClass ColBestLap  = "live-timing__best"
liveColumnClass ColState    = "live-timing__state"

-- | Las columnas que salen en «Columnas ▾»: todas menos «Pos» y «Driver».
menuColumns :: [LiveColumn]
menuColumns = filter (`notElem` [ColPos, ColDriver]) liveColumnsInOrder

-- | Las que cuentan para «siempre queda al menos una».
countsForOne :: [LiveColumn]
countsForOne = [ColGap, ColInterval, ColLastLap, ColBestLap, ColState]

-- | Si una columna abierta se puede cerrar con las cerradas que hay: no si es «Pos»
-- o «Driver», ni si es la última abierta de las que cuentan.
canClose :: Set LiveColumn -> LiveColumn -> Bool
canClose closed c
  | c `notElem` menuColumns = False
  | c `elem` countsForOne   = any (\o -> o /= c && Set.notMember o closed) countsForOne
  | otherwise               = True

-- | Abre (con 'True') o cierra una columna; cerrar lo que 'canClose' no deja no
-- cambia nada.
toggleColumn :: LiveColumn -> Bool -> Set LiveColumn -> Set LiveColumn
toggleColumn c True closed = Set.delete c closed
toggleColumn c False closed
  | canClose closed c = Set.insert c closed
  | otherwise         = closed

-- | Las columnas que se pintan, en orden.
shownColumns :: Set LiveColumn -> [LiveColumn]
shownColumns closed = filter (`Set.notMember` closed) liveColumnsInOrder
