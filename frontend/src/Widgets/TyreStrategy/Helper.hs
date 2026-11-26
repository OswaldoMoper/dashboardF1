-- | Lo puro de 'Widgets.TyreStrategy': qué enseña la tarjeta según el refresco.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo, y un import de Reflex aquí lo deja sin compilar.
module Widgets.TyreStrategy.Helper
  ( TyreState (..)
  , tyreStateOf
  , tyreViewOf
  ) where

import           Common.Origin       (Sourced (..))
import           Common.Session      (notRunYet)
import           Common.Shown        (Poll (..), delayWaitLabel)
import           Common.Types        (LiveTable (..))
import           Common.TyreStrategy (SetRow, carriesStints, setRows,
                                      stintScale)
import           Data.Text           (Text)

-- | Qué enseña la tarjeta.
data TyreState
  = Loading
  | Failed
  | Waiting Text
    -- ^ Con retraso, mientras nada es tan viejo: el aviso de la espera.
  | NoStints
    -- ^ La tabla no trae stints.
  | NotRun
    -- ^ La sesión elegida aún no se ha corrido ('Common.Session.notRunYet').
  | NotFound
    -- ^ La sesión elegida no existe: un @404@ y nada enseñado ('Common.Shown.pollNotFound').
  | Loaded Int [SetRow]
    -- ^ La escala ('Common.TyreStrategy.stintScale') y las filas.
  deriving (Eq, Show)

-- | Lo que se enseña a partir del estado del refresco, como
-- 'Widgets.LiveTiming.Helper.liveStateOf'. @chosen@ dice si la página tiene una sesión
-- elegida.
tyreStateOf :: Bool -> Poll (Sourced LiveTable) -> TyreState
tyreStateOf chosen p =
  case pollShown p of
    Just shown
      | notRunYet chosen (liveRows (srcValue shown)) -> NotRun
      | carriesStints chosen (srcSource shown) (liveStints (srcValue shown)) -> loaded (srcValue shown)
      | otherwise -> NoStints
    Nothing
      | pollNotFound p   -> NotFound
      | pollLastFailed p -> Failed
      | otherwise        -> Loading
  where
    loaded t = Loaded (stintScale (liveSession t) (liveStints t)) (setRows t)

-- | 'tyreStateOf' con el diferido, como 'Widgets.LiveTiming.Helper.liveViewOf'.
tyreViewOf :: Bool -> Int -> Maybe Int -> Poll (Sourced LiveTable) -> TyreState
tyreViewOf chosen n wait p =
  case (tyreStateOf chosen p, wait) of
    (NotFound, _) -> NotFound
    (Failed, _)   -> Failed
    (_, Just w)   -> Waiting (delayWaitLabel n w)
    (s, Nothing)  -> s
