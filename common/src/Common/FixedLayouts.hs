-- | Los tres layouts fijos de la página (Race Overview, Qualy y Strategy), con sus
-- rectángulos en 1/120 del lienzo. Viven en @common@ para que @backend-test@ pruebe
-- estos y no una copia.
module Common.FixedLayouts
  ( cfg
  , raceOverview
  , qualy
  , strategy
  ) where

import           Common.Types (Layout (..), LayoutId (..), WidgetConfig (..),
                               WidgetId (..), WidgetType (..), noParams)

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
  , widgetGroups  = []
  , wcX           = x
  , wcY           = y
  , wcW           = w
  , wcH           = h
  }

-- | Layout "Race Overview": live timing, comparación de vueltas y las dos
-- clasificaciones históricas, cada una en su sitio.
--
-- La colocación, en unidades de 120 (2026-09-03 y 2026-09-04):
--
-- > 0            60           120
-- > ┌────────────┬────────────┐  0
-- > │            │            │
-- > │            │            │
-- > │ live-timing│ lap-compar │
-- > │            │            │
-- > │            │            │
-- > │            ├╌╌╌╌╌╌╌╌╌╌╌╌┤ 85
-- > ├────────────┼────────────┤ 90
-- > │ driver-st  │ constr-st  │
-- > └────────────┴────────────┘ 120
--
-- Las cinco unidades bajo @lap-comparison@ quedan __vacías a propósito__:
-- comprueban que el lienzo no rellena los huecos solo. Todos los números son
-- múltiplos de 5, o sea celda del imán de 24×24.
--
-- Un typo en los ids no lo caza el compilador, y por eso los cinco rectángulos de
-- este módulo los ejercita @backend-test@ contra "Common.Layout".
raceOverview :: Layout
raceOverview = Layout
  { layoutId = LayoutId "race-overview"
  , layoutGroups = []
  , widgets  =
      [ cfg (WidgetId "live-timing")       LiveTiming       (  0,  0, 60, 90)
      , cfg (WidgetId "lap-comparison")    LapComparison    ( 60,  0, 60, 85)
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
  , layoutGroups = []
  , widgets  = [cfg (WidgetId "qualy-live-timing") LiveTiming (0, 0, 120, 120)]
  }

-- | Layout "Strategy": live timing y Tyre Strategy, mitad y mitad y a todo el alto, para
-- que las filas de las dos tarjetas queden a la par.
strategy :: Layout
strategy = Layout
  { layoutId = LayoutId "strategy"
  , layoutGroups = []
  , widgets  =
      [ cfg (WidgetId "strategy-live-timing") LiveTiming   ( 0, 0, 60, 120)
      , cfg (WidgetId "tyre-strategy")        TyreStrategy (60, 0, 60, 120)
      ]
  }
