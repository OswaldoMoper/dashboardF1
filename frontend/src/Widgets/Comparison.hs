{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}

-- | Widget de Comparación de Vueltas (categoría LapComparison).
--
-- Consume @GET \/api\/comparison@ en runtime vía 'Client.fetchJson' +
-- 'Common.Route.comparisonPathFor' al arrancar, al elegir coches y al pedir trazas
-- (relativos, misma-origen), con los tres estados del fetch
-- ('Loading' \/ 'Failed' \/ 'Loaded') y sin datos dummy locales, igual que
-- 'Widgets.LiveTiming', 'Widgets.Telemetry' e 'Widgets.Historical'.
--
-- __Es el primer widget del repo que pinta una serie y no una tabla.__ Pinta el
-- par de los dos primeros coches de 'Common.Types.LapComparison' (el primero es la
-- referencia) con la base que elige «Δ contra»: la serie es la Δ del coche que no es
-- la base ('Common.Comparison.pairWith').
-- Los tiempos vienen __ya formateados__ desde el microservicio (2026-07-31).
--
-- __El gráfico es SVG a mano, sin librería.__ El escalado vive en 'Common.Chart',
-- puro y probado por @backend-test@; este módulo solo monta el DOM. La
-- alternativa que @ARCHITECTURE.md §2.2@ contempla —Plotly\/Chart.js por FFI—
-- sigue en pie para el día que hagan falta tooltips o zoom, con el coste que
-- registró la decisión del 2026-08-04: servir el @.js@, escribir el
-- @foreign import javascript@ y sobre todo manejar que 'dyn_' __re-monte__ el
-- nodo bajo un gráfico imperativo, que es justo lo que pasa aquí con cada
-- respuesta.
--
-- __Es el primer widget del repo cuyo fetch no sale solo de 'getPostBuild'.__
-- Los tres switchers anteriores ('Widgets.Historical' ×2, 'Widgets.Telemetry')
-- filtran __en cliente__ sobre datos ya recibidos
-- (2026-08-01); aquí no se puede, porque la comparación de otros dos coches
-- sencillamente no está en la respuesta actual. De ahí las dos cosas nuevas:
-- un 'Event' de URL que nace de un clic y un estado de recarga que __no borra__
-- lo que ya se veía.
--
-- __Se eligen coches de la parrilla, no se teclean números.__ Es el desajuste de
-- vocabularios del repo (la API habla números, los widgets acrónimos,
-- 2026-08-01) cerrado por los dos extremos:
-- cada coche de 'Common.Types.LapComparison' trae su número junto al acrónimo
-- —de qué coches habla lo que se está pintando— y @\/api\/drivers@
-- publica desde el 2026-08-06 la parrilla entera —qué otros hay—. Este módulo es
-- el primer consumidor de las dos cosas: el usuario ve @\"1 · NOR — McLaren\"@ y
-- lo que sale hacia el endpoint sigue siendo el @1@.
--
-- __Son dos peticiones con dos degradados independientes__ (parrilla y
-- comparación), así que con el microservicio apagado el selector muestra los seis
-- coches del dummy de @Handler.Drivers.Context@ y el gráfico la comparación del
-- dummy de @Handler.Comparison.Context@. Que los dos hablen de coches
-- compatibles no es casualidad ni se comprueba aquí: lo fija un caso de
-- @backend-test@ (2026-08-06).
module Widgets.Comparison where

import           Client        (fetchJson)
import           Common.Chart  (SectorPace (..), SectorSpan (..), axisPolyline,
                                axisTicks, axisZeroY, chartHeight,
                                chartWidth, frontierCells, frontierCellsAt,
                                sectorSpans)
import           Common.ComparisonCard (CardLayout (..), ChartMode, Side (..),
                                        axisColumnWidth, cardLayout, curveInset,
                                        tracesInset,
                                        defaultControlSide, defaultMode,
                                        insideAxisLabels, modeEnabled,
                                        modeFromKey, modeKey, modeOption,
                                        modesInOrder, otherSide, rowHeight,
                                        rowTitle,
                                        shownMode, showsNames, showsValues,
                                        stretchFor, valueHeight,
                                        valuesFitMeasured, vsBeside)
import           Common.Comparison (Axis, Baseline (..), ChartType, Pair (..),
                                    axesInOrder, axisFromKey, axisKey,
                                    axisLabel, axisNotice, baselineFromKey,
                                    baselineKey, baselineLabel, baselineRole,
                                    baselinesInOrder, chartTypeFromKey,
                                    chartTypeKey, chartTypeLabel,
                                    chartTypeReady, chartTypeTraces,
                                    chartTypesInOrder, defaultAxis,
                                    defaultChartType, deltaFormula, lapShown,
                                    missingReference, noLapFor, pairWith)
import           Common.Format (formatFixed)
import           Common.Route  (comparisonPathFor, driversParam, driversPathFor)
import           Common.Traces (TraceRows (..), axisEnd, axisEndLabel,
                                boundaryXs, channelCaption, channelHeight,
                                channelRange, channelTop, channelsSpan,
                                frontierXs, readSamples, samplesMax,
                                samplesMin, samplesStart, samplesStep,
                                stretchesSpeed, traceChannels, traceXs,
                                tracePoints, tracesHeight, tracesWidth,
                                xPercent)
import           Common.Types  (ComparisonEntry (..), DriverEntry (..),
                                LapComparison (..))
import           Control.Monad (forM_, unless, when)
import           Control.Monad.IO.Class (liftIO)
import           Data.List     (find)
import           Data.Map      (Map)
import qualified Data.Map      as Map
import           Data.Maybe    (fromMaybe, listToMaybe)
import           Data.Text     (Text)
import qualified Data.Text     as T
import qualified GHCJS.DOM     as DOM (currentWindowUnchecked)
import qualified GHCJS.DOM.DOMRectReadOnly as DOM (getHeight)
import qualified GHCJS.DOM.Element as DOM (getBoundingClientRect, getClientHeight)
import qualified GHCJS.DOM.EventM as DOM (on)
import qualified GHCJS.DOM.GlobalEventHandlers as DOM (resize)
import qualified GHCJS.DOM.HTMLElement as DOM (getOffsetHeight, getOffsetWidth)
import qualified GHCJS.DOM.Types as DOM (Element (..), HTMLElement (..),
                                         liftJSM, uncheckedCastTo)
import qualified Language.Javascript.JSaddle as JS
import           Reflex.Dom

-- | Estado del fetch de @\/api\/comparison@. 'Failed' (no 'Error') para no
-- chocar con nombres de @base@\/@Prelude@, mismo criterio que los otros widgets.
data CState
  = Loading
  | Failed
  | Loaded LapComparison

-- | Comparación de la vuelta rápida de dos coches: la tabla de mando (selectores y
-- los dos pilotos con su tiempo), la gráfica del delta acumulado y la leyenda al
-- pie, a todo el ancho.
--
-- La tarjeta se reparte según su ancho medido ('Common.ComparisonCard.cardLayout'):
-- dos columnas, con la tabla de mando en el lado que elige «⇄», o apilada. Hasta la
-- primera medida se pinta apilada.
--
-- El eje vertical va siempre. El desplegable de modos elige qué lleva la fila de
-- fronteras y enseña el modo que se ve ('Common.ComparisonCard.shownMode'); la
-- elección del usuario se guarda aparte y vuelve en cuanto caben las dos líneas.
-- Pulsar la fila la turna con la banda de sectores ('frontierRowAt'); abre con la fila.
--
-- El selector va fuera de los 'dyn_', que lo devolverían a su valor inicial en cada
-- respuesta; sus opciones entran como 'Dynamic' (2026-08-07).
--
-- La parrilla se pide una sola vez. Parrilla y comparación son dos peticiones que
-- podrían discrepar; hoy las dos van a @latest@ (2026-08-07).
--
-- El 'mdo' cierra un ciclo real —la selección compone la URL y la respuesta marca
-- la selección— que no se cierra en el mismo instante porque 'Client.fetchJson' es
-- asíncrono. El prefill sale de @state@, lo que se está pintando, y no de @resp@
-- (2026-08-07).
--
-- @revealed@ avisa de que la tarjeta se acaba de enseñar tras estar oculta: oculta
-- mide 0, así que al enseñarse se vuelve a medir.
comparisonWidget :: MonadWidget t m => Event t () -> m ()
comparisonWidget revealed = mdo
  (root, (card, (userMode, state, view))) <-
    elClass' "div" "widget widget--comparison" $ elClass' "div" "comparison__card" $ mdo
      (swap, ty, (axis, frontiers, samples)) <- divClass "widget__head" $ do
        el "h2" $ text "Lap Comparison"
        t  <- typeSelect
        tc <- traceControls t
        s  <- swapButton (clStacked <$> layout)
        pure (s, t, tc)
      side    <- foldDyn (const otherSide) defaultControlSide swap
      pb      <- getPostBuild
      gridRsp <- fetchJson (driversPathFor Nothing <$ pb)
      grid    <- holdDyn [] (fromMaybe [] <$> gridRsp)
      ((picked, chosenE), rowClicks) <- elDynAttr "div" (bodyAttrs <$> side <*> layout) $ do
        r <- elDynAttr "div" (controlAttrs <$> layout) $ do
          r' <- carSelector grid (shownComparison <$> st) (vsNextTo <$> layout)
                  (modeSelect fits shown)
          dyn_ (controlState <$> st)
          pure r'
        clicks <- divClass "comparison__plot" $
          switchHold never =<< dyn
            ( plotView (dyn_ (banner <$> zipDyn refresh st))
                <$> ((\c s -> RowMode c s band) <$> chosen <*> shown) <*> layout
                <*> (otherSide <$> side) <*> v <*> stretch <*> st )
        pure (r, clicks)
      band    <- toggle False rowClicks
      b       <- legendRow ty axis st
      wanted  <- holdUniqDyn ((\t n -> if chartTypeTraces t then n else 0) <$> ty <*> samples)
      drivers <- holdDyn Nothing (Just <$> picked)
      let v       = View <$> ty <*> b <*> axis <*> frontiers
          request = leftmost
            [ comparisonPathFor Nothing Nothing <$> tag (current wanted) pb
            , attachWith (\n d -> comparisonPathFor Nothing (Just d) n) (current wanted) picked
            , attachWith (comparisonPathFor Nothing) (current drivers) (ffilter (> 0) (updated wanted))
            ]
      resp    <- fetchJson request
      refresh <- holdDyn InFlight (leftmost [InFlight <$ request, refreshOf <$> resp])
      st      <- foldDyn step Loading resp
      pure (chosenE, st, v)
  size    <- cardSize root card (current ((,) <$> rowNow <*> drawn)) changed
  stretch <- holdUniqDyn (maybe 0 (\(_, _, s) -> s) <$> size)
  stacked <- holdUniqDyn (clStacked <$> layout)
  chosen  <- holdDyn defaultMode userMode
  shown   <- holdUniqDyn (shownMode <$> fits <*> chosen)
  let layout   = cardLayout . maybe 0 (\(w, _, _) -> w) <$> size
      fits     = maybe True (\(_, f, _) -> f) <$> size
      rowNow   = rowHeightNow <$> shown <*> view <*> state
      drawn    = stretchDrawn <$> view <*> state <*> stretch
      changed  = leftmost
                   [ () <$ updated shown, () <$ updated state, () <$ updated view
                   , () <$ updated stacked, revealed ]
  pure ()
  where
    controlState :: MonadWidget t m => CState -> m ()
    controlState (Loaded c) = lapHeader c
    controlState _          = blank

-- | Lo que el usuario eligió para pintar la comparación: el tipo, la base de la Δ, el
-- eje de las trazas y si van sus fronteras.
data View = View
  { vType      :: ChartType
  , vBase      :: Baseline
  , vAxis      :: Axis
  , vFrontiers :: Bool
  }
  deriving Eq

-- | El alto de la fila de fronteras pintada: el de su modo si hay fronteras que
-- nombrar, 0 si no hay fila.
rowHeightNow :: ChartMode -> View -> CState -> Double
rowHeightNow m v (Loaded c) | not (null (frontierCells (seriesOf (vBase v) c))) = rowHeight m
rowHeightNow _ _ _          = 0

-- | Lo que está estirada la velocidad pintada, o 'Nothing' si no hay una velocidad que
-- se estire pintada: otro tipo, o sin comparación, o con el aviso de la referencia sin
-- vuelta en su lugar.
stretchDrawn :: View -> CState -> Double -> Maybe Double
stretchDrawn v (Loaded c) s
  | stretchesSpeed (traceChannels (vType v))
  , Nothing <- missingReference (vBase v) c
  , _ : _ : _ <- lcEntries c = Just s
stretchDrawn _ _ _ = Nothing

-- | La serie que se pinta con una base: la Δ del coche que no es la base
-- ('Common.Comparison.pairWith'), o @[]@.
seriesOf :: Baseline -> LapComparison -> [Double]
seriesOf b = maybe [] pairDelta . pairWith b

-- | La fila de la leyenda: «Δ contra [Referencia ▾]» y la leyenda como un bloque,
-- repartidos con @space-evenly@ (2026-10-01 (g)), y la base elegida. El desplegable
-- va fuera del 'dyn_', que lo devolvería a «Referencia» en cada respuesta; la fila
-- se esconde mientras no hay comparación.
--
-- En los tipos con trazas, debajo va siempre el aviso de su eje
-- ('Common.Comparison.axisNotice', 2026-09-30 (a)).
legendRow
  :: MonadWidget t m
  => Dynamic t ChartType -> Dynamic t Axis -> Dynamic t CState -> m (Dynamic t Baseline)
legendRow ty axis st = do
  b <- elDynAttr "div" (attrs <$> st) $ do
    b' <- elClass "span" "comparison__against" $ do
      text "Δ contra "
      baselineSelect
    elClass "span" "comparison__keys" $ dyn_ (legendState <$> ty <*> b' <*> st)
    pure b'
  dyn_ (note <$> ty <*> axis <*> st)
  pure b
  where
    attrs (Loaded _) = "class" =: "comparison__legend"
    attrs _          = ("class" =: "comparison__legend") <> ("hidden" =: "")
    legendState t b (Loaded c)
      | chartTypeTraces t = traceLegend b c
      | otherwise         = legend b c
    legendState _ _ _ = blank
    note t a (Loaded _)
      | chartTypeTraces t = elClass "p" "comparison__note" $ text (axisNotice a)
    note _ _ _ = blank

-- | El desplegable del tipo de gráfica, en el título y nativo: los cuatro tipos,
-- con los que aún no existen en gris ('Common.Comparison.chartTypeReady'), y el
-- tipo elegido. Abre en 'Common.Comparison.defaultChartType'.
typeSelect :: MonadWidget t m => m (Dynamic t ChartType)
typeSelect = do
  let cfg = def
        & selectElementConfig_initialValue .~ chartTypeKey defaultChartType
        & selectElementConfig_elementConfig . elementConfig_initialAttributes
            .~ ("class" =: "car-selector__select comparison__type")
  (sel, _) <- selectElement cfg $ forM_ chartTypesInOrder $ \ty ->
    elAttr "option" (optionAttrs ty) $ text (chartTypeLabel ty)
  pure (fromMaybe defaultChartType . chartTypeFromKey <$> _selectElement_value sel)
  where
    optionAttrs ty =
      ("value" =: chartTypeKey ty) <> if chartTypeReady ty then mempty else "disabled" =: "disabled"

-- | Los mandos de las trazas, en el título y solo en los tipos que las pintan
-- (2026-09-30 (a)): el eje, las muestras y las fronteras. Abren en Tiempo, 100 y
-- con fronteras. Van siempre montados —escondidos en los otros tipos— para que no
-- vuelvan a su valor inicial al cambiar de tipo.
--
-- Devuelve el eje, si van las fronteras y las muestras que se piden: mientras se
-- arrastra el deslizable, como mucho una vez cada 200 ms y la última al soltar
-- (2026-10-01 (e)); el número de al lado cambia al momento.
traceControls
  :: MonadWidget t m
  => Dynamic t ChartType -> m (Dynamic t Axis, Dynamic t Bool, Dynamic t Int)
traceControls ty =
  elDynAttr "span" (attrs <$> ty) $ do
    let axisCfg = def
          & selectElementConfig_initialValue .~ axisKey defaultAxis
          & selectElementConfig_elementConfig . elementConfig_initialAttributes
              .~ Map.fromList [("class", "car-selector__select comparison__axis-select"), ("title", "Eje X")]
    (axisSel, _) <- selectElement axisCfg $ forM_ axesInOrder $ \a ->
      elAttr "option" ("value" =: axisKey a) $ text (axisLabel a)
    picked <- elAttr "label" (Map.fromList [("class", "comparison__samples"), ("title", "Muestras por piloto")]) $ do
      text "Muestras"
      slider <- inputElement $
        def
          & inputElementConfig_initialValue .~ T.pack (show samplesStart)
          & initialAttributes .~ Map.fromList
              [ ("type", "range"), ("class", "comparison__slider")
              , ("min", T.pack (show samplesMin)), ("max", T.pack (show samplesMax))
              , ("step", T.pack (show samplesStep)) ]
      let typed = fmapMaybe readSamples (_inputElement_input slider)
      now <- holdDyn samplesStart typed
      el "output" $ dynText (T.pack . show <$> now)
      throttle 0.2 typed
    box <- elClass "label" "comparison__check" $ do
      b <- inputElement $
        def
          & inputElementConfig_initialChecked .~ True
          & initialAttributes .~ ("type" =: "checkbox")
      text "Fronteras"
      pure b
    samples <- holdDyn samplesStart picked
    pure ( fromMaybe defaultAxis . axisFromKey <$> _selectElement_value axisSel
         , _inputElement_checked box
         , samples )
  where
    attrs t
      | chartTypeTraces t = "class" =: "comparison__trace-controls"
      | otherwise         = ("class" =: "comparison__trace-controls") <> ("hidden" =: "")

-- | El desplegable «Δ contra», nativo; abre en «Referencia».
baselineSelect :: MonadWidget t m => m (Dynamic t Baseline)
baselineSelect = do
  let cfg = def
        & selectElementConfig_initialValue .~ baselineKey AgainstReference
        & selectElementConfig_elementConfig . elementConfig_initialAttributes
            .~ ("class" =: "car-selector__select comparison__baseline")
  (sel, _) <- selectElement cfg $ forM_ baselinesInOrder $ \b ->
    elAttr "option" ("value" =: baselineKey b) $ text (baselineLabel b)
  pure (fromMaybe AgainstReference . baselineFromKey <$> _selectElement_value sel)

-- | Lo que se mide de la tarjeta: su ancho por dentro, en px; si caben las dos
-- líneas de la fila de fronteras sin que pida scroll
-- ('Common.ComparisonCard.valuesFitMeasured', con la velocidad en su mínimo), y lo
-- que se estira la velocidad pintada para llenarla ('Common.ComparisonCard.stretchFor';
-- 0 si no hay una que se estire). El 'Behavior' da el alto de la fila pintada y lo
-- estirado ahora ('stretchDrawn').
--
-- Se mide al montarse, cada vez que cambia la ventana o el tamaño de la tarjeta o de
-- su contenido ('sizeChanges'), y un instante después de cada evento del último argumento
-- (cambios del contenido, o que se acaba de enseñar). Mientras la tarjeta aún no está
-- en la página, o está oculta, mide 0, y se vuelve a medir cada 0,2 s hasta
-- 'measureTries' veces. 'Nothing' hasta la primera medida con ancho; no cambia si la
-- medida se repite.
cardSize
  :: MonadWidget t m
  => Element EventResult GhcjsDomSpace t
  -> Element EventResult GhcjsDomSpace t
  -> Behavior t (Double, Maybe Double)
  -> Event t ()
  -> m (Dynamic t (Maybe (Double, Bool, Double)))
cardSize root card drawnNow changed = mdo
  mounted  <- delay 0 =<< getPostBuild
  win      <- DOM.liftJSM DOM.currentWindowUnchecked
  resized  <- wrapDomEvent win (`DOM.on` DOM.resize) (pure ())
  settled  <- delay 0 changed
  grown    <- sizeChanges [_element_raw root, _element_raw card]
  measured <- performEvent (measure <$> tag drawnNow (leftmost [mounted, resized, settled, grown, retry]))
  let zero = ffilter (\(w, _, _) -> w <= 0) measured
  tries    <- count zero
  retry    <- delay 0.2 (() <$ ffilter (< measureTries) (tag (current tries) zero))
  holdUniqDyn =<< holdDyn Nothing (Just <$> ffilter (\(w, _, _) -> w > 0) measured)
  where
    cardEl = DOM.uncheckedCastTo DOM.HTMLElement (_element_raw card)
    measure (row, stretched) = DOM.liftJSM $ do
      w       <- DOM.getOffsetWidth cardEl
      content <- DOM.getOffsetHeight cardEl
      client  <- DOM.getClientHeight (_element_raw root)
      exact   <- DOM.getHeight =<< DOM.getBoundingClientRect cardEl
      pure ( w
           , valuesFitMeasured client content (row + fromMaybe 0 stretched)
           , maybe 0 (stretchFor client exact) stretched )

-- | Cuántas veces se vuelve a medir una tarjeta que mide 0 (10 s en total).
measureTries :: Int
measureTries = 50

-- | Un evento cada vez que el navegador ve cambiar el tamaño de alguno de los
-- elementos, ya pintado (@ResizeObserver@), y al empezar a observarlos. Los observa
-- mientras viva la página.
sizeChanges :: MonadWidget t m => [DOM.Element] -> m (Event t ())
sizeChanges es = do
  (changes, fire) <- newTriggerEvent
  DOM.liftJSM $ do
    cb  <- JS.function (\_ _ _ -> liftIO (fire ()))
    obs <- JS.new (JS.jsg ("ResizeObserver" :: Text)) [JS.toJSVal cb]
    forM_ es $ \e -> obs JS.# ("observe" :: Text) $ [JS.toJSVal e]
  pure changes

-- | El botón que pasa la tabla de mando al otro lado. Con la tarjeta apilada no
-- hay lados y se oculta; el lado elegido se conserva.
swapButton :: MonadWidget t m => Dynamic t Bool -> m (Event t ())
swapButton stacked = do
  (e, _) <- elDynAttr' "button" (attrs <$> stacked) $ text "⇄"
  pure (domEvent Click e)
  where
    attrs s =
      Map.fromList $
        [ ("class", "comparison__swap")
        , ("type", "button")
        , ("title", "Pasar la tabla de mando al otro lado")
        ]
          <> [("hidden", "") | s]

-- | Atributos del cuerpo de la tarjeta: dos columnas (con la tabla de mando a la
-- derecha si toca) o apilada.
bodyAttrs :: Side -> CardLayout -> Map Text Text
bodyAttrs side l =
  Map.singleton "class" . T.unwords $
    ["comparison__body"]
      <> ["comparison__body--stacked" | clStacked l]
      <> ["comparison__body--control-right" | side == SideRight, not (clStacked l)]

-- | Si el «VS» va a la derecha del primer desplegable: solo con dos columnas, y
-- cuando cabe ('vsBeside'). Apilada, los dos desplegables y el «VS» ya comparten
-- línea.
vsNextTo :: CardLayout -> Bool
vsNextTo l = not (clStacked l) && vsBeside (clControl l)

-- | Atributos del grupo de los dos desplegables y el «VS».
pairAttrs :: Bool -> Map Text Text
pairAttrs next =
  Map.singleton "class" . T.unwords $
    ["car-selector__pair"] <> ["car-selector__pair--vs-beside" | next]

-- | Atributos de la tabla de mando: su ancho con dos columnas; apilada, el de la
-- tarjeta.
controlAttrs :: CardLayout -> Map Text Text
controlAttrs l =
  Map.fromList $
    ("class", "comparison__control")
      : [("style", "width: " <> formatFixed 1 (clControl l) <> "px") | not (clStacked l)]

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

-- | La comparación que el gráfico está pintando, si hay alguna. Es lo que
-- 'carSelector' necesita para marcar el par activo, y sale del __estado__ y no
-- de la respuesta a propósito ('comparisonWidget'): tras una recarga fallida
-- 'step' conserva el gráfico anterior, y los selectores tienen que seguir
-- señalando ése y no quedarse en blanco.
shownComparison :: CState -> Maybe LapComparison
shownComparison (Loaded c) = Just c
shownComparison _          = Nothing

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

-- | El aviso de la petición, __encima__ de la curva y no en su lugar:
-- sustituirlo sería volver a la pantalla en blanco que 'step' evita. Flota en el
-- centro del lienzo, sin mover nada de la tarjeta.
--
-- Solo se muestra cuando ya hay datos debajo. Sin ellos el mensaje lo da
-- la gráfica ('Loading' \/ 'Failed'), y dos a la vez serían ruido.
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

-- | Los dos selectores de coche y el botón, y el valor de @?drivers=@ que sale de
-- pulsarlo; la URL la compone 'comparisonWidget' con las muestras del tipo.
--
-- __Dos controles separados y no uno solo con @\"16,1\"@:__ así la cardinalidad
-- es estructural —la tarjeta pinta un par—. El primero es la referencia, y va
-- primero en el query. Es lo único que sobrevive intacto del par de @\<input\>@ que
-- había aquí hasta el 2026-08-07.
--
-- __Las posiciones iniciales, 1 y 0, no son la selección de verdad:__ son lo que
-- se ve durante el instante que va del arranque a la primera respuesta. El par
-- que el gráfico pinta lo marca el prefill, y tiene que ser así porque
-- @Handler.Comparison.Helper.defaultDrivers@ son los coches @16@ y @1@ y sus
-- posiciones dependen de la parrilla: en el dummy son la 1 y la 0 y en la parrilla
-- real la __3__ y la 0.
--
-- El tercer argumento dice si el «VS» va a la derecha del primer desplegable
-- ('vsNextTo'). El último se pinta junto a «Comparar», en la misma fila, y su
-- resultado se devuelve con los coches.
carSelector
  :: MonadWidget t m
  => Dynamic t [DriverEntry]
  -> Dynamic t (Maybe LapComparison)
  -> Dynamic t Bool
  -> m a
  -> m (Event t Text, a)
carSelector grid shown vsNext beside = divClass "car-selector" $ mdo
  let indexed = indexedGrid <$> grid
      labels  = Map.map driverLabel <$> indexed
      -- El prefill de un lado: la posición que ocupa hoy el coche del que habla
      -- el gráfico. 'updated' sobre las __dos__ fuentes y no un 'Event' de la
      -- respuesta, porque parrilla y comparación son dos peticiones y llegan en
      -- cualquier orden: con solo la respuesta, la que se adelante a la parrilla
      -- buscaría el coche en una lista vacía y el prefill se perdería para
      -- siempre.
      setPos i = fmapMaybe id (updated (zipDynWith (positionFor (carOf i)) indexed shown))
      refCar   = zipDynWith carAt indexed posRef
      otherCar = zipDynWith carAt indexed posOther
  (posRef, posOther) <- elDynAttr "div" (pairAttrs <$> vsNext) $ do
    r <- carDropdown 1 labels (setPos 0) (carSelectAttrs <$> refCar <*> shown)
    elClass "span" "car-selector__vs" $ text "vs"
    o <- carDropdown 0 labels (setPos 1) (carSelectAttrs <$> otherCar <*> shown)
    pure (r, o)
  (click, a) <- divClass "comparison__actions" $ (,) <$> compareButton <*> beside
  let picked = zipDyn refCar otherCar
  pure (fmapMaybe driversFor (tagPromptlyDyn picked click), a)
  where
    -- 'fmapMaybe' es lo que hace que una selección incompleta __no dispare
    -- nada__, en vez de disparar y confiar en el degradado: un 'Nothing' que llegara
    -- a 'comparisonPathFor' daría el path __sin__ coches — la comparación por
    -- defecto presentada como la que se pidió.
    --
    -- Los dos 'Nothing' que hay que absorber son el mismo: parrilla vacía. Pasa
    -- entre el arranque y la respuesta de @\/api\/drivers@, y ahí un clic no
    -- puede significar nada.
    driversFor :: (Maybe Text, Maybe Text) -> Maybe Text
    driversFor (mref, mother) = do
      ref   <- mref
      other <- mother
      driversParam ref other

-- | La parrilla indexada por __posición__, que es la clave de los dos
-- 'dropdown'.
--
-- __La clave es la posición y no el número de coche, y no es un detalle:__
-- 'dropdown' ordena las opciones por la clave del 'Map' (su propia fuente lo
-- reconoce con un @TODO@), así que un @'Map' 'Text'@ sobre @deNumber@ daría el
-- orden lexicográfico @1, 10, 11, 12, 14, 16, 3, 44…@ y un @'Map' 'Int'@ del
-- número obligaría a parsear @deNumber@ y a decidir qué hacer con lo que no
-- parsee. Con la posición, el orden del 'Map' __es__ el que dio FastF1 —medido
-- el 2026-08-07: @1 3 12 16 44 6 63 30 27 41 5 10 18 14 43 31 23 55 87 81 11
-- 77@, que en una carrera cargada es el de clasificación— y que
-- la decisión del 2026-08-06 registra como información del servicio:
-- reordenar aquí la destruiría.
--
-- El precio es que la selección no lleva el número encima y hay que buscarlo
-- ('carAt') contra la misma parrilla.
indexedGrid :: [DriverEntry] -> Map Int DriverEntry
indexedGrid = Map.fromList . zip [0 ..]

-- | El número de coche de una posición, o 'Nothing' si la parrilla no la tiene.
--
-- Devuelve el __número__ y no el 'DriverEntry' entero porque es lo único que
-- sale del widget: el acrónimo es para mirar, el número es lo que la API
-- entiende (2026-08-01).
carAt :: Map Int DriverEntry -> Int -> Maybe Text
carAt indexed = fmap deNumber . flip Map.lookup indexed

-- | La posición que ocupa un número de coche en la parrilla, o 'Nothing' si no
-- está. Es 'carAt' al revés, y hace falta porque el widget habla dos idiomas: el
-- 'dropdown' se maneja por posición ('indexedGrid') y la respuesta trae números.
--
-- Recorre la lista en vez de mantener un índice inverso: son 22 entradas y se
-- consulta dos veces por respuesta.
positionOf :: Map Int DriverEntry -> Text -> Maybe Int
positionOf indexed car =
  fst <$> find ((== car) . deNumber . snd) (Map.toAscList indexed)

-- | La posición a la que hay que llevar un selector, dada la parrilla vigente y
-- lo que el gráfico está pintando. 'Nothing' —y por tanto ningún @setValue@— en
-- los dos casos en que mover el selector sería mentir: todavía no hay
-- comparación, o el coche del que habla __no está en la parrilla__.
--
-- El segundo caso no es hipotético: con el microservicio apagado la comparación
-- es el dummy (@16@ y @1@) y la parrilla puede ser la real de otra sesión
-- cacheada. Que el selector se quede donde estaba y el @#n@ de 'lapLabel'
-- discrepe es justo la señal de que lo pintado no es lo pedido.
positionFor
  :: (LapComparison -> Maybe Text)
  -> Map Int DriverEntry
  -> Maybe LapComparison
  -> Maybe Int
positionFor car indexed shown = positionOf indexed =<< (car =<< shown)

-- | El número del coche @i@ de la comparación (0, la referencia), si lo hay.
carOf :: Int -> LapComparison -> Maybe Text
carOf i = fmap ceCar . listToMaybe . drop i . lcEntries

-- | La etiqueta de una opción: @\"1 · NOR — McLaren\"@.
--
-- Los tres campos de 'Common.Types.DriverEntry', y @deTeam@ entró al DTO en la
-- 2026-08-06 precisamente para esto. El __número__ va delante porque es lo que
-- permite cotejar de un vistazo lo elegido con el @#n@ que 'lapLabel' pinta en
-- la cabecera del gráfico: sin él no habría forma de ver que la respuesta
-- corresponde a lo pedido.
--
-- Con @deTeam@ vacío se omite el guion largo en vez de dejarlo colgando. Vacío
-- es lo que devuelve un microservicio que no resolvió el equipo, y también lo
-- que da @.:? … .!= \"\"@ ante uno anterior a que el campo existiera
-- (2026-08-06).
driverLabel :: DriverEntry -> Text
driverLabel d
  | T.null (deTeam d) = core
  | otherwise         = core <> " — " <> deTeam d
  where
    core = deNumber d <> " · " <> deCode d

-- | Un selector de coche: la posición inicial y las opciones, que __cambian__
-- cuando llega la parrilla sin remontar el @\<select\>@, así que no se pierde lo
-- que el usuario ya hubiera elegido.
--
-- El tercer argumento es el prefill, que sale de 'carSelector' y cierra el ciclo
-- del @mdo@ de 'comparisonWidget'. Da igual si llega antes que la parrilla:
-- 'dropdown' une la clave de @setValue@ a las opciones (2026-08-07).
--
-- La config se arma con lentes (@&@ y @.~@) y no con @def { ... }@, que aquí no
-- compila (@GHC-39999@, 2026-08-11 (b)).
carDropdown
  :: MonadWidget t m
  => Int
  -> Dynamic t (Map Int Text)
  -> Event t Int
  -> Dynamic t (Map Text Text)
  -> m (Dynamic t Int)
carDropdown initial options setPos attrs =
  fmap _dropdown_value . dropdown initial options $
    def
      &  dropdownConfig_attributes .~ attrs
      &  dropdownConfig_setValue   .~ setPos

-- | Atributos de un selector de coche: en amarillo y con el aviso de
-- 'Common.Comparison.noLapFor' como tooltip mientras el coche que tiene elegido
-- aparece sin vuelta en la comparación que se pinta (2026-10-02).
carSelectAttrs :: Maybe Text -> Maybe LapComparison -> Map Text Text
carSelectAttrs car shown =
  case (\c -> noLapFor c =<< shown) =<< car of
    Just note ->
      Map.fromList [("class", "car-selector__select car-selector__select--nolap"), ("title", note)]
    Nothing -> Map.fromList [("class", "car-selector__select")]

-- | Botón que dispara la comparación. Replicado aquí en lugar de importado de
-- 'Widgets.Historical' o 'Widgets.Telemetry': mismo criterio que allí, no
-- acoplar dos widgets entre sí por tres líneas de DOM.
compareButton :: DomBuilder t m => m (Event t ())
compareButton = do
  (e, _) <- elClass' "button" "car-selector__btn" $ text "Comparar"
  pure (domEvent Click e)

-- | El desplegable de modos, nativo: enseña el modo que se ve, apaga «Eje y
-- valores» cuando la fila no cabe, y devuelve solo lo que elige el usuario (el
-- valor que pone el código no dispara nada).
modeSelect
  :: MonadWidget t m
  => Dynamic t Bool
  -> Dynamic t ChartMode
  -> m (Event t ChartMode)
modeSelect fits shown = do
  pb <- getPostBuild
  let cfg = def
        & selectElementConfig_initialValue .~ modeKey defaultMode
        & selectElementConfig_setValue .~ (modeKey <$> leftmost [updated shown, tag (current shown) pb])
        & selectElementConfig_elementConfig . elementConfig_initialAttributes
            .~ ("class" =: "car-selector__select comparison__modes")
  (sel, _) <- selectElement cfg $ forM_ modesInOrder $ \m ->
    elDynAttr "option" (optionAttrs m <$> fits) $ dynText ((`modeOption` m) <$> fits)
  pure (fmapMaybe modeFromKey (_selectElement_change sel))
  where
    optionAttrs m f =
      ("value" =: modeKey m) <> if modeEnabled f m then mempty else "disabled" =: "disabled"

-- | Los dos primeros coches con su tiempo de vuelta, la referencia primero. El
-- tiempo llega ya formateado (@M:SS.mmm@) por el microservicio, y un coche sin
-- vuelta dice «sin vuelta» ('Common.Comparison.lapShown').
lapHeader :: DomBuilder t m => LapComparison -> m ()
lapHeader c = divClass "comparison__header" $
  case lcEntries c of
    ref : other : _ -> do
      lapLabel ref
      elClass "span" "comparison__vs" $ text "vs"
      lapLabel other
    [ref] -> lapLabel ref
    []    -> blank

-- | Un piloto, su coche y su tiempo.
--
-- El número de coche no es decoración: es lo que confirma el viaje de vuelta. El
-- widget pide números y recibe acrónimos, así que sin el @#n@ no hay forma de ver
-- que lo que volvió corresponde a lo que se pidió — y en el caso del respaldo, de
-- ver que __no__ corresponde: el dummy siempre habla de @16@ y @1@, así que pedir
-- @44@ y leer @#16@ es exactamente la señal de que el microservicio no contestó.
lapLabel :: DomBuilder t m => ComparisonEntry -> m ()
lapLabel e = divClass "comparison__lap" $ do
  elClass "span" "comparison__who" $ do
    elClass "span" "comparison__driver" $ text (ceDriver e)
    elClass "span" "comparison__car" $ text ("#" <> ceCar e)
  elClass "span" "comparison__time" $ text (lapShown e)

-- | Lo que la fila de fronteras necesita para turnarse con la banda de sectores: el
-- modo elegido, que decide qué lleva la banda; el que se ve, que decide la fila y su
-- alto (la banda no lo cambia), y si está puesta la banda.
data RowMode t = RowMode
  { rmChosen :: ChartMode
  , rmShown  :: ChartMode
  , rmBand   :: Dynamic t Bool
  }

-- | La gráfica según el reparto, el lado del eje y el modo de la fila: la curva, el
-- eje vertical (en su columna o dentro, según 'clAxisInside') y la fila de
-- fronteras. El primer argumento se pinta encima de la curva, dentro de su lienzo:
-- el aviso de la petición. Si la referencia no tiene vuelta, en lugar de todo eso va
-- el aviso de 'Common.Comparison.missingReference'. El penúltimo argumento es lo que
-- se estira la velocidad del tipo 2. Devuelve los clics en la fila ('never' sin fila).
plotView
  :: MonadWidget t m
  => m () -> RowMode t -> CardLayout -> Side -> View -> Double -> CState -> m (Event t ())
plotView _ _ _ _ _ _ Loading =
  never <$ elClass "p" "status status--loading" (text "Cargando…")
plotView _ _ _ _ _ _ Failed =
  never <$ elClass "p" "status status--error" (text "Error al cargar /api/comparison")
plotView overlay rm l axis v stretch (Loaded c)
  | Just note <- missingReference (vBase v) c = never <$ elClass "p" "status status--empty" (text note)
  | chartTypeTraces (vType v) = tracesView overlay rm v stretch c
  | otherwise =
      elAttr "div" (plotRowAttrs axis) $ do
        clicks <- divClass "comparison__plotarea" $ do
          divClass "comparison__canvas" $ do
            deltaChart series
            when (clAxisInside l) $
              mapM_ insideTick (insideAxisLabels axis (clChart l) series)
            overlay
          frontierRow rm series
        unless (clAxisInside l) $ axisColumn axis series
        pure clicks
  where
    series = seriesOf (vBase v) c

-- | Las trazas de los dos primeros coches: los canales del tipo
-- ('Common.Traces.traceChannels') en el eje elegido, con las fronteras de cada coche
-- si van y, debajo, la fila Δ en las fronteras de la referencia. La referencia en rojo y el
-- otro en blanco, encima la referencia (2026-10-02). Un coche sin traza —sin vuelta,
-- o el dummy— no se pinta, y sin ninguna quedan los canales vacíos.
--
-- Las líneas van en un @\<svg\>@ que se estira a lo ancho, con trazo que no se
-- estira; los rótulos van en HTML encima, en porcentaje del ancho. El lienzo y la fila
-- entran 'Common.ComparisonCard.tracesInset'. La velocidad sola se estira lo que diga
-- el cuarto argumento ('Common.Traces.TraceRows').
tracesView
  :: MonadWidget t m => m () -> RowMode t -> View -> Double -> LapComparison -> m (Event t ())
tracesView overlay rm v stretch c = case lcEntries c of
  ref : other : _ -> do
    let axis  = vAxis v
        cars  = [(other, traceOtherColor), (ref, traceRefColor)]
        xMax  = maximum [axisEnd axis ref e | e <- [ref, other]]
        delta = seriesOf (vBase v) c
        cells = case boundaryXs axis ref of
          Just xs | not (null delta) -> frontierCellsAt (map (xPercent xMax) xs) delta
          _                          -> []
    elAttr "div" (Map.fromList [("class", "comparison__canvas comparison__canvas--traces"), ("style", insetStyle tracesInset)]) $ do
      svgEl "svg" (tracesAttrs rows) $ do
        forM_ (trChannels rows) $ \ch -> do
          let range@(lo, hi) = channelRange ch [ref, other]
          forM_ [lo, hi] $ \y -> svgEl "line" (traceGridAttrs (rowY ch range y)) blank
          forM_ cars $ \(e, color) -> do
            let pts = tracePoints rows ch range xMax (traceXs axis ref e) (ceTrace e)
            unless (T.null pts) $ svgEl "polyline" (tracePolylineAttrs color pts) blank
        when (vFrontiers v) $
          forM_ cars $ \(e, color) ->
            forM_ (frontierPair (frontierXs axis ref e)) $ \x ->
              svgEl "line" (traceFrontierAttrs rows color (tracesWidth * xPercent xMax x / 100)) blank
      forM_ (trChannels rows) $ \ch ->
        traceLabel ("left: 0; top: " <> px (channelTop rows ch - 13)) (channelCaption ch (channelRange ch [ref, other]))
      when (vFrontiers v) $
        forM_ (zip [0 :: Int ..] cars) $ \(row, (e, _)) ->
          forM_ (zip ["S1", "S2"] (frontierPair (frontierXs axis ref e))) $ \(name, x) ->
            traceLabelColored (if row == 0 then "comparison__trace-label--other" else "comparison__trace-label--ref")
              ("left: calc(" <> formatFixed 3 (xPercent xMax x) <> "% + 2px); top: " <> px (if row == 0 then 10 else 0))
              name
      traceLabel ("left: 0; top: " <> px (tracesHeight rows - 13)) "0"
      traceLabel ("right: 0; top: " <> px (tracesHeight rows - 13)) (axisEndLabel axis xMax)
      overlay
    frontierRowAt tracesInset rm delta cells
  _ -> pure never
  where
    rows = TraceRows (traceChannels (vType v)) stretch
    frontierPair = maybe [] (\(a, b) -> [a, b])
    rowY ch (lo, hi) y = channelTop rows ch + channelHeight rows ch * (1 - (y - lo) / (hi - lo))
    px x = formatFixed 1 x <> "px"
    traceLabel style = traceLabelColored "" style
    traceLabelColored extra style t =
      elAttr "span" (Map.fromList [("class", T.strip ("comparison__trace-label " <> extra)), ("style", style)]) $
        text t

-- | El color de la referencia y el del otro en las trazas.
traceRefColor, traceOtherColor :: Text
traceRefColor   = "#e10600"
traceOtherColor = "#e7e9ee"

-- | El lienzo de las trazas con esos canales: @viewBox@ de 'Common.Traces' y ancho
-- fluido.
tracesAttrs :: TraceRows -> Map Text Text
tracesAttrs rows =
  Map.fromList
    [ ("class", "comparison__traces")
    , ("viewBox", "0 0 " <> num tracesWidth <> " " <> num (tracesHeight rows))
    , ("width", "100%")
    , ("height", num (tracesHeight rows))
    , ("preserveAspectRatio", "none")
    ]

-- | La curva de un coche en un canal.
tracePolylineAttrs :: Text -> Text -> Map Text Text
tracePolylineAttrs color pts =
  Map.fromList
    [ ("points", pts)
    , ("fill", "none")
    , ("stroke", color)
    , ("stroke-width", "1.3")
    , ("stroke-opacity", if color == traceRefColor then "1" else "0.85")
    , ("vector-effect", "non-scaling-stroke")
    ]

-- | Las líneas tenues del mínimo y el máximo de un canal.
traceGridAttrs :: Double -> Map Text Text
traceGridAttrs y =
  Map.fromList
    [ ("x1", "0"), ("x2", num tracesWidth), ("y1", formatFixed 1 y), ("y2", formatFixed 1 y)
    , ("stroke", "#888888"), ("stroke-opacity", "0.3"), ("vector-effect", "non-scaling-stroke")
    ]

-- | La raya discontinua de una frontera de un coche, de arriba abajo de los canales.
traceFrontierAttrs :: TraceRows -> Text -> Double -> Map Text Text
traceFrontierAttrs rows color x =
  Map.fromList
    [ ("x1", formatFixed 1 x), ("x2", formatFixed 1 x)
    , ("y1", formatFixed 1 (fst (channelsSpan rows)))
    , ("y2", formatFixed 1 (snd (channelsSpan rows)))
    , ("stroke", color), ("stroke-dasharray", "4 3"), ("stroke-opacity", "0.8")
    , ("vector-effect", "non-scaling-stroke")
    ]

-- | La fila de la gráfica: el lienzo con su fila de valores y, al lado del eje, su
-- columna.
plotRowAttrs :: Side -> Map Text Text
plotRowAttrs axis =
  Map.singleton "class" $
    "comparison__plotrow" <> if axis == SideLeft then " comparison__plotrow--axis-left" else ""

-- | Los números del eje en su columna, cada uno a la altura de su línea, el cero
-- incluido.
axisColumn :: DomBuilder t m => Side -> [Double] -> m ()
axisColumn axis series =
  elAttr "div" attrs $ mapM_ tick (axisTicks series)
  where
    attrs =
      Map.fromList
        [ ("class", "comparison__axis" <> if axis == SideLeft then " comparison__axis--left" else "")
        , ("style", "width: " <> formatFixed 1 axisColumnWidth <> "px")
        ]
    tick (_, y, label) =
      elAttr "span" (Map.fromList [("class", "comparison__tick"), ("style", topAt y)]) $
        text label

-- | Un número del eje dentro de la gráfica ('Common.ComparisonCard.insideAxisLabels').
insideTick :: DomBuilder t m => (Double, Double, Text) -> m ()
insideTick (x, y, label) =
  elAttr "span" attrs $ text label
  where
    attrs =
      Map.fromList
        [ ("class", "comparison__tick comparison__tick--inside")
        , ("style", "left: " <> formatFixed 1 x <> "px; " <> topAt y)
        ]

-- | La posición vertical de un número centrado en la Y de su línea.
topAt :: Double -> Text
topAt y = "top: " <> formatFixed 1 (y - valueHeight / 2) <> "px"

-- | El delta acumulado como @\<polyline\>@ sobre un @viewBox@ fijo, con la línea
-- del cero dibujada aparte y una línea tenue por cada número del eje salvo el cero.
-- Todo con el rango de 'Common.Chart.axisRange'. Las líneas van de borde a borde
-- en un lienzo; la curva, en otro encima que entra 'curveInset' por lado.
--
-- La línea del cero se pinta __siempre__, incluso sin serie: es la referencia que
-- da sentido al eje ("iban empatados"), no una decoración de los datos. Sin serie
-- —el comparado no tiene vuelta— no se emite @\<polyline\>@ ni se dice nada: lo
-- dice su cabecera, «sin vuelta» (2026-10-02).
deltaChart :: MonadWidget t m => [Double] -> m ()
deltaChart series = do
  svgEl "svg" chartAttrs $ do
    mapM_ (\y -> svgEl "line" (gridLineAttrs y) blank)
      [y | (v, y, _) <- axisTicks series, v /= 0]
    svgEl "line" (zeroLineAttrs series) blank
  unless (null series) $
    svgEl "svg" curveAttrs $ svgEl "polyline" (polylineAttrs series) blank

-- | Debajo del gráfico, el nombre y el valor de cada frontera —o solo uno de los
-- dos, según el modo que se ve—, cada uno centrado en la X de su punto
-- ('Common.Chart.frontierCells'). Van en HTML y no dentro del @\<svg\>@, que se
-- estira a lo ancho y deformaría el texto. La fila entra 'curveInset' por lado,
-- como la curva, para que el primero y el último no se salgan.
frontierRow :: MonadWidget t m => RowMode t -> [Double] -> m (Event t ())
frontierRow rm series =
  frontierRowAt (curveInset, curveInset) rm series (frontierCells series)

-- | 'frontierRow' con su margen a la izquierda y a la derecha, en px —el de las
-- trazas es 'Common.ComparisonCard.tracesInset'—, la Δ en las cuatro fronteras y las
-- celdas ya colocadas, porque en las trazas las fronteras no caen a espacio igual.
--
-- Con la banda puesta, en lugar de las celdas van los tramos de
-- 'Common.Chart.sectorSpans', con lo que pida el modo __elegido__: también el valor
-- cuando las dos líneas no caben, porque la banda va en una. La fila conserva el
-- alto del modo que se ve. Devuelve sus clics, que turnan fila y banda.
frontierRowAt
  :: MonadWidget t m
  => (Double, Double) -> RowMode t -> [Double] -> [(Double, Text, Text)] -> m (Event t ())
frontierRowAt _ _ _ [] = pure never
frontierRowAt margins rm series cells = do
  (row, _) <- elDynAttr' "div" (rowAttrs <$> rmBand rm) $ dyn_ (content <$> rmBand rm)
  pure (domEvent Click row)
  where
    shown = rmShown rm
    rowAttrs band =
      Map.fromList
        [ ("class", rowClass)
        , ("style", insetStyle margins)
        , ("title", rowTitle (rmChosen rm) band)
        ]
    rowClass
      | showsNames shown && showsValues shown = "comparison__frontiers"
      | otherwise = "comparison__frontiers comparison__frontiers--single"
    content False = mapM_ (frontierCell (showsNames shown) (showsValues shown)) cells
    content True  = mapM_ (sectorSpan (rmChosen rm)) (sectorSpans cells series)

-- | Un tramo de la banda: la raya entre sus dos fronteras y, en medio, lo que pida el
-- modo elegido, del color de cómo le fue al comparado en el sector. Si el texto no
-- cabe en el tramo, la hoja de estilos quita primero el nombre y después el valor.
sectorSpan :: DomBuilder t m => ChartMode -> SectorSpan -> m ()
sectorSpan chosen s =
  elAttr "div" attrs $
    elClass "span" ("comparison__band-label " <> labelClass) $ do
      elClass "span" "comparison__band-name" $ text (spName s)
      elClass "span" "comparison__band-sep" $ text ": "
      elClass "span" "comparison__band-value" $ text (spValue s)
  where
    attrs =
      Map.fromList
        [ ("class", "comparison__band-piece " <> paceClass (spPace s))
        , ("style", "left: " <> formatFixed 3 (spLeft s) <> "%; width: " <> formatFixed 3 (spWidth s) <> "%")
        ]
    labelClass
      | showsNames chosen && showsValues chosen = "comparison__band-label--both"
      | showsValues chosen                      = "comparison__band-label--values"
      | otherwise                               = "comparison__band-label--names"
    paceClass SectorFaster = "comparison__band-piece--faster"
    paceClass SectorEven   = "comparison__band-piece--even"
    paceClass SectorSlower = "comparison__band-piece--slower"

-- | El @style@ de un margen a la izquierda y otro a la derecha, en px.
insetStyle :: (Double, Double) -> Text
insetStyle (left, right) =
  "margin-left: " <> formatFixed 1 left <> "px; margin-right: " <> formatFixed 1 right <> "px"

-- | Una celda de 'frontierRow': qué líneas lleva, y la X, el nombre y el valor de su
-- frontera.
frontierCell :: DomBuilder t m => Bool -> Bool -> (Double, Text, Text) -> m ()
frontierCell names values (x, name, value) =
  elAttr "div" attrs $ do
    when names $ elClass "span" "comparison__frontier-name" $ text name
    when values $ elClass "span" "comparison__frontier-value" $ text value
  where
    attrs =
      Map.fromList
        [ ("class", "comparison__frontier")
        , ("style", "left: " <> formatFixed 3 x <> "%")
        ]

-- | Qué es cada línea: la discontinua (el cero) es la base, y la roja el otro coche
-- contra ella ('Common.Comparison.pairWith'). Por encima del cero, el otro va por
-- detrás, porque la serie es comparado − base.
--
-- Sin serie no hay línea roja que explicar, y queda solo la base; si va contra la
-- referencia y es ella la que no tiene vuelta no hay gráfica, y no se pinta nada.
legend :: DomBuilder t m => Baseline -> LapComparison -> m ()
legend b c = case pairWith b c of
  Just p | Nothing <- missingReference b c -> do
    elClass "span" "comparison__key comparison__key--ref" $ text "- - -"
    text (" " <> ceDriver (pairBase p) <> " (" <> baselineRole b <> ")")
    unless (null (pairDelta p)) $ do
      elClass "span" "comparison__key comparison__key--delta" $ text "——"
      text (" " <> ceDriver (pairOther p) <> ": por encima, va por detrás")
  _ -> blank

-- | La leyenda de las trazas: el color de cada coche, la referencia en rojo, y qué
-- resta la fila Δ (@«Δ = NOR − LEC»@, el otro menos la base). Sin la Δ, solo los
-- colores; con el aviso de la referencia sin vuelta, nada.
traceLegend :: DomBuilder t m => Baseline -> LapComparison -> m ()
traceLegend b c = case (lcEntries c, pairWith b c) of
  (ref : other : _, Just p) | Nothing <- missingReference b c -> do
    elClass "span" "comparison__key comparison__key--trace-ref" $ text "——"
    text (" " <> ceDriver ref <> " (referencia)")
    elClass "span" "comparison__key comparison__key--trace-other" $ text "——"
    text (" " <> ceDriver other)
    unless (null (pairDelta p)) $
      elClass "span" "comparison__formula" $ text ("Δ = " <> deltaFormula p)
  _ -> blank

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

-- | La curva, en su propio lienzo encima del de las líneas: entra 'curveInset' por
-- cada lado, con el mismo @viewBox@ y el mismo alto.
curveAttrs :: Map Text Text
curveAttrs =
  Map.fromList
    [ ("class", "comparison__curve")
    , ("viewBox", "0 0 " <> num chartWidth <> " " <> num chartHeight)
    , ("height", num chartHeight)
    , ("preserveAspectRatio", "none")
    , ( "style"
      , "left: " <> formatFixed 1 curveInset <> "px; width: calc(100% - "
          <> formatFixed 1 (2 * curveInset) <> "px)" )
    ]

-- | Línea tenue de un número del eje, de borde a borde del lienzo.
gridLineAttrs :: Double -> Map Text Text
gridLineAttrs y =
  Map.fromList
    [ ("class", "comparison__gridline")
    , ("x1", "0")
    , ("y1", num y)
    , ("x2", num chartWidth)
    , ("y2", num y)
    , ("stroke", "#888888")
    , ("stroke-opacity", "0.3")
    , ("stroke-width", "1")
    ]

-- | Línea de referencia del cero, discontinua para que no se confunda con la
-- serie. Su Y sale del mismo 'Common.Chart.axisRange' que los puntos.
zeroLineAttrs :: [Double] -> Map Text Text
zeroLineAttrs series =
  Map.fromList
    [ ("class", "comparison__zero")
    , ("x1", "0")
    , ("y1", y)
    , ("x2", num chartWidth)
    , ("y2", y)
    , ("stroke", "#888888")
    , ("stroke-width", "1")
    , ("stroke-dasharray", "4 4")
    ]
  where
    y = num (axisZeroY series)

-- | La serie. @fill=\"none\"@ es obligatorio: por defecto un @\<polyline\>@ se
-- rellena en negro y el gráfico sale como una mancha.
polylineAttrs :: [Double] -> Map Text Text
polylineAttrs series =
  Map.fromList
    [ ("class", "comparison__delta")
    , ("points", axisPolyline series)
    , ("fill", "none")
    , ("stroke", "#e10600")
    , ("stroke-width", "2")
    , ("stroke-linejoin", "round")
    ]

-- | Un número del lienzo como texto de atributo. Entero por el mismo motivo que
-- las coordenadas de 'Common.Chart.axisPolyline': 'show' sobre 'Double' emite
-- notación científica para los valores pequeños.
--
-- __@stroke@, @fill@ y compañía se quedan aquí a propósito__ y no pasaron a
-- @frontend\/dashboard.css@ cuando la hoja llegó el 2026-08-21: el CSS gana a
-- los atributos de presentación, así que sobrescribirlos allí dejaría este
-- Haddock diciendo una mentira. La hoja estila solo la caja del gráfico
-- (@comparison__chart@). Decidido el 2026-08-21 (c).
num :: Double -> Text
num = T.pack . show . (round :: Double -> Int)
