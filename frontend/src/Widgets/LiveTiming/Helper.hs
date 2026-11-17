-- | Lo puro de 'Widgets.LiveTiming': qué enseña la tarjeta según el refresco.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo, y un import de Reflex aquí lo deja sin compilar.
module Widgets.LiveTiming.Helper
  ( LiveState (..)
  , liveStateOf
  ) where

import           Common.Origin (Sourced (..))
import           Common.Shown  (Poll (..))
import           Common.Types  (LiveTable (..), LiveTimingRow, RowBreak,
                                overCutOff, rowBreaks)
import           Data.Text     (Text)

-- | Qué enseña la tarjeta. 'Failed' (no 'Error') para no chocar con
-- nombres de @base@\/@Prelude@.
data LiveState
  = Loading
  | Failed
  | Loaded [LiveTimingRow] [Maybe RowBreak] [Bool]
    -- ^ Las filas, la raya que va encima de cada una ('Common.Types.rowBreaks') y
    -- si va fuera del 107 % ('Common.Types.overCutOff').
  | Waiting Text
    -- ^ Con retraso, mientras nada es tan viejo: el aviso de la espera.
  deriving (Eq, Show)

-- | Lo que se enseña a partir del estado del refresco.
--
-- __Deja fuera a propósito si hay una petición en vuelo.__ Si entrara, la tabla se
-- volvería a montar al pedir y otra vez al llegar la respuesta —dos veces cada
-- diez segundos— aunque el dato no hubiera cambiado. Con @holdUniqDyn@ encima, se
-- monta solo cuando cambia lo que se ve.
--
-- __Se queda con las filas y, de la sesión, solo con sus rayas y el 107 %__
-- ('Common.Types.rowBreaks', 'Common.Types.overCutOff'): de la sesión se encarga la banda de la página
-- ('Pages.Dashboard.sessionBand'), y meterla entera aquí haría remontar la tabla
-- cada vez que avanzara el reloj.
liveStateOf :: Poll (Sourced LiveTable) -> LiveState
liveStateOf p =
  case pollShown p of
    Just shown           -> loaded (srcValue shown)
    Nothing
      | pollLastFailed p -> Failed
      | otherwise        -> Loading
  where
    loaded t =
      Loaded (liveRows t) (rowBreaks (liveSession t) (liveRows t))
        (overCutOff (liveSession t) (liveRows t))
