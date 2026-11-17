-- | Lo puro de 'Widgets.TyreStrategy': qué enseña la tarjeta según el refresco.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo, y un import de Reflex aquí lo deja sin compilar.
module Widgets.TyreStrategy.Helper
  ( TyreState (..)
  , tyreStateOf
  ) where

import           Common.Origin       (Source (..), Sourced (..))
import           Common.Shown        (Poll (..))
import           Common.Types        (LiveTable (..))
import           Common.TyreStrategy (SetRow, setRows, stintScale)
import           Data.Text           (Text)

-- | Qué enseña la tarjeta.
data TyreState
  = Loading
  | Failed
  | Waiting Text
    -- ^ Con retraso, mientras nada es tan viejo: el aviso de la espera.
  | NoStints
    -- ^ La tabla no sale del feed.
  | Loaded Int [SetRow]
    -- ^ La escala ('Common.TyreStrategy.stintScale') y las filas.
  deriving (Eq, Show)

-- | Lo que se enseña a partir del estado del refresco, como
-- 'Widgets.LiveTiming.Helper.liveStateOf'.
tyreStateOf :: Poll (Sourced LiveTable) -> TyreState
tyreStateOf p =
  case pollShown p of
    Just shown
      | srcSource shown /= Just Feed -> NoStints
      | otherwise                    -> loaded (srcValue shown)
    Nothing
      | pollLastFailed p -> Failed
      | otherwise        -> Loading
  where
    loaded t = Loaded (stintScale (liveSession t) (liveStints t)) (setRows t)
