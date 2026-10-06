{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}

-- | Página Dashboard (un módulo por flujo, convención @Pages.\<Flujo\>@).
--
-- La pantalla no monta widgets hardcodeados: se **deriva de un 'Layout'**
-- ('Common.Types'). 'renderWidget' despacha por
-- 'widgetType' a los widgets existentes ('liveTimingWidget' \/ 'telemetryWidget') y
-- da un placeholder para los tipos aún no implementados. Dos botones conmutan entre
-- dos 'Layout' fijos ('raceOverview' \/ 'qualy') sosteniendo un @Dynamic t Layout@;
-- los dos se montan una vez, cada uno en su capa, y el inactivo se oculta
-- ('layer'). Único consumidor de
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
module Pages.Dashboard where

import           Common.Format      (ClockForm (..), formatClock)
import           Common.Layout      (slotStyle, touchesTopRight)
import           Common.Origin      (Sourced (..))
import           Common.Shown       (Kept (..), Poll (..), delayDefaultSeconds,
                                     delayFromUrl, keepLast, keptNothing,
                                     landed, readDelay)
import           Common.Types       (BandFlag (..), BandPiece, Countdown,
                                     Layout (..), LayoutId (..),
                                     LiveTable (..), SessionClock,
                                     SessionInfo (..), StateReading (..),
                                     TrackCondition, UpNext (..),
                                     WidgetConfig (..), WidgetId (..),
                                     WidgetType (..), bandMark, bandNote,
                                     bandPieces, bandRight, countdownAfter,
                                     countdownText, flagName, isDerived,
                                     noParams, pieceFlag, pieceSeparator,
                                     pieceWord, sessionTitle, shownClock,
                                     shownNext,
                                     tickClock, catchUp)
import           Control.Monad.IO.Class (liftIO)
import           Data.Maybe         (fromMaybe, isJust, listToMaybe)
import           Data.Text          (Text)
import qualified Data.Text          as T
import           Data.Time.Clock    (UTCTime (..), getCurrentTime)
import           Language.Javascript.JSaddle (eval, liftJSM, valToNumber)
import           Reflex.Dom
import           Widgets.Comparison (comparisonWidget)
import           Widgets.Historical (constructorStatsWidget, driverStatsWidget)
import           Widgets.LiveTiming (LiveView (..), delayedLive, livePoll,
                                     liveTimingWidget, sessionOf)
import           Widgets.Telemetry  (telemetryWidget)

-- | Pantalla del dashboard: la cabecera —título y conmutación de layouts—, la
-- __banda de sesión__ y el __lienzo__ con los dos layouts, cada widget en su
-- rectángulo; solo se ve el activo.
--
-- __Los tres son hermanos, y el lienzo no lleva encabezado dentro__: los widgets se
-- colocan desde la esquina de arriba de su contenedor, así que cualquier cosa en
-- flujo dentro de él la taparía el widget de @y = 0@. Cabecera y banda van delante
-- en el flujo, y el lienzo se lleva el resto de la ventana.
--
-- __Cabecera y banda van dentro de una misma barra pegajosa__ (@.top-bar@), y ése
-- es el único sitio del que no se escapan al deslizar: sueltas, la página desliza
-- lo que mide la cabecera y la banda se va debajo de ella, que es opaca.
--
-- __La cabecera se pliega y la banda no__: 'headerToggle' abre y cierra la primera
-- y arranca abierta. El botón se monta antes que ella porque el 'Event' que emite
-- es lo que alimenta su estado, y no por dónde salga en pantalla.
--
-- __El refresco del directo lo monta la página y no la tarjeta__ ('Widgets.LiveTiming.livePoll'):
-- los dos layouts están montados a la vez y los dos llevan Live Timing, así que una
-- petición por tarjeta saldría dos veces. Así comparten una sola.
dashboardPage :: MonadWidget t m => m ()
dashboardPage = divClass "page page--dashboard" $ do
  toggleClick <- headerToggle
  openDyn     <- toggle True toggleClick
  poll        <- livePoll
  initial     <- fromMaybe delayDefaultSeconds . delayFromUrl <$> getLocationUrl
  (layoutDyn, live) <- divClass "top-bar" $ do
    (active, delay) <- dashboardHeader initial openDyn
    live <- delayedLive delay poll
    sessionBand openDyn (lvPoll live) (lvAge live)
    pure (active, live)
  elDynClass "div" (canvasClass <$> openDyn) $
    mapM_ (layer live layoutDyn) [raceOverview, qualy]
  where
    -- __El lienzo dice si la cabecera está plegada__, para quien necesite saberlo
    -- desde la hoja de estilos. Hoy no lo lee nadie: lo leía la muesca de la
    -- esquina, y la banda se la quitó de encima al bajar las tarjetas fuera del
    -- alcance del botón. Se conserva con el resto de ese mecanismo.
    --
    -- __Va aquí y no en @.page--dashboard@__ para no atar un nudo: el botón que
    -- produce el 'Event' es hijo de la página, así que una clase dinámica en
    -- ella tendría que leer algo que se define dentro de ella misma. El lienzo
    -- se monta después del botón y del estado, y el valor ya está en la mano.
    canvasClass open
      | open      = "canvas"
      | otherwise = "canvas canvas--header-hidden"

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

-- | La cabecera: título, conmutación de layouts y el retraso del directo, que se
-- pliegan __juntos__ (2026-09-07). Devuelve el layout activo y el retraso en
-- segundos, porque los dos viven dentro; el retraso arranca en @initial@.
--
-- __Se pliega con una clase y no desmontando__, y la diferencia importa: con
-- 'dyn' el contenido se re-monta en cada cambio, así que 'layoutSwitcher'
-- perdería su @Dynamic t Layout@ y __volvería a 'raceOverview'__ cada vez que se
-- desplegara. Con 'elDynClass' el DOM se queda montado y solo cambia si se pinta.
dashboardHeader :: MonadWidget t m
                => Int -> Dynamic t Bool -> m (Dynamic t Layout, Dynamic t Int)
dashboardHeader initial openDyn =
  elDynClass "div" (headerClass <$> openDyn) $ do
    el "h1" $ text "F1 Functional Dashboard"
    divClass "dashboard-header__controls" $ do
      active <- layoutSwitcher
      delay  <- delayField initial
      pure (active, delay)
  where
    headerClass open
      | open      = "dashboard-header"
      | otherwise = "dashboard-header dashboard-header--hidden"

-- | El campo del retraso, en @m:ss@. Lo tecleado se aplica __al pulsar Enter o al
-- salir del campo__, nunca tecla a tecla: camino de @0:41@ se pasa por @0@, que
-- quitaría el retraso. Lo que no vale ('Common.Shown.readDelay') no cambia nada, y
-- al aplicarse el campo vuelve a escribir el retraso vigente.
delayField :: MonadWidget t m => Int -> m (Dynamic t Int)
delayField initial = elClass "label" "delay-field" $ mdo
  elClass "span" "delay-field__label" $ text "Diferido"
  input <- inputElement $
    def
      & inputElementConfig_initialValue .~ formatClock ClockCompact initial
      & inputElementConfig_setValue     .~ (formatClock ClockCompact <$> applied)
      & initialAttributes               .~ ("class" =: "delay-field__input" <> "size" =: "5")
  let committed = leftmost [() <$ ffilter (== 13) (domEvent Keypress input), domEvent Blur input]
      typed     = tag (current (_inputElement_value input)) committed
      applied   = attachWith (\old t -> fromMaybe old (readDelay t)) (current delay) typed
  delay <- holdDyn initial applied
  pure delay

-- | La banda que dice __de qué sesión__ habla la página, y no una tarjeta
-- (2026-09-15 (h)).
--
-- No se desmonta cuando no hay sesión: el lienzo descuenta su alto (2026-09-15 (j)),
-- y una banda que apareciera y desapareciera movería las tarjetas. Sin sesión se
-- queda vacía, que es lo que la hoja de estilos espera.
--
-- Recibe el pliegue porque con la cabecera plegada el botón le cae encima y tiene
-- que cederle sitio; quién lo hace y cuánto, lo dice la hoja.
--
-- Tiene dos aspectos, tarjeta y barra, con su mando; el 'mdo' es porque la clase del
-- contenedor depende de un 'Event' que nace dentro de él. El aspecto no sobrevive a
-- recargar (2026-09-15 (n)).
--
-- Enseña la última sesión que vino con nombre, no la de la última respuesta
-- ('Common.Shown.keepLast', 2026-09-22 (b)).
--
-- Un solo tic de un segundo mueve los dos relojes de la banda —la cuenta atrás y la
-- edad de lo conservado—, para que no se desincronicen.
sessionBand :: MonadWidget t m
            => Dynamic t Bool -> Dynamic t (Poll (Sourced LiveTable)) -> Dynamic t (Maybe Int)
            -> m ()
sessionBand openDyn poll lag = mdo
  tick    <- tickLossyFromPostBuildTime 1
  day     <- localTimeOfDay tick
  let arrived = sessionOf <$> ffilter (isJust . landed) (updated poll)
  kept    <- foldDyn keepLast keptNothing arrived
  age     <- sessionAge tick arrived
  title   <- holdUniqDyn (maybe "" sessionTitle . keptValue <$> kept)
  reading <- holdUniqDyn ((\k -> siState =<< keptValue k) <$> kept)
  track   <- holdUniqDyn ((\k -> siTrack =<< keptValue k) <$> kept)
  next    <- countdown tick lag (shownNext . fmap srcValue . pollShown <$> poll)
  restart <- ticked Nothing (fmap . countdownAfter) tick lag
               ((siCountdown =<<) . sessionOf <$> poll)
  clock   <- sessionClock tick ((shownClock =<<) . sessionOf <$> poll)
  let laps = (siLaps =<<) . sessionOf <$> poll
      restartText = (\d -> fmap (countdownText d)) <$> day <*> restart
  asCard  <- toggle True lookClick
  lookClick <- elDynClass "div" (bandClass <$> openDyn <*> asCard) $ do
    dynText title
    sessionState reading track restartText (keptStale <$> kept) age
    elClass "span" "session-band__next" $
      dynText (bandRight <$> day <*> next <*> laps <*> clock)
    lookSwitch asCard
  pure ()
  where
    bandClass open card =
      T.unwords $
        ["session-band", lookClass card]
          <> ["session-band--header-hidden" | not open]

    lookClass card
      | card      = "session-band--card"
      | otherwise = "session-band--bar"

    -- El botón nombra __a dónde lleva__ y no dónde estás: leído sobre una banda
    -- que ya se ve, «barra» a secas no dice si es lo que hay o lo que habrá.
    lookSwitch :: MonadWidget t m => Dynamic t Bool -> m (Event t ())
    lookSwitch card = do
      (e, _) <- elClass' "button" "switcher__btn session-band__look" $
                  dynText (lookLabel <$> card)
      pure (domEvent Click e)

    lookLabel card
      | card      = "Ver como barra"
      | otherwise = "Ver como tarjeta"

-- | En qué punto está la sesión y su pista ('bandPieces'), con la marca que la
-- califica y su aviso.
--
-- __Todo el DOM se monta una vez y solo cambian clases y texto__, sin 'dyn_'. Es
-- deliberado: el aviso guarda si está abierto, y re-montar lo cerraría cada vez que
-- cambiara el estado. De paso es lo único de Reflex que se puede escribir sin verlo
-- compilar y seguir estando seguro de lo que hace. Por eso las piezas van en __dos
-- huecos fijos__ —las que 'bandPieces' puede dar—, cada uno con su palabra y su
-- bandera, y lo que no toca se queda vacío o escondido.
--
-- __El botón es la etiqueta entera y no solo los asteriscos.__ Un carácter es un
-- blanco de un par de milímetros en un teléfono, que es justo donde el aviso solo
-- puede abrirse pulsando.
--
-- __Sin estado no hay palabra, pero el hueco se monta igual__: la banda tiene alto
-- fijo y el lienzo lo descuenta, así que lo que aparece y desaparece mueve las
-- tarjetas. Sobre una sesión conservada sin estado, los dos asteriscos salen solos
-- y son el ancla del aviso.
--
-- __Quién responde al dedo lo decide si hay aviso y no qué estado es__: con dos
-- marcas posibles, preguntar por una de ellas dejaría la otra inerte.
sessionState :: MonadWidget t m
             => Dynamic t (Maybe StateReading)
             -> Dynamic t (Maybe TrackCondition)
             -> Dynamic t (Maybe Text)
             -> Dynamic t Bool
             -> Dynamic t Int
             -> m ()
sessionState reading track restart stale age = do
  note <- holdUniqDyn (bandNote <$> ageWhenStale <*> (isDerived <$> reading))
  pieces <- holdUniqDyn (bandPieces <$> (fmap srState <$> reading) <*> track <*> restart)
  (markEl, _) <-
    elDynClass' "button" (stateClass <$> note) $ do
      piece (listToMaybe <$> pieces)
      dynText (pieceSeparator <$> pieces)
      piece (listToMaybe . drop 1 <$> pieces)
      dynText (bandMark <$> stale <*> reading)
  noteOpen <- toggle False (domEvent Click markEl)
  elDynClass "span" (noteClass <$> noteOpen <*> note) $ dynText note
  where
    -- Un hueco: la bandera, escondida si no la hay, y la palabra, vacía si no la hay.
    piece :: MonadWidget t m => Dynamic t (Maybe BandPiece) -> m ()
    piece p = do
      elDynAttr "span" (flagAttrs . pieceFlag <$> p) blank
      dynText (pieceWord <$> p)

    flagAttrs Nothing  = "class" =: "session-band__flag session-band__flag--none"
    flagAttrs (Just f) =
      "class" =: ("session-band__flag session-band__flag--" <> flagClass f)
        <> "title" =: flagName f

    flagClass YellowFlag    = "yellow"
    flagClass RedFlag       = "red"
    flagClass ChequeredFlag = "chequered"

    -- La edad solo se dice de lo conservado: sobre lo que acaba de llegar sería
    -- cierta y no significaría nada.
    ageWhenStale = (\s n -> if s then Just n else Nothing) <$> stale <*> age

    stateClass n = T.unwords $
      ["session-band__state"] <> ["session-band__state--noted" | hasNote n]

    noteClass open n = T.unwords $
      ["session-band__note"] <> ["session-band__note--open" | open && hasNote n]

    hasNote = not . T.null

-- | Cuántos segundos hace que llegó una respuesta que nombraba su sesión.
--
-- __Es la edad del nombre que se está leyendo, no la del corte__: se pone a cero
-- con cada llegada que trae sesión, así que en régimen normal oscila entre cero y
-- el periodo de la página, y durante un hueco sigue subiendo desde ahí.
--
-- __Una llegada gana al tic si caen en el mismo frame__, por el mismo criterio que
-- 'countdown': lo que acaba de llegar manda sobre lo que el navegador contó.
sessionAge :: MonadWidget t m
           => Event t TickInfo -> Event t (Maybe SessionInfo) -> m (Dynamic t Int)
sessionAge tick arrived =
  foldDyn ($) 0 $
    leftmost [const 0 <$ ffilter isJust arrived, (+ 1) <$ tick]

-- | La cuenta atrás de la derecha de la banda, descontada en el navegador ('ticked').
--
-- __Arranca en 'NextUnknown'__ porque antes de la primera respuesta eso es lo cierto,
-- y es además lo que la banda pinta como «todavía no se sabe».
countdown :: MonadWidget t m
          => Event t TickInfo -> Dynamic t (Maybe Int) -> Dynamic t UpNext
          -> m (Dynamic t UpNext)
countdown = ticked NextUnknown catchUp

-- | Una cuenta que llega en la respuesta, descontada en el navegador: @after k@ es la
-- misma cuenta @k@ segundos después.
--
-- __Un tic de un segundo sobre un refresco de diez__, que son los dos relojes de
-- esta página y no se estorban: cada respuesta reinicia la cuenta al valor que el
-- backend resolvió, y entre respuestas baja sola. Sin esto el número saltaría de
-- diez en diez y «la cuenta atrás cuenta» dejaría de poder comprobarse mirando.
--
-- __El 'holdUniqDyn' no es una optimización, es lo que impide que el número suba.__
-- El estado del refresco cambia dos veces por ciclo —al pedir y al llegar— y solo la
-- segunda trae valor nuevo; sin filtrar, el «al pedir» reiniciaría la cuenta al valor
-- de la respuesta anterior y el número saltaría diez segundos hacia atrás cada diez
-- segundos.
--
-- __Una respuesta gana al tic si caen en el mismo frame__ ('leftmost' con el valor
-- servido delante): lo que el backend resolvió manda sobre lo que el navegador
-- descontó.
--
-- __Cada valor servido entra a la hora del calendario__: se le descuenta la edad de
-- lo enseñado (@after@), leída en el mismo frame ('attachPromptlyDynWith'), porque
-- con @current@ sería la del valor anterior.
--
-- __El tic entra por argumento y no se crea aquí__: es el mismo que cuenta la edad
-- de lo conservado, y dos relojes de un segundo se separarían con el tiempo.
ticked :: (MonadWidget t m, Eq a)
       => a -> (Int -> a -> a)
       -> Event t TickInfo -> Dynamic t (Maybe Int) -> Dynamic t a
       -> m (Dynamic t a)
ticked initial after tick lag served = do
  fresh <- holdUniqDyn served
  foldDyn ($) initial $
    leftmost [ attachPromptlyDynWith (\a v -> const (after (fromMaybe 0 a) v)) lag (updated fresh)
             , after 1 <$ tick
             ]

-- | Los segundos del día en la hora local del navegador, al ritmo del tic: con lo
-- que 'Common.Types.countdownText' pone la hora del final de una cuenta.
--
-- __La zona se lee una vez, al montar__, del propio navegador: el @time@ del backend
-- JavaScript de GHC no la sabe leer.
localTimeOfDay :: MonadWidget t m => Event t TickInfo -> m (Dynamic t Int)
localTimeOfDay tick = do
  offset <- liftJSM (eval ("new Date().getTimezoneOffset()" :: Text) >>= valToNumber)
  start  <- liftIO getCurrentTime
  now    <- holdDyn start (_tickInfo_lastUTC <$> tick)
  let behind = round (offset * 60) :: Int
  pure ((\t -> (floor (utctDayTime t) - behind) `mod` 86400) <$> now)

-- | El reloj de la sesión que llega en la respuesta, descontado en el navegador con
-- el mismo reparto que 'countdown': cada valor servido nuevo manda, y entre uno y
-- otro baja con el tic si el feed dice que corre ('Common.Types.tickClock').
sessionClock :: MonadWidget t m
             => Event t TickInfo -> Dynamic t (Maybe SessionClock)
             -> m (Dynamic t (Maybe SessionClock))
sessionClock tick served = do
  fresh <- holdUniqDyn served
  foldDyn ($) Nothing $
    leftmost [const <$> updated fresh, fmap tickClock <$ tick]

-- | La capa de un layout: sus widgets, del tamaño del lienzo. Se monta una vez y se
-- oculta mientras su layout no es el activo, así que cambiar de layout no
-- reconstruye nada y cada layout conserva lo suyo, scroll incluido
-- (2026-09-29 (j)). Pulsar el layout activo no cambia nada.
--
-- Al volver a enseñarse avisa a sus widgets; lo usa Lap Comparison, que mide su
-- ancho y oculta mide 0.
layer :: MonadWidget t m => LiveView t -> Dynamic t Layout -> Layout -> m ()
layer live layoutDyn l = do
  active <- holdUniqDyn (((== layoutId l) . layoutId) <$> layoutDyn)
  let revealed = () <$ ffilter id (updated active)
  elDynClass "div" (layerClass <$> active) $
    mapM_ (slot live revealed) (widgets l)
  where
    layerClass a
      | a         = "canvas__layer"
      | otherwise = "canvas__layer canvas__layer--hidden"

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
--
-- __El modificador de la esquina lo pone el slot y no el widget__, por la misma
-- razón: quien sabe dónde está la tarjeta es quien la coloca. Marca a la tarjeta
-- que ocupa la esquina donde vive el botón de plegar, que es @fixed@ contra la
-- ventana (2026-09-07 b); a quién le toca lo dice 'touchesTopRight'.
slot :: MonadWidget t m => LiveView t -> Event t () -> WidgetConfig -> m ()
slot live revealed wc =
  elAttr "div" ("class" =: slotClass wc <> "style" =: slotStyle wc) $
    renderWidget live revealed wc

-- | Clase del slot: el bloque, y el modificador solo cuando hay algo que
-- modificar — mismo criterio que el @rowClass@ de 'Widgets.LiveTiming'
-- (2026-08-27). De los seis slots de los layouts fijos lo llevan dos.
--
-- __El modificador no pinta nada hoy:__ la hoja dejó de dibujar la muesca cuando
-- la banda de sesión bajó las tarjetas fuera del alcance del botón. Se emite igual,
-- porque la esquina vuelve a estar en disputa en cuanto la banda pueda anclarse
-- abajo.
slotClass :: WidgetConfig -> T.Text
slotClass wc
  | touchesTopRight wc = "widget-slot widget-slot--top-right"
  | otherwise          = "widget-slot"

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
--
-- __El refresco del directo y el aviso de que la capa se enseña atraviesan las
-- siete ramas y cada uno lo usa una__, por la misma razón por la que el
-- rectángulo no lo lleva el widget: quien conoce el dato es quien monta, y darlo
-- solo a la rama que lo pide exigiría que el @case@ devolviera funciones de tipos
-- distintos.
renderWidget :: MonadWidget t m => LiveView t -> Event t () -> WidgetConfig -> m ()
renderWidget live revealed wc = case widgetType wc of
  LiveTiming       -> liveTimingWidget live
  Telemetry        -> telemetryWidget
  LapComparison    -> comparisonWidget revealed
  TyreStrategy     -> placeholderWidget "Tyre Strategy"
  HistoricalStats  -> driverStatsWidget
  ConstructorStats -> constructorStatsWidget
  Custom           -> placeholderWidget "Custom"

-- | Widget aún no disponible: recuadro con etiqueta del tipo.
placeholderWidget :: DomBuilder t m => T.Text -> m ()
placeholderWidget name = divClass "widget widget--placeholder" $ do
  divClass "widget__head" $ el "h2" $ text name
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

-- | Layout "Race Overview": live timing, telemetría, comparación de vueltas y las
-- dos clasificaciones históricas, cada una en su sitio.
--
-- La colocación, en unidades de 120 (2026-09-03 y 2026-09-04):
--
-- > 0            60           120
-- > ┌────────────┬────────────┐  0
-- > │            │  telemetry │
-- > │            ├────────────┤ 35
-- > │ live-timing│            │
-- > │            │ lap-compar │
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
-- Un typo en los ids no lo caza el compilador, y por eso los seis rectángulos de
-- este módulo los ejercita @backend-test@ contra "Common.Layout".
raceOverview :: Layout
raceOverview = Layout
  { layoutId = LayoutId "race-overview"
  , widgets  =
      [ cfg (WidgetId "live-timing")       LiveTiming       (  0,  0, 60, 90)
      , cfg (WidgetId "telemetry")         Telemetry        ( 60,  0, 60, 35)
      , cfg (WidgetId "lap-comparison")    LapComparison    ( 60, 35, 60, 50)
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
