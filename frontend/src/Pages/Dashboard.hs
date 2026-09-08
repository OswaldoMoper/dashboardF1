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
-- __Desde el 2026-09-07 el layout coloca de verdad.__ Hasta entonces los widgets
-- se montaban como hermanos sobre una rejilla @auto-fit@ y el rectángulo de cada
-- 'WidgetConfig' —que existe desde el 2026-09-03 y está probado en
-- "Common.Layout"— no lo miraba nadie. Ahora 'slot' envuelve cada widget en su
-- rectángulo y la rejilla desaparece. Lo que el @.css@ ya no puede saber lo emite
-- 'Common.Layout.slotStyle', porque depende del dato y no de la clase.
--
-- __Los 'WidgetId' se escriben aquí__, uno por widget y a mano: desde el
-- 2026-09-01 la identidad no se deriva del tipo, así que los layouts de este
-- módulo son quienes la ponen. Un typo no lo caza el compilador; se nota al usar
-- lo que referencia por id, no al compilar.
--
-- Observación: al conmutar, 'dyn_' re-monta los widgets, así que 'liveTimingWidget'
-- re-dispara su fetch (@getPostBuild@ corre al montar). Aceptable en esta fase.
module Pages.Dashboard where

import           Common.Layout      (slotStyle)
import           Common.Types       (Layout (..), LayoutId (..),
                                     WidgetConfig (..), WidgetId (..),
                                     WidgetType (..), noParams)
import qualified Data.Text          as T
import           Reflex.Dom
import           Widgets.Comparison (comparisonWidget)
import           Widgets.Historical (constructorStatsWidget, driverStatsWidget)
import           Widgets.LiveTiming (liveTimingWidget)
import           Widgets.Telemetry  (telemetryWidget)

-- | Pantalla del dashboard: la cabecera —título y conmutación de layouts— y el
-- __lienzo__ con los widgets del layout activo, cada uno en su rectángulo.
--
-- __La cabecera y el lienzo son hermanos, y no un encabezado dentro del lienzo__:
-- los widgets se colocan desde la esquina de arriba de su contenedor, así que un
-- título en flujo dentro de él lo taparía el widget de @y = 0@. La cabecera flota
-- por encima (@position: sticky@ en la hoja de estilos) y el lienzo se lleva la
-- ventana entera.
--
-- Y precisamente porque flota encima, __se pliega__: 'headerToggle' la abre y la
-- cierra, y arranca abierta. Los tres se montan en este orden por dependencia y
-- no por posición en pantalla — el botón emite el 'Event', 'toggle' lo convierte
-- en estado y la cabecera lo consume.
dashboardPage :: MonadWidget t m => m ()
dashboardPage = divClass "page page--dashboard" $ do
  toggleClick <- headerToggle
  openDyn     <- toggle True toggleClick
  layoutDyn   <- dashboardHeader openDyn
  divClass "canvas" $
    dyn_ $ ffor layoutDyn $ \l -> mapM_ slot (widgets l)

-- | Botón que pliega y despliega la cabecera. __Es hermano de ella y no hijo__,
-- que es lo único que le permite seguir visible cuando ella no lo está: metido
-- dentro, plegar la cabecera se lo llevaría por delante y no habría forma de
-- traerla de vuelta.
--
-- Por eso también es lo primero que se monta, antes que la propia cabecera: el
-- 'Event' que emite es lo que alimenta el @Dynamic t Bool@ que ella consume, así
-- que el orden evita el ciclo y con él el 'RecursiveDo' que 'Widgets.Comparison'
-- sí necesita.
--
-- Clase propia y no @switcher__btn@ —no conmuta entre alternativas, abre y
-- cierra—, pero el __aspecto__ lo comparte con los switchers en la hoja de
-- estilos, que es lo que 2026-08-21 (c) unificó.
headerToggle :: DomBuilder t m => m (Event t ())
headerToggle = do
  (e, _) <- elClass' "button" "header-toggle" $ text "☰"
  pure (domEvent Click e)

-- | La cabecera: título y conmutación de layouts, que se pliegan __juntos__
-- (2026-09-07). Devuelve el layout activo, porque el switcher vive dentro.
--
-- __Se pliega con una clase y no desmontando__, y la diferencia importa: con
-- 'dyn' el contenido se re-monta en cada cambio, así que 'layoutSwitcher'
-- perdería su @Dynamic t Layout@ y __volvería a 'raceOverview'__ cada vez que se
-- desplegara. Es el mismo mecanismo que ya hace que 'liveTimingWidget' re-dispare
-- su fetch al conmutar de layout; aquí no sería una observación aceptable sino un
-- estado perdido. Con 'elDynClass' el DOM se queda montado y solo cambia si se
-- pinta.
dashboardHeader :: MonadWidget t m => Dynamic t Bool -> m (Dynamic t Layout)
dashboardHeader openDyn =
  elDynClass "div" (headerClass <$> openDyn) $ do
    el "h1" $ text "F1 Functional Dashboard"
    layoutSwitcher
  where
    headerClass open
      | open      = "dashboard-header"
      | otherwise = "dashboard-header dashboard-header--hidden"

-- | Envuelve un widget en su __slot__: el rectángulo que le da sitio en el
-- lienzo, con el estilo que calcula 'slotStyle'.
--
-- __El rectángulo lo pone quien envuelve y no el widget__, y no es una elección
-- de estilo: 'renderWidget' despacha por 'widgetType' y cada widget emite su
-- propia @divClass "widget …"@ sin saber dónde va. Meterle la posición obligaría
-- a pasarle la 'WidgetConfig' a los siete y a que los siete la usaran igual.
--
-- Del estilo, aquí solo viaja lo que __depende del dato__; @position: absolute@ y
-- la separación entre widgets viven en la regla de @.widget-slot@.
slot :: MonadWidget t m => WidgetConfig -> m ()
slot wc =
  elAttr "div" ("class" =: "widget-slot" <> "style" =: slotStyle wc) $
    renderWidget wc

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

-- | 'WidgetConfig' con su sitio en el lienzo: el 'WidgetId' y el rectángulo
-- __los pone quien llama__, y el resto va en su valor neutro — 'noParams' (cada
-- endpoint con su default), visible y sin grupo—.
--
-- El id es argumento y no derivado del tipo desde el 2026-09-01: derivarlo de
-- @show wt@ hacía que la identidad __fuera__ el tipo, y entonces dos widgets del
-- mismo tipo compartían id. Decidido el 2026-09-01.
--
-- __El rectángulo también es argumento, y no puede no serlo__: con el lienzo
-- libre (2026-09-03) la colocación es dato del widget, así
-- que un valor neutro sería apilar los siete en @0,0@. La tupla es
-- @(x, y, ancho, alto)@ en __1\/120 del contenedor__ (2026-09-04), no en
-- píxeles ni en centésimas.
cfg :: WidgetId -> WidgetType -> (Int, Int, Int, Int) -> WidgetConfig
cfg wid wt (x, y, w, h) = WidgetConfig
  { widgetId      = wid
  , widgetType    = wt
  , params        = noParams
  , widgetVisible = True
  , widgetGroup   = Nothing
  , wcX           = x
  , wcY           = y
  , wcW           = w
  , wcH           = h
  }

-- | Layout "Race Overview": live timing, __dos__ telemetrías, comparación de vueltas
-- y las __dos__ clasificaciones históricas, que desde 2026-08-26 son dos widgets y
-- ocupan dos sitios propios en vez de compartir tarjeta.
--
-- __Los dos 'Telemetry' son el entregable de varias instancias__, y solo son
-- posibles desde que el id es explícito: derivado de @show wt@ los dos tenían el
-- mismo. Cada uno hace su propio fetch de @\/api\/telemetry@ y sostiene su propio
-- selector de piloto, así que pueden mostrar pilotos distintos a la vez — que es
-- para lo que sirven: comparar dos peleas.
--
-- Es el par que 'widgetGroup' va a agrupar, y __no por estar juntos__: desde el
-- 2026-09-03 (b) la membresía del grupo la declara el autor y no la adyacencia
-- (que además ya no significa nada, porque el orden de la lista dejó de colocar).
--
-- __La colocación es la del requisito__ que descartó la lista y el árbol —«uno a
-- medio layout, dos apilados junto a uno alto»—, en unidades de 120
-- (2026-09-03 y 2026-09-04):
--
-- > 0            60           120
-- > ┌────────────┬────────────┐  0
-- > │            │  telemetry │
-- > │            ├────────────┤ 35
-- > │ live-timing│ telemetry-2│
-- > │            ├────────────┤ 70
-- > │            │ lap-compar │
-- > │            ├╌╌╌╌╌╌╌╌╌╌╌╌┤ 85
-- > ├────────────┼────────────┤ 90
-- > │ driver-st  │ constr-st  │
-- > └────────────┴────────────┘ 120
--
-- Las cinco unidades bajo @lap-comparison@ quedan __vacías a propósito__. Los
-- huecos son legales desde el 2026-09-03, y este existe para comprobar al
-- encender el render que el lienzo __no lo rellena solo__: es la propiedad que lo
-- distingue de la rejilla @auto-fit@ que sustituye.
--
-- Todos los números son múltiplos de 5, o sea celda del imán de 24×24.
--
-- Un typo aquí __no lo caza el compilador__ —mismo riesgo que los 'WidgetId'
-- literales del 2026-09-01—, y por eso los siete rectángulos de este módulo los
-- ejercita @backend-test@ contra "Common.Layout".
--
-- Observación, no defecto a arreglar aquí: __el segundo fetch se paga__. Son dos
-- peticiones de la misma lista multi-piloto, igual que las dos clasificaciones
-- desde el 2026-08-26; el filtrado por piloto ya era en cliente.
raceOverview :: Layout
raceOverview = Layout
  { layoutId = LayoutId "race-overview"
  , widgets  =
      [ cfg (WidgetId "live-timing")       LiveTiming       (  0,  0, 60, 90)
      , cfg (WidgetId "telemetry")         Telemetry        ( 60,  0, 60, 35)
      , cfg (WidgetId "telemetry-2")       Telemetry        ( 60, 35, 60, 35)
      , cfg (WidgetId "lap-comparison")    LapComparison    ( 60, 70, 60, 15)
      , cfg (WidgetId "driver-stats")      HistoricalStats  (  0, 90, 60, 30)
      , cfg (WidgetId "constructor-stats") ConstructorStats ( 60, 90, 60, 30)
      ]
  }

-- | Layout "Qualy": solo live timing (conjunto distinto → valida la conmutación).
--
-- Su live timing lleva id __propio__ y no el de 'raceOverview': la unicidad solo
-- se pide dentro de un 'Layout', pero un id por layout es lo que permite que los
-- dos guarden estado distinto del mismo tipo de widget.
--
-- Ocupa el lienzo entero, que es el caso límite del rectángulo: @0,0@ y 120×120.
qualy :: Layout
qualy = Layout
  { layoutId = LayoutId "qualy"
  , widgets  = [cfg (WidgetId "qualy-live-timing") LiveTiming (0, 0, 120, 120)]
  }
