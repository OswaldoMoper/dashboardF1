-- | Lo puro de 'Pages.Dashboard': la clase y el estilo de cada slot.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo.
module Pages.Dashboard.Helper
  ( slotAttrs
  , slotClass
  ) where

import           Common.Carry  (Held (..), Scene (..), heldStyle)
import           Common.Layout (slotStyle, touchesTopRight)
import           Common.Types  (WidgetConfig (..))
import           Data.List     (find)
import           Data.Map      (Map)
import qualified Data.Map      as Map
import           Data.Maybe    (fromMaybe)
import           Data.Text     (Text)

-- | Clase y estilo del slot según lo que se pinta: la que se lleva sigue al puntero
-- ('heldStyle') y se marca si ahí no se deja; las demás, en su rectángulo.
slotAttrs :: WidgetConfig -> Scene -> Map Text Text
slotAttrs wc s = case sceneHeld s of
  Just h | heldId h == widgetId wc -> Map.fromList [("class", heldClass h), ("style", heldStyle h)]
  _ -> Map.fromList [("class", slotClass r), ("style", slotStyle r)]
  where
    r = fromMaybe wc (find ((== widgetId wc) . widgetId) (sceneCards s))
    heldClass h
      | heldFits h = "widget-slot widget-slot--held"
      | otherwise  = "widget-slot widget-slot--held widget-slot--blocked"

-- | Clase del slot: el bloque, y el modificador solo cuando hay algo que
-- modificar — mismo criterio que el @rowClass@ de 'Widgets.LiveTiming'
-- (2026-08-27). De los siete slots de los layouts fijos lo llevan tres.
--
-- __El modificador no pinta nada hoy:__ la hoja dejó de dibujar la muesca cuando
-- la banda de sesión bajó las tarjetas fuera del alcance del botón. Se emite igual,
-- porque la esquina vuelve a estar en disputa en cuanto la banda pueda anclarse
-- abajo.
slotClass :: WidgetConfig -> Text
slotClass wc
  | touchesTopRight wc = "widget-slot widget-slot--top-right"
  | otherwise          = "widget-slot"
