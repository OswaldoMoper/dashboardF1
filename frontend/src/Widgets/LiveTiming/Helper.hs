-- | Lo puro de 'Widgets.LiveTiming': qué enseña la tarjeta según el refresco.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo, y un import de Reflex aquí lo deja sin compilar.
module Widgets.LiveTiming.Helper
  ( LiveState (..)
  , liveStateOf
  , liveViewOf
  , hasTable
  ) where

import           Common.Origin  (Sourced (..))
import           Common.Session (notRunYet)
import           Common.Shown   (Poll (..), delayWaitLabel)
import           Common.Types   (LiveTable (..), LiveTimingRow, RowBreak,
                                 overCutOff, rowBreaks)
import           Data.Text      (Text)

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
  | NotRun
    -- ^ La sesión elegida aún no se ha corrido ('Common.Session.notRunYet').
  | NotFound
    -- ^ La sesión elegida no existe: un @404@ y nada enseñado ('Common.Shown.pollNotFound').
  deriving (Eq, Show)

-- | Lo que se enseña a partir del estado del refresco. @chosen@ dice si la página tiene
-- una sesión elegida.
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
liveStateOf :: Bool -> Poll (Sourced LiveTable) -> LiveState
liveStateOf chosen p =
  case pollShown p of
    Just shown
      | notRunYet chosen (liveRows (srcValue shown)) -> NotRun
      | otherwise        -> loaded (srcValue shown)
    Nothing
      | pollNotFound p   -> NotFound
      | pollLastFailed p -> Failed
      | otherwise        -> Loading
  where
    loaded t =
      Loaded (liveRows t) (rowBreaks (liveSession t) (liveRows t))
        (overCutOff (liveSession t) (liveRows t))

-- | 'liveStateOf' con el diferido de @n@ segundos y los que faltan para tener algo tan
-- viejo (@wait@): mientras falten, el aviso de la espera, salvo que la sesión no exista,
-- que se dice al momento (2026-11-17 (l)), o que haya fallado sin que llegara nada, que
-- se dice como sin diferido (2026-11-18 (a)).
liveViewOf :: Bool -> Int -> Maybe Int -> Poll (Sourced LiveTable) -> LiveState
liveViewOf chosen n wait p =
  case (liveStateOf chosen p, wait) of
    (NotFound, _) -> NotFound
    (Failed, _)   -> Failed
    (_, Just w)   -> Waiting (delayWaitLabel n w)
    (s, Nothing)  -> s

-- | Si la tarjeta enseña la tabla, aunque sea sin filas: solo entonces se ve «Columnas ▾»
-- (2026-11-17 (g)).
hasTable :: LiveState -> Bool
hasTable Loaded {} = True
hasTable _         = False
