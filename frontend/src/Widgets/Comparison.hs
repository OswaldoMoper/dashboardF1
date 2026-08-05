{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Comparación de Vueltas (categoría LapComparison).
--
-- Consume @GET \/api\/comparison@ en runtime vía 'Client.fetchJson' +
-- 'Common.Route.comparisonPath' (relativo, misma-origen), con los tres estados
-- del fetch ('Loading' \/ 'Failed' \/ 'Loaded') y sin datos dummy locales, igual
-- que 'Widgets.LiveTiming', 'Widgets.Telemetry' e 'Widgets.Historical'.
--
-- __Es el primer widget del repo que pinta una serie y no una tabla.__ De los
-- cinco campos de 'Common.Types.LapComparison', cuatro son etiquetas triviales
-- —@lcLapA@\/@lcLapB@ vienen __ya formateadas__ desde el microservicio
-- (2026-07-31), así que aquí no se parsea ni se calcula
-- nada con ellas— y todo el interés está en @lcDelta@.
--
-- __El gráfico es SVG a mano, sin librería.__ El escalado vive en 'Common.Chart',
-- puro y probado por @backend-test@; este módulo solo monta el DOM. La
-- alternativa que @ARCHITECTURE.md §2.2@ contempla —Plotly\/Chart.js por FFI—
-- sigue en pie para el día que hagan falta tooltips o zoom, con el coste que
-- registró la decisión del 2026-08-04: servir el @.js@, escribir el
-- @foreign import javascript@ y sobre todo manejar que 'dyn_' __re-monte__ el
-- nodo bajo un gráfico imperativo, que es justo lo que pasa aquí al conmutar de
-- layout.
--
-- __Un solo 'dyn_'__, a diferencia de 'Widgets.Telemetry': allí las opciones del
-- selector salen de la respuesta y obligan a anidar; aquí no hay selector.
-- Elegir los dos coches es sesión propia y necesita resolver el desajuste de
-- vocabularios (la API habla números de coche, los widgets acrónimos,
-- 2026-08-01), así que hoy se piden los de por defecto y
-- 'Common.Route.comparisonPathFor' __sigue sin consumidor__.
module Widgets.Comparison where

import           Client       (fetchJson)
import           Common.Chart (chartHeight, chartPad, chartWidth, deltaPolyline,
                               zeroLineY)
import           Common.Route (comparisonPath)
import           Common.Types (LapComparison (..))
import           Data.Map     (Map)
import qualified Data.Map     as Map
import           Data.Text    (Text)
import qualified Data.Text    as T
import           Reflex.Dom

-- | Estado del fetch de @\/api\/comparison@. 'Failed' (no 'Error') para no
-- chocar con nombres de @base@\/@Prelude@, mismo criterio que los otros widgets.
data CState
  = Loading
  | Failed
  | Loaded LapComparison

-- | Comparación de la vuelta rápida de dos coches: cabecera con los dos pilotos
-- y sus tiempos, y el delta acumulado como una línea.
comparisonWidget :: MonadWidget t m => m ()
comparisonWidget = divClass "widget widget--comparison" $ do
  el "h2" $ text "Lap Comparison"
  pb    <- getPostBuild
  resp  <- fetchJson (comparisonPath <$ pb)
  state <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ (renderState <$> state)
  where
    renderState :: MonadWidget t m => CState -> m ()
    renderState Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/comparison"
    renderState (Loaded c) = do
      lapHeader c
      deltaChart (lcDelta c)

-- | Los dos pilotos con su tiempo de vuelta, tal cual llegan. @lcLapA@\/@lcLapB@
-- son 'Text' ya formateado (@M:SS.mmm@) por el microservicio: intentar
-- reformatearlos aquí sería reintroducir en el widget un trabajo que el servicio
-- ya hizo.
lapHeader :: DomBuilder t m => LapComparison -> m ()
lapHeader c = divClass "comparison__header" $ do
  lapLabel (lcDriverA c) (lcLapA c)
  elClass "span" "comparison__vs" $ text "vs"
  lapLabel (lcDriverB c) (lcLapB c)

-- | Un piloto y su tiempo.
lapLabel :: DomBuilder t m => Text -> Text -> m ()
lapLabel driver lap = divClass "comparison__lap" $ do
  elClass "span" "comparison__driver" $ text driver
  elClass "span" "comparison__time" $ text lap

-- | El delta acumulado como @\<polyline\>@ sobre un @viewBox@ fijo, con la línea
-- del cero dibujada aparte.
--
-- La línea del cero se pinta __siempre__, incluso sin serie: es la referencia que
-- da sentido al eje ("iban empatados"), no una decoración de los datos. Con
-- @lcDelta@ vacío no se emite @\<polyline\>@ y se dice por qué; no debería
-- ocurrir —el @Context@ del backend degrada a dummy cuando lo está
-- (2026-08-03)— pero el widget no puede darlo por hecho.
deltaChart :: MonadWidget t m => [Double] -> m ()
deltaChart series = do
  svgEl "svg" chartAttrs $ do
    svgEl "line" (zeroLineAttrs series) blank
    case series of
      [] -> blank
      _  -> svgEl "polyline" (polylineAttrs series) blank
  case series of
    [] -> elClass "p" "status status--empty" $ text "Sin delta que dibujar"
    _  -> blank

-- | Elemento en el namespace de SVG.
--
-- Es el único punto delicado del módulo: 'el'\/'elAttr' crean el elemento en el
-- namespace de __HTML__, y un @\<svg\>@ HTML es un nodo desconocido que el
-- navegador no pinta. No hay error, no hay excepción: no se ve nada. De ahí que
-- todo el gráfico pase por aquí.
--
-- Dos detalles de la API, y los dos son de @reflex-dom@ y no elecciones: los
-- atributos son estáticos pero el combinador con namespace es el __dinámico__
-- (no existe un @elAttrNS@), y se usa la variante con tick descartando el
-- 'Element' que devuelve, que es el primitivo sobre el que están escritas las
-- demás.
svgEl :: MonadWidget t m => Text -> Map Text Text -> m a -> m a
svgEl name attrs child =
  snd <$> elDynAttrNS' svgNamespace name (constDyn attrs) child

-- | Namespace de SVG, el que espera 'svgEl'.
svgNamespace :: Maybe Text
svgNamespace = Just "http://www.w3.org/2000/svg"

-- | Lienzo: @viewBox@ fijo de 'Common.Chart' y ancho fluido.
--
-- @preserveAspectRatio=\"none\"@ porque el eje X es la vuelta y el Y son
-- segundos: no son magnitudes comparables, así que conservar la proporción no
-- significa nada y estirar a lo ancho aprovecha la pantalla.
chartAttrs :: Map Text Text
chartAttrs =
  Map.fromList
    [ ("class", "comparison__chart")
    , ("viewBox", "0 0 " <> num chartWidth <> " " <> num chartHeight)
    , ("width", "100%")
    , ("height", num chartHeight)
    , ("preserveAspectRatio", "none")
    ]

-- | Línea de referencia del cero, discontinua para que no se confunda con la
-- serie. Su Y sale del mismo 'Common.Chart.deltaRange' que los puntos.
zeroLineAttrs :: [Double] -> Map Text Text
zeroLineAttrs series =
  Map.fromList
    [ ("class", "comparison__zero")
    , ("x1", num chartPad)
    , ("y1", y)
    , ("x2", num (chartWidth - chartPad))
    , ("y2", y)
    , ("stroke", "#888888")
    , ("stroke-width", "1")
    , ("stroke-dasharray", "4 4")
    ]
  where
    y = num (zeroLineY series)

-- | La serie. @fill=\"none\"@ es obligatorio: por defecto un @\<polyline\>@ se
-- rellena en negro y el gráfico sale como una mancha.
polylineAttrs :: [Double] -> Map Text Text
polylineAttrs series =
  Map.fromList
    [ ("class", "comparison__delta")
    , ("points", deltaPolyline series)
    , ("fill", "none")
    , ("stroke", "#e10600")
    , ("stroke-width", "2")
    , ("stroke-linejoin", "round")
    ]

-- | Un número del lienzo como texto de atributo. Entero por el mismo motivo que
-- las coordenadas de 'Common.Chart.deltaPolyline': 'show' sobre 'Double' emite
-- notación científica para los valores pequeños.
--
-- __No hay hoja de estilos en el repo__, así que @stroke@, @fill@ y compañía van
-- como atributos de presentación. Las clases se mantienen como gancho para
-- cuando exista, igual que hace 'Widgets.Historical.rowClass'.
num :: Double -> Text
num = T.pack . show . (round :: Double -> Int)
