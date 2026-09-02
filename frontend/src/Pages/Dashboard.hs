{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Página Dashboard (un módulo por flujo, convención @Pages.\<Flujo\>@).
--
-- La pantalla no monta widgets hardcodeados: se **deriva de un 'Layout'**
-- ('Common.Types'). 'renderWidget' despacha por
-- 'widgetType' a los widgets existentes ('liveTimingWidget' \/ 'telemetryWidget') y
-- da un placeholder para los tipos aún no implementados. Dos botones conmutan entre
-- dos 'Layout' fijos ('raceOverview' \/ 'qualy') sosteniendo un @Dynamic t Layout@;
-- 'dyn_' re-monta la lista de widgets en cada cambio. Único consumidor de
-- 'Layout'\/'WidgetConfig'\/'WidgetType'\/'WidgetParams'\/'WidgetId'.
--
-- __Los 'WidgetId' se escriben aquí__, uno por widget y a mano: desde el
-- 2026-09-01 la identidad no se deriva del tipo, así que los layouts de este
-- módulo son quienes la ponen. Un typo no lo caza el compilador; se nota al usar
-- lo que referencia por id, no al compilar.
--
-- Observación: al conmutar, 'dyn_' re-monta los widgets, así que 'liveTimingWidget'
-- re-dispara su fetch (@getPostBuild@ corre al montar). Aceptable en esta fase.
module Pages.Dashboard where

import           Common.Types       (Layout (..), LayoutId (..),
                                     WidgetConfig (..), WidgetId (..),
                                     WidgetType (..), noParams)
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

-- | 'WidgetConfig' mínima: el 'WidgetId' __lo pone quien llama__ y el resto va
-- en su valor neutro — 'noParams' (cada endpoint con su default), visible y sin
-- grupo—, de modo que el render es el mismo que antes de que los tres campos
-- existieran.
--
-- El id es argumento y no derivado del tipo desde el 2026-09-01: derivarlo de
-- @show wt@ hacía que la identidad __fuera__ el tipo, y entonces dos widgets del
-- mismo tipo compartían id. Ver (2026-09-01).
cfg :: WidgetId -> WidgetType -> WidgetConfig
cfg wid wt = WidgetConfig
  { widgetId      = wid
  , widgetType    = wt
  , params        = noParams
  , widgetVisible = True
  , widgetGroup   = Nothing
  }

-- | Layout "Race Overview": live timing, __dos__ telemetrías, comparación de vueltas
-- y las __dos__ clasificaciones históricas, que desde 2026-08-26 son dos widgets y
-- ocupan dos sitios de la rejilla en vez de compartir tarjeta.
--
-- __Los dos 'Telemetry' son el entregable de varias instancias__, y solo son
-- posibles desde que el id es explícito: derivado de @show wt@ los dos tenían el
-- mismo. Cada uno hace su propio fetch de @\/api\/telemetry@ y sostiene su propio
-- selector de piloto, así que pueden mostrar pilotos distintos a la vez — que es
-- para lo que sirven: comparar dos peleas.
--
-- Van __adyacentes__ a propósito: el grupo es adyacencia más etiqueta
-- (2026-09-01 c), así que este es el par que 'widgetGroup'
-- va a agrupar.
--
-- Observación, no defecto a arreglar aquí: __el segundo fetch se paga__. Son dos
-- peticiones de la misma lista multi-piloto, igual que las dos clasificaciones
-- desde el 2026-08-26; el filtrado por piloto ya era en cliente.
raceOverview :: Layout
raceOverview = Layout
  { layoutId = LayoutId "race-overview"
  , widgets  =
      [ cfg (WidgetId "live-timing")       LiveTiming
      , cfg (WidgetId "telemetry")         Telemetry
      , cfg (WidgetId "telemetry-2")       Telemetry
      , cfg (WidgetId "lap-comparison")    LapComparison
      , cfg (WidgetId "driver-stats")      HistoricalStats
      , cfg (WidgetId "constructor-stats") ConstructorStats
      ]
  }

-- | Layout "Qualy": solo live timing (conjunto distinto → valida la conmutación).
--
-- Su live timing lleva id __propio__ y no el de 'raceOverview': la unicidad solo
-- se pide dentro de un 'Layout', pero un id por layout es lo que permite que los
-- dos guarden estado distinto del mismo tipo de widget.
qualy :: Layout
qualy = Layout
  { layoutId = LayoutId "qualy"
  , widgets  = [cfg (WidgetId "qualy-live-timing") LiveTiming]
  }
