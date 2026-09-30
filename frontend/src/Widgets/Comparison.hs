{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}

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
-- 'Common.Types.LapComparison' trae desde el 2026-08-05 los números junto a los
-- acrónimos —de qué coches habla lo que se está pintando— y @\/api\/drivers@
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
import           Common.Chart  (axisPolyline, axisTicks, axisZeroY, chartHeight,
                                chartWidth, frontierCells)
import           Common.ComparisonCard (CardLayout (..), ChartMode, Side (..),
                                        axisColumnWidth, cardLayout, curveInset,
                                        defaultControlSide, defaultMode,
                                        insideAxisLabels, modeEnabled,
                                        modeFromKey, modeKey, modeOption,
                                        modesInOrder, otherSide, rowHeight,
                                        shownMode, showsNames, showsValues,
                                        valueHeight, valuesFitMeasured,
                                        vsBeside)
import           Common.Format (formatFixed)
import           Common.Route  (comparisonPath, comparisonPathFor, driversParam,
                                driversPathFor)
import           Common.Types  (DriverEntry (..), LapComparison (..))
import           Control.Monad (forM_, unless, when)
import           Data.List     (find)
import           Data.Map      (Map)
import qualified Data.Map      as Map
import           Data.Maybe    (fromMaybe)
import           Data.Text     (Text)
import qualified Data.Text     as T
import qualified GHCJS.DOM     as DOM (currentWindowUnchecked)
import qualified GHCJS.DOM.Element as DOM (getClientHeight)
import qualified GHCJS.DOM.EventM as DOM (on)
import qualified GHCJS.DOM.GlobalEventHandlers as DOM (resize)
import qualified GHCJS.DOM.HTMLElement as DOM (getOffsetHeight, getOffsetWidth)
import qualified GHCJS.DOM.Types as DOM (Element (..), HTMLElement (..),
                                         liftJSM, uncheckedCastTo)
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
  (root, (card, (userMode, state))) <-
    elClass' "div" "widget widget--comparison" $ elClass' "div" "comparison__card" $ mdo
      swap <- divClass "widget__head" $ do
        el "h2" $ text "Lap Comparison"
        swapButton (clStacked <$> layout)
      side    <- foldDyn (const otherSide) defaultControlSide swap
      pb      <- getPostBuild
      gridRsp <- fetchJson (driversPathFor Nothing <$ pb)
      grid    <- holdDyn [] (fromMaybe [] <$> gridRsp)
      (picked, chosenE) <- elDynAttr "div" (bodyAttrs <$> side <*> layout) $ do
        r <- elDynAttr "div" (controlAttrs <$> layout) $ do
          r' <- carSelector grid (shownComparison <$> st) (vsNextTo <$> layout)
                  (modeSelect fits shown)
          dyn_ (controlState <$> st)
          pure r'
        divClass "comparison__plot" $
          dyn_ ( plotView (dyn_ (banner <$> zipDyn refresh st))
                   <$> shown <*> layout <*> (otherSide <$> side) <*> st )
        pure r
      dyn_ (legendState <$> st)
      resp    <- fetchJson (leftmost [comparisonPath <$ pb, picked])
      refresh <- holdDyn InFlight (leftmost [InFlight <$ picked, refreshOf <$> resp])
      st      <- foldDyn step Loading resp
      pure (chosenE, st)
  size    <- cardSize root card (current rowNow) changed
  stacked <- holdUniqDyn (clStacked <$> layout)
  chosen  <- holdDyn defaultMode userMode
  shown   <- holdUniqDyn (shownMode <$> fits <*> chosen)
  let layout   = cardLayout . maybe 0 fst <$> size
      fits     = maybe True snd <$> size
      rowNow   = rowHeightNow <$> shown <*> state
      changed  = leftmost
                   [() <$ updated shown, () <$ updated state, () <$ updated stacked, revealed]
  pure ()
  where
    controlState :: MonadWidget t m => CState -> m ()
    controlState (Loaded c) = lapHeader c
    controlState _          = blank

    legendState :: MonadWidget t m => CState -> m ()
    legendState (Loaded c) = legend c
    legendState _          = blank

-- | El alto de la fila de fronteras pintada: el de su modo si hay fronteras que
-- nombrar, 0 si no hay fila.
rowHeightNow :: ChartMode -> CState -> Double
rowHeightNow m (Loaded c) | not (null (frontierCells (lcDelta c))) = rowHeight m
rowHeightNow _ _          = 0

-- | Lo que se mide de la tarjeta: su ancho por dentro, en px, y si caben las dos
-- líneas de la fila de fronteras sin que pida scroll
-- ('Common.ComparisonCard.valuesFitMeasured', con el alto de la fila pintada que da
-- el 'Behavior').
--
-- Se mide al montarse, cada vez que cambia la ventana y un instante después de cada
-- evento del último argumento (cambios del contenido, o que se acaba de enseñar).
-- Mientras la tarjeta aún no está en la página, o está oculta, mide 0, y se vuelve a
-- medir cada 0,2 s hasta 'measureTries' veces. 'Nothing' hasta la primera medida con ancho; no cambia si la medida se
-- repite.
--
-- No mide los cambios de tamaño de la tarjeta que no vienen de la ventana.
cardSize
  :: MonadWidget t m
  => Element EventResult GhcjsDomSpace t
  -> Element EventResult GhcjsDomSpace t
  -> Behavior t Double
  -> Event t ()
  -> m (Dynamic t (Maybe (Double, Bool)))
cardSize root card rowNow changed = mdo
  mounted  <- delay 0 =<< getPostBuild
  win      <- DOM.liftJSM DOM.currentWindowUnchecked
  resized  <- wrapDomEvent win (`DOM.on` DOM.resize) (pure ())
  settled  <- delay 0 changed
  measured <- performEvent (measure <$> tag rowNow (leftmost [mounted, resized, settled, retry]))
  let zero = ffilter ((<= 0) . fst) measured
  tries    <- count zero
  retry    <- delay 0.2 (() <$ ffilter (< measureTries) (tag (current tries) zero))
  holdUniqDyn =<< holdDyn Nothing (Just <$> ffilter ((> 0) . fst) measured)
  where
    cardEl = DOM.uncheckedCastTo DOM.HTMLElement (_element_raw card)
    measure row = DOM.liftJSM $ do
      w       <- DOM.getOffsetWidth cardEl
      content <- DOM.getOffsetHeight cardEl
      client  <- DOM.getClientHeight (_element_raw root)
      pure (w, valuesFitMeasured client content row)

-- | Cuántas veces se vuelve a medir una tarjeta que mide 0 (10 s en total).
measureTries :: Int
measureTries = 50

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

-- | Los dos selectores de coche y el botón, y la URL que sale de pulsarlo.
--
-- __Dos controles separados y no uno solo con @\"1,16\"@:__ así la cardinalidad
-- es estructural. El microservicio responde 400 a cualquier cantidad que no sea
-- dos, y ese 400 lo absorbe el @try@ del backend y vuelve como 200 con el dummy
-- (2026-08-01), así que impedir mandar uno o tres tiene que
-- ser cosa del widget y no del degradado. Es lo único que sobrevive intacto del
-- par de @\<input\>@ que había aquí hasta el 2026-08-07.
--
-- __Las posiciones iniciales, 0 y 1, no son la selección de verdad:__ son lo que
-- se ve durante el instante que va del arranque a la primera respuesta. El par
-- que el gráfico pinta lo marca el prefill, y tiene que ser así porque
-- @Handler.Comparison.Helper.defaultDrivers@ son los coches @1@ y @16@ y sus
-- posiciones dependen de la parrilla: en el dummy son la 0 y la 1 —está ordenado
-- justamente así— y en la parrilla real son la 0 y la __3__.
--
-- El tercer argumento dice si el «VS» va a la derecha del primer desplegable
-- ('vsNextTo'). El último se pinta junto a «Comparar», en la misma fila, y su
-- resultado se devuelve con la URL.
carSelector
  :: MonadWidget t m
  => Dynamic t [DriverEntry]
  -> Dynamic t (Maybe LapComparison)
  -> Dynamic t Bool
  -> m a
  -> m (Event t Text, a)
carSelector grid shown vsNext beside = divClass "car-selector" $ do
  let indexed = indexedGrid <$> grid
      labels  = Map.map driverLabel <$> indexed
      -- El prefill de un lado: la posición que ocupa hoy el coche del que habla
      -- el gráfico. 'updated' sobre las __dos__ fuentes y no un 'Event' de la
      -- respuesta, porque parrilla y comparación son dos peticiones y llegan en
      -- cualquier orden: con solo la respuesta, la que se adelante a la parrilla
      -- buscaría el coche en una lista vacía y el prefill se perdería para
      -- siempre.
      setPos car = fmapMaybe id (updated (zipDynWith (positionFor car) indexed shown))
  (posB, posA) <- elDynAttr "div" (pairAttrs <$> vsNext) $ do
    b <- carDropdown 1 labels (setPos lcCarB)
    elClass "span" "car-selector__vs" $ text "vs"
    a' <- carDropdown 0 labels (setPos lcCarA)
    pure (b, a')
  (click, a) <- divClass "comparison__actions" $ (,) <$> compareButton <*> beside
  let picked = zipDyn (zipDynWith carAt indexed posA)
                      (zipDynWith carAt indexed posB)
  pure (fmapMaybe urlFor (tagPromptlyDyn picked click), a)
  where
    -- 'fmapMaybe' es lo que hace que una selección incompleta __no dispare
    -- nada__, en vez de disparar y confiar en el degradado. Y el 'Just' interior
    -- no es ruido: 'comparisonPathFor' ya acepta 'Maybe', así que pasarle un
    -- 'Nothing' daría el path __sin__ query — la comparación por defecto
    -- presentada como la que se pidió.
    --
    -- Los dos 'Nothing' que hay que absorber son el mismo: parrilla vacía. Pasa
    -- entre el arranque y la respuesta de @\/api\/drivers@, y ahí un clic no
    -- puede significar nada.
    urlFor :: (Maybe Text, Maybe Text) -> Maybe Text
    urlFor (mcarA, mcarB) = do
      carA <- mcarA
      carB <- mcarB
      comparisonPathFor Nothing . Just <$> driversParam carA carB

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
-- es el dummy (@1@ vs @16@) y la parrilla puede ser la real de otra sesión
-- cacheada. Que el selector se quede donde estaba y el @#n@ de 'lapLabel'
-- discrepe es justo la señal de que lo pintado no es lo pedido.
positionFor
  :: (LapComparison -> Text)
  -> Map Int DriverEntry
  -> Maybe LapComparison
  -> Maybe Int
positionFor car indexed = (positionOf indexed . car =<<)

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
  -> m (Dynamic t Int)
carDropdown initial options setPos =
  fmap _dropdown_value . dropdown initial options $
    def
      &  dropdownConfig_attributes .~ constDyn carSelectAttrs
      &  dropdownConfig_setValue   .~ setPos

-- | Atributos de un selector de coche. Como en el resto del módulo, no hay hoja
-- de estilos: la clase es el gancho para cuando la haya.
carSelectAttrs :: Map Text Text
carSelectAttrs = Map.fromList [("class", "car-selector__select")]

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

-- | Los dos pilotos con su tiempo de vuelta, tal cual llegan. @lcLapA@\/@lcLapB@
-- son 'Text' ya formateado (@M:SS.mmm@) por el microservicio: intentar
-- reformatearlos aquí sería reintroducir en el widget un trabajo que el servicio
-- ya hizo.
lapHeader :: DomBuilder t m => LapComparison -> m ()
lapHeader c = divClass "comparison__header" $ do
  lapLabel (lcDriverB c) (lcCarB c) (lcLapB c)
  elClass "span" "comparison__vs" $ text "vs"
  lapLabel (lcDriverA c) (lcCarA c) (lcLapA c)

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
  elClass "span" "comparison__who" $ do
    elClass "span" "comparison__driver" $ text driver
    if T.null car
      then blank
      else elClass "span" "comparison__car" $ text ("#" <> car)
  elClass "span" "comparison__time" $ text lap

-- | La gráfica según el reparto, el lado del eje y el modo que se ve: la curva, el
-- eje vertical (en su columna o dentro, según 'clAxisInside') y la fila de
-- fronteras con las líneas que pida el modo. El primer argumento se pinta encima
-- de la curva, dentro de su lienzo: el aviso de la petición.
plotView :: MonadWidget t m => m () -> ChartMode -> CardLayout -> Side -> CState -> m ()
plotView _ _ _ _ Loading =
  elClass "p" "status status--loading" $ text "Cargando…"
plotView _ _ _ _ Failed =
  elClass "p" "status status--error" $ text "Error al cargar /api/comparison"
plotView overlay m l axis (Loaded c) =
  elAttr "div" (plotRowAttrs axis) $ do
    divClass "comparison__plotarea" $ do
      divClass "comparison__canvas" $ do
        deltaChart series
        when (clAxisInside l) $
          mapM_ insideTick (insideAxisLabels axis (clChart l) series)
        overlay
      frontierRow (showsNames m) (showsValues m) series
    unless (clAxisInside l) $ axisColumn axis series
  where
    series = lcDelta c

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
-- da sentido al eje ("iban empatados"), no una decoración de los datos. Con
-- @lcDelta@ vacío no se emite @\<polyline\>@ y se dice por qué; no debería
-- ocurrir —el @Context@ del backend degrada a dummy cuando lo está
-- (2026-08-03)— pero el widget no puede darlo por hecho.
deltaChart :: MonadWidget t m => [Double] -> m ()
deltaChart series = do
  svgEl "svg" chartAttrs $ do
    mapM_ (\y -> svgEl "line" (gridLineAttrs y) blank)
      [y | (v, y, _) <- axisTicks series, v /= 0]
    svgEl "line" (zeroLineAttrs series) blank
  case series of
    [] -> elClass "p" "status status--empty" $ text "Sin delta que dibujar"
    _  -> svgEl "svg" curveAttrs $ svgEl "polyline" (polylineAttrs series) blank

-- | Debajo del gráfico, el nombre y el valor de cada frontera —o solo uno de los
-- dos, según los dos primeros argumentos—, cada uno centrado en la X de su punto
-- ('Common.Chart.frontierCells'). Van en HTML y no dentro del @\<svg\>@, que se
-- estira a lo ancho y deformaría el texto. La fila entra 'curveInset' por lado,
-- como la curva, para que el primero y el último no se salgan.
frontierRow :: DomBuilder t m => Bool -> Bool -> [Double] -> m ()
frontierRow names values series = case frontierCells series of
  []    -> blank
  cells -> elAttr "div" rowAttrs $ mapM_ (frontierCell names values) cells
  where
    rowAttrs =
      Map.fromList
        [ ("class", rowClass)
        , ("style", "margin-left: " <> inset <> "; margin-right: " <> inset)
        ]
    inset = formatFixed 1 curveInset <> "px"
    rowClass
      | names && values = "comparison__frontiers"
      | otherwise       = "comparison__frontiers comparison__frontiers--single"

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

-- | Qué es cada línea: la discontinua es el coche de la derecha, la referencia, y
-- la roja el de la izquierda contra él. Por encima del cero, el de la izquierda va
-- por detrás, porque la serie es A − B.
--
-- Sin serie no hay línea roja que explicar, y no se pinta.
legend :: DomBuilder t m => LapComparison -> m ()
legend c
  | null (lcDelta c) = blank
  | otherwise = divClass "comparison__legend" $ do
      elClass "span" "comparison__key comparison__key--ref" $ text "- - -"
      text (" " <> lcDriverB c <> " (referencia)")
      elClass "span" "comparison__key comparison__key--delta" $ text "——"
      text (" " <> lcDriverA c <> ": por encima, va por detrás")

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
