-- | Lo puro de 'Widgets.Historical': qué filas son de cada clasificación y cómo se
-- escribe cada cifra.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo.
module Widgets.Historical.Helper
  ( onlyEntity
  , pointsLabel
  , winsLabel
  , positionLabel
  ) where

import           Common.Format (formatFixed, formatTrimmed, noData)
import           Common.Types  (HistoricalStat (..), StatEntity)
import           Data.Text     (Text)

-- | Las filas de una sola clasificación, sacadas de la lista heterogénea que sirve
-- @\/api\/historical@. Puro, y el único punto del módulo donde se lee 'hsEntity'.
onlyEntity :: StatEntity -> [HistoricalStat] -> [HistoricalStat]
onlyEntity entity = filter ((== entity) . hsEntity)

-- | Puntos de la fila, sin el @.0@ que sobra.
--
-- 'Common.Format.formatTrimmed' y no 'Common.Format.formatFixed' porque el decimal
-- es la excepción: Jolpica publica los puntos como 'Double' —la F1 reparte medios
-- puntos— pero casi siempre son enteros, y hasta el 2026-08-26 la columna mostraba
-- @393.0@. Un decimal es todo lo que el reglamento permite.
pointsLabel :: HistoricalStat -> Text
pointsLabel = formatTrimmed 1 . hsPoints

-- | Victorias de la fila, o una raya cuando Jolpica no las publica.
--
-- La raya __no es un cero__ y la distinción es la que 'Common.Types.hsWins' existe
-- para conservar: pintar @0@ afirmaría que la entidad no ganó ninguna carrera,
-- que es un dato que nadie dio. Con dato real no se ve: Jolpica publica @wins@
-- siempre, medido el 2026-08-24 y de nuevo el 2026-08-26.
--
-- La raya viene de 'Common.Format.noData' y no de un literal local: es la misma que
-- emite la rama de no-finito del formateador, así que una victoria ausente y una
-- cifra imposible se ven igual —que es lo correcto, porque las dos son «nadie dio
-- esta cifra»— y el carácter se define una sola vez en el repo.
winsLabel :: HistoricalStat -> Text
winsLabel = maybe noData (formatFixed 0) . hsWins

-- | Puesto de la fila, o la raya cuando Jolpica no da un número (un excluido): la
-- misma raya que 'winsLabel', porque las dos son «nadie dio esta cifra».
positionLabel :: HistoricalStat -> Text
positionLabel = maybe noData (formatFixed 0 . fromIntegral) . hsPosition
