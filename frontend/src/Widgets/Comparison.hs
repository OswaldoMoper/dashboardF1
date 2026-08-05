{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Comparación de Vueltas (categoría LapComparison).
--
-- Consume @GET \/api\/comparison@ en runtime vía 'Client.fetchJson' +
-- 'Common.Route.comparisonPath' al arrancar y 'Common.Route.comparisonPathFor'
-- al elegir coches (relativos, misma-origen), con los tres estados del fetch
-- ('Loading' \/ 'Failed' \/ 'Loaded') y sin datos dummy locales, igual que
-- 'Widgets.LiveTiming', 'Widgets.Telemetry' e 'Widgets.Historical'.
--
-- __Es el primer widget del repo que pinta una serie y no una tabla.__ De los
-- siete campos de 'Common.Types.LapComparison', seis son etiquetas
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
-- __Es el primer widget del repo cuyo fetch no sale solo de 'getPostBuild'.__
-- Los tres switchers anteriores ('Widgets.Historical' ×2, 'Widgets.Telemetry')
-- filtran __en cliente__ sobre datos ya recibidos
-- (2026-08-01); aquí no se puede, porque la comparación de otros dos coches
-- sencillamente no está en la respuesta actual. De ahí las dos cosas nuevas:
-- un 'Event' de URL que nace de un clic y un estado de recarga que __no borra__
-- lo que ya se veía.
--
-- __Se teclean números de coche, no acrónimos.__ Es el desajuste de vocabularios
-- del repo (la API habla números, los widgets acrónimos,
-- 2026-08-01) resuelto por el lado barato: 'Common.Types.LapComparison' trae
-- desde el 2026-08-05 los números junto a los acrónimos, así que el widget puede
-- mostrar de qué coches habla lo que está pintando. Lo que todavía no tiene es
-- la __lista__ de la parrilla: eso necesita un endpoint propio del microservicio
-- y es la sesión siguiente. Hasta entonces, dos entradas libres.
module Widgets.Comparison where

import           Client       (fetchJson)
import           Common.Chart (chartHeight, chartPad, chartWidth, deltaPolyline,
                               zeroLineY)
import           Common.Route (comparisonPath, comparisonPathFor, driversParam)
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

-- | Comparación de la vuelta rápida de dos coches: selector, cabecera con los
-- dos pilotos y sus tiempos, y el delta acumulado como una línea.
--
-- __El selector se monta fuera de los 'dyn_', y no es una preferencia de
-- estilo:__ 'dyn_' __re-monta__ su contenido en cada cambio del 'Dynamic', así
-- que un @\<input\>@ dentro perdería el foco y lo tecleado en cada respuesta.
comparisonWidget :: MonadWidget t m => m ()
comparisonWidget = divClass "widget widget--comparison" $ do
  el "h2" $ text "Lap Comparison"
  picked  <- carSelector
  pb      <- getPostBuild
  resp    <- fetchJson (leftmost [comparisonPath <$ pb, picked])
  refresh <- holdDyn InFlight (leftmost [InFlight <$ picked, refreshOf <$> resp])
  state   <- foldDyn step Loading resp
  dyn_ (banner <$> zipDyn refresh state)
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

-- | Cómo avanza el estado con cada respuesta. __Es la pieza que impide el
-- parpadeo__, y por eso el widget usa 'foldDyn' y no el 'holdDyn' de los otros
-- cuatro: el estado depende del anterior.
--
-- Con @holdDyn (maybe Failed Loaded)@ cada clic habría llevado el widget a
-- 'Failed' o directamente a repintar desde cero, borrando el gráfico que se
-- estaba mirando justo cuando se pide el siguiente. Aquí el estado __solo
-- avanza__: una recarga fallida conserva lo mostrado, y 'Failed' queda para el
-- único caso en que no hay nada que conservar — que no llegara nunca nada.
--
-- 'CState' no gana un cuarto constructor de \"recargando\": el estado de la
-- __petición__ vive aparte, en 'Refresh', justamente para que no se mezcle con
-- el de los __datos__. Meterlos en el mismo tipo obligaría a que cada
-- combinación fuera un constructor.
step :: Maybe LapComparison -> CState -> CState
step (Just c) _          = Loaded c
step Nothing  (Loaded c) = Loaded c
step Nothing  _          = Failed

-- | Qué le pasó a la última petición, al margen de los datos que se muestran.
--
-- Existe por una consecuencia directa de 'step': al conservar lo anterior ante
-- una recarga fallida, el fallo __no se vería en ninguna parte__. 'LastFailed'
-- es lo que impide que el widget enseñe datos viejos como si fueran los que se
-- acaban de pedir.
data Refresh
  = Idle        -- ^ Nada en vuelo y lo último que llegó, llegó bien.
  | InFlight
  | LastFailed  -- ^ La recarga falló; se conserva lo anterior.

-- | La respuesta traducida a estado de petición.
refreshOf :: Maybe LapComparison -> Refresh
refreshOf = maybe LastFailed (const Idle)

-- | El aviso de la petición, __al lado__ del contenido y no en su lugar:
-- sustituirlo sería volver a la pantalla en blanco que 'step' evita.
--
-- Solo se muestra cuando ya hay datos debajo. Sin ellos el mensaje lo da
-- 'renderState' ('Loading' \/ 'Failed'), y dos a la vez serían ruido.
banner :: DomBuilder t m => (Refresh, CState) -> m ()
banner (r, Loaded _) = refreshLine r
banner _             = blank

-- | Una línea de estado por cada resultado posible de la petición.
refreshLine :: DomBuilder t m => Refresh -> m ()
refreshLine Idle       = blank
refreshLine InFlight   = elClass "p" "status status--busy" $ text "Actualizando…"
refreshLine LastFailed =
  elClass "p" "status status--stale" $
    text "No se pudo recargar: se muestra la comparación anterior"

-- | Las dos entradas de coche y el botón, y la URL que sale de pulsarlo.
--
-- __Dos entradas separadas y no una sola con @\"1,16\"@:__ así la cardinalidad
-- es estructural. El microservicio responde 400 a cualquier cantidad que no sea
-- dos, y ese 400 lo absorbe el @try@ del backend y vuelve como 200 con el dummy
-- (2026-08-01), así que impedir mandar uno o tres tiene que
-- ser cosa del widget y no del degradado.
--
-- Los valores iniciales son los de @Handler.Comparison.Context.defaultDrivers@:
-- lo que las entradas muestran al arrancar es lo que la primera petición —la de
-- 'getPostBuild', sin query— va a traer.
carSelector :: MonadWidget t m => m (Event t Text)
carSelector = divClass "car-selector" $ do
  carA  <- carInput "1"
  elClass "span" "car-selector__vs" $ text "vs"
  carB  <- carInput "16"
  click <- compareButton
  pure (fmapMaybe urlFor (tagPromptlyDyn (zipDyn carA carB) click))
  where
    -- 'fmapMaybe' es lo que hace que una entrada inválida __no dispare nada__,
    -- en vez de disparar y confiar en el degradado. Y el 'Just' interior no es
    -- ruido: 'comparisonPathFor' ya acepta 'Maybe', así que pasarle el 'Nothing'
    -- de una entrada inválida daría el path __sin__ query — la comparación por
    -- defecto presentada como la que se pidió.
    urlFor :: (Text, Text) -> Maybe Text
    urlFor (a, b) = comparisonPathFor Nothing . Just <$> driversParam a b

-- | Una entrada de número de coche. @inputmode@ saca el teclado numérico en
-- móvil; la validación de verdad la hace 'Common.Route.driversParam', que es
-- pura y está probada por @backend-test@ — aquí no se valida a mano nada.
carInput :: MonadWidget t m => Text -> m (Dynamic t Text)
carInput initial =
  fmap _textInput_value . textInput $
    def
      { _textInputConfig_initialValue = initial
      , _textInputConfig_attributes = constDyn carInputAttrs
      }

-- | Atributos de una entrada de coche. Como en el resto del módulo, no hay hoja
-- de estilos: la clase es el gancho para cuando la haya.
carInputAttrs :: Map Text Text
carInputAttrs =
  Map.fromList
    [ ("class", "car-selector__input")
    , ("size", "3")
    , ("inputmode", "numeric")
    ]

-- | Botón que dispara la comparación. Replicado aquí en lugar de importado de
-- 'Widgets.Historical' o 'Widgets.Telemetry': mismo criterio que allí, no
-- acoplar dos widgets entre sí por tres líneas de DOM.
compareButton :: DomBuilder t m => m (Event t ())
compareButton = do
  (e, _) <- elClass' "button" "car-selector__btn" $ text "Comparar"
  pure (domEvent Click e)

-- | Los dos pilotos con su tiempo de vuelta, tal cual llegan. @lcLapA@\/@lcLapB@
-- son 'Text' ya formateado (@M:SS.mmm@) por el microservicio: intentar
-- reformatearlos aquí sería reintroducir en el widget un trabajo que el servicio
-- ya hizo.
lapHeader :: DomBuilder t m => LapComparison -> m ()
lapHeader c = divClass "comparison__header" $ do
  lapLabel (lcDriverA c) (lcCarA c) (lcLapA c)
  elClass "span" "comparison__vs" $ text "vs"
  lapLabel (lcDriverB c) (lcCarB c) (lcLapB c)

-- | Un piloto, su coche y su tiempo.
--
-- El número de coche es __el único consumidor de @lcCarA@\/@lcCarB@__ y no es
-- decoración: es lo que confirma el viaje de vuelta. El widget pide números y
-- recibe acrónimos, así que sin el @#n@ no hay forma de ver que lo que volvió
-- corresponde a lo que se pidió — y en el caso del respaldo, de ver que __no__
-- corresponde: el dummy siempre habla de @1@ y @16@, así que pedir @44@ y leer
-- @#1@ es exactamente la señal de que el microservicio no contestó.
--
-- Se omite cuando viene vacío, que es la respuesta de un servicio anterior a
-- que la clave existiera (2026-08-05).
lapLabel :: DomBuilder t m => Text -> Text -> Text -> m ()
lapLabel driver car lap = divClass "comparison__lap" $ do
  elClass "span" "comparison__driver" $ text driver
  if T.null car
    then blank
    else elClass "span" "comparison__car" $ text ("#" <> car)
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
