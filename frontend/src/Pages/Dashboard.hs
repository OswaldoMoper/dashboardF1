{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Página Dashboard (un módulo por flujo, convención @Pages.\<Flujo\>@).
--
-- La pantalla no monta widgets hardcodeados: se **deriva de un 'Layout'**
-- ('Common.Types'). 'renderWidget' despacha por
-- 'widgetType' a los widgets existentes ('liveTimingWidget' \/ 'telemetryWidget') y
-- da un placeholder para los tipos aún no implementados. Primer uso real de
-- 'Layout'\/'WidgetConfig'\/'WidgetType'\/'WidgetParams'\/'WidgetId' en el frontend.
-- La conmutación entre layouts (botones Race Overview \/ Qualy) llega después.
module Pages.Dashboard where

import           Common.Types       (Layout (..), LayoutId (..),
                                     WidgetConfig (..), WidgetId (..),
                                     WidgetParams (..), WidgetType (..))
import qualified Data.Text          as T
import           Reflex.Dom
import           Widgets.LiveTiming (liveTimingWidget)
import           Widgets.Telemetry  (telemetryWidget)

-- | Pantalla del dashboard: monta la lista de widgets del layout actual.
-- Todavía fijo ('raceOverview'); la conmutación llega en el Commit B.
dashboardPage :: MonadWidget t m => m ()
dashboardPage = divClass "page page--dashboard" $ do
  el "h1" $ text "F1 Functional Dashboard"
  mapM_ renderWidget (widgets raceOverview)

-- | Despacha una 'WidgetConfig' a su widget según 'widgetType'. Total sobre los
-- seis constructores de 'WidgetType'; los aún no implementados caen en un
-- placeholder (no @error@ parcial). 'params' no se consume todavía.
renderWidget :: MonadWidget t m => WidgetConfig -> m ()
renderWidget wc = case widgetType wc of
  LiveTiming      -> liveTimingWidget
  Telemetry       -> telemetryWidget
  LapComparison   -> placeholderWidget "Lap Comparison"
  TyreStrategy    -> placeholderWidget "Tyre Strategy"
  HistoricalStats -> placeholderWidget "Historical Stats"
  Custom          -> placeholderWidget "Custom"

-- | Widget aún no disponible: recuadro con etiqueta del tipo.
placeholderWidget :: DomBuilder t m => T.Text -> m ()
placeholderWidget name = divClass "widget widget--placeholder" $ do
  el "h2" $ text name
  elClass "p" "status status--placeholder" $ text "Widget no disponible"

-- | 'WidgetConfig' mínima para un 'WidgetType': 'WidgetId' derivado del tipo y
-- 'params' vacíos (mapa vacío; los widgets no toman parámetros aún).
cfg :: WidgetType -> WidgetConfig
cfg wt = WidgetConfig
  { widgetId   = WidgetId (T.pack (show wt))
  , widgetType = wt
  , params     = WidgetParams mempty
  }

-- | Layout "Race Overview": live timing + telemetría.
raceOverview :: Layout
raceOverview = Layout
  { layoutId = LayoutId "race-overview"
  , widgets  = [cfg LiveTiming, cfg Telemetry]
  }

-- | Layout "Qualy": solo live timing (conjunto distinto → valida la conmutación).
qualy :: Layout
qualy = Layout
  { layoutId = LayoutId "qualy"
  , widgets  = [cfg LiveTiming]
  }
