{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Página Dashboard (un módulo por flujo, convención @Pages.\<Flujo\>@).
--
-- La pantalla no monta widgets hardcodeados: se **deriva de un 'Layout'**
-- ('Common.Types'). 'renderWidget' despacha por
-- 'widgetType' a los widgets existentes ('liveTimingWidget' \/ 'telemetryWidget') y
-- da un placeholder para los tipos aún no implementados. Dos botones conmutan entre
-- dos 'Layout' fijos ('raceOverview' \/ 'qualy') sosteniendo un @Dynamic t Layout@;
-- 'dyn_' re-monta la lista de widgets en cada cambio. Primer uso real de
-- 'Layout'\/'WidgetConfig'\/'WidgetType'\/'WidgetParams'\/'WidgetId' en el frontend.
--
-- Observación: al conmutar, 'dyn_' re-monta los widgets, así que 'liveTimingWidget'
-- re-dispara su fetch (@getPostBuild@ corre al montar). Aceptable en esta fase.
module Pages.Dashboard where

import           Common.Types       (Layout (..), LayoutId (..),
                                     WidgetConfig (..), WidgetId (..),
                                     WidgetParams (..), WidgetType (..))
import qualified Data.Text          as T
import           Reflex.Dom
import           Widgets.Comparison (comparisonWidget)
import           Widgets.Historical (constructorStatsWidget, driverStatsWidget)
import           Widgets.LiveTiming (liveTimingWidget)
import           Widgets.Telemetry  (telemetryWidget)

-- | Pantalla del dashboard: barra de conmutación de layouts + la lista de widgets
-- del layout activo (re-montada con 'dyn_' en cada cambio).
dashboardPage :: MonadWidget t m => m ()
dashboardPage = divClass "page page--dashboard" $ do
  el "h1" $ text "F1 Functional Dashboard"
  layoutDyn <- layoutSwitcher
  dyn_ $ ffor layoutDyn $ \l -> mapM_ renderWidget (widgets l)

-- | Barra de botones que conmutan entre los layouts fijos. Sostiene el layout
-- activo en un @Dynamic t Layout@ (arranca en 'raceOverview').
layoutSwitcher :: MonadWidget t m => m (Dynamic t Layout)
layoutSwitcher = divClass "layout-switcher" $ do
  overviewClick <- switcherButton "Race Overview"
  qualyClick    <- switcherButton "Qualy"
  holdDyn raceOverview $ leftmost
    [ raceOverview <$ overviewClick
    , qualy        <$ qualyClick
    ]

-- | Botón que emite un 'Event' al hacer click. Clase @switcher__btn@, la misma
-- que los tres switchers de los widgets; el bloque
-- @layout-switcher@ sí es propio.
switcherButton :: DomBuilder t m => T.Text -> m (Event t ())
switcherButton label = do
  (e, _) <- elClass' "button" "switcher__btn" $ text label
  pure (domEvent Click e)

-- | Despacha una 'WidgetConfig' a su widget según 'widgetType'. Total sobre los
-- __siete__ constructores de 'WidgetType'; los aún no implementados caen en un
-- placeholder (no @error@ parcial). 'params' no se consume todavía.
--
-- 'HistoricalStats' y 'ConstructorStats' son dos ramas desde 2026-08-26, una por
-- clasificación: antes 'HistoricalStats' montaba un widget que pintaba las dos
-- tablas. La totalidad de este @case@ es la que cobra el constructor nuevo, y
-- __solo bajo GHCJS__ (@-Wall@ del paquete @frontend@).
renderWidget :: MonadWidget t m => WidgetConfig -> m ()
renderWidget wc = case widgetType wc of
  LiveTiming       -> liveTimingWidget
  Telemetry        -> telemetryWidget
  LapComparison    -> comparisonWidget
  TyreStrategy     -> placeholderWidget "Tyre Strategy"
  HistoricalStats  -> driverStatsWidget
  ConstructorStats -> constructorStatsWidget
  Custom           -> placeholderWidget "Custom"

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

-- | Layout "Race Overview": live timing, telemetría, comparación de vueltas y las
-- __dos__ clasificaciones históricas, que desde 2026-08-26 son dos widgets y ocupan
-- dos sitios de la rejilla en vez de compartir tarjeta.
raceOverview :: Layout
raceOverview = Layout
  { layoutId = LayoutId "race-overview"
  , widgets  =
      [ cfg LiveTiming
      , cfg Telemetry
      , cfg LapComparison
      , cfg HistoricalStats
      , cfg ConstructorStats
      ]
  }

-- | Layout "Qualy": solo live timing (conjunto distinto → valida la conmutación).
qualy :: Layout
qualy = Layout
  { layoutId = LayoutId "qualy"
  , widgets  = [cfg LiveTiming]
  }
