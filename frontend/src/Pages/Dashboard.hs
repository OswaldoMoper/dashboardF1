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

import           Common.Carry       (Board (..), Grip (..), Hand (..), Held (..),
                                     Scene (..), boardOf, heldStyle, scene,
                                     stepBoard)
import           Common.ComparisonCard (Side, defaultControlSide)
import           Common.Format      (ClockForm (..), formatClock)
import           Common.Layout      (slotStyle, touchesTopRight)
import           Common.Origin      (Sourced (..))
import           Common.Saved       (Restored (..), atFactory, factorySides,
                                     restoreLayout, saveLayout, savedKey,
                                     unfitNote)
import           Common.Shown      (Kept (..), Poll (..), delayDefaultSeconds,
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
import           Control.Exception  (SomeException, try)
import           Control.Monad.IO.Class (liftIO)
import           Data.IORef         (IORef, newIORef, readIORef, writeIORef)
import           Data.List          (find)
import           Data.Map           (Map)
import qualified Data.Map           as Map
import           Data.Maybe         (fromMaybe, isJust, isNothing, listToMaybe)
import           Data.Text          (Text)
import qualified Data.Text          as T
import           Data.Time.Clock    (UTCTime (..), getCurrentTime)
import qualified GHCJS.DOM          as DOM (currentWindowUnchecked)
import qualified GHCJS.DOM.DOMRectReadOnly as DOM (getHeight, getWidth)
import qualified GHCJS.DOM.Element as DOM (closest, getBoundingClientRect)
import qualified GHCJS.DOM.EventM   as DOM (event, mouseClientXY, on,
                                            preventDefault, target)
import qualified GHCJS.DOM.GlobalEventHandlers as DOM (click, keyDown, keyUp,
                                                       mouseDown, mouseMove,
                                                       mouseUp)
import qualified GHCJS.DOM.KeyboardEvent as Key (getKey)
import qualified GHCJS.DOM.MouseEvent as Mouse (getAltKey, getButton)
import qualified GHCJS.DOM.Storage  as Storage (getItem, setItem)
import qualified GHCJS.DOM.Types    as DOM (Element (..), HTMLElement (..),
                                            MouseEvent (..),
                                            uncheckedCastTo)
import qualified GHCJS.DOM.Window   as Window (getLocalStorage)
import           Language.Javascript.JSaddle (JSM, eval, liftJSM, valToNumber)
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
--
-- __Es 'mdo' porque la cabecera lee de las capas__: «Restablecer» necesita saber si la
-- capa que se ve ya es la de fábrica, y las capas se montan después de la cabecera.
dashboardPage :: MonadWidget t m => m ()
dashboardPage = divClass "page page--dashboard" $ mdo
  toggleClick <- headerToggle
  openDyn     <- toggle True toggleClick
  poll        <- livePoll
  initial     <- fromMaybe delayDefaultSeconds . delayFromUrl <$> getLocationUrl
  restored    <- mapM (\l -> (,) l <$> liftJSM (readSaved l)) [raceOverview, qualy]
  let unfit l = lookup l restored == Just Unfit
  (layoutDyn, live, edit) <- divClass "top-bar" $ do
    (active, delay, editing) <- dashboardHeader initial openDyn unfit shownAtFactory
    delayed <- delayedLive delay poll
    sessionBand openDyn (lvPoll delayed) (lvAge delayed)
    pure (active, delayed, editing)
  factories <- elDynClass "div" (canvasClass <$> openDyn <*> editOn edit) $
    mapM (\(l, r) -> (,) (layoutId l) <$> layer live layoutDyn edit l r) restored
  let shownAtFactory =
        (\l fs -> fromMaybe True (lookup (layoutId l) fs))
          <$> layoutDyn <*> traverse (\(i, d) -> (,) i <$> d) factories
  pure ()
  where
    -- __El lienzo dice si la cabecera está plegada y si se está editando__, para
    -- quien necesite saberlo desde la hoja de estilos. Lo plegado hoy no lo lee
    -- nadie: lo leía la muesca de la esquina, y la banda se la quitó de encima al
    -- bajar las tarjetas fuera del alcance del botón. Se conserva con el resto de
    -- ese mecanismo. Lo editado lo leen los bordes, la ⠿ del título y «⇄».
    --
    -- __Va aquí y no en @.page--dashboard@__ para no atar un nudo: el botón que
    -- produce el 'Event' es hijo de la página, así que una clase dinámica en
    -- ella tendría que leer algo que se define dentro de ella misma. El lienzo
    -- se monta después del botón y del estado, y el valor ya está en la mano.
    canvasClass open editing =
      T.unwords $
        ["canvas"]
          <> ["canvas--header-hidden" | not open]
          <> ["canvas--editing" | editing]

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

-- | La cabecera: título, conmutación de layouts, el modo edición y el retraso del
-- directo, que se pliegan __juntos__ (2026-09-07). Devuelve el layout activo, el
-- retraso en segundos y si se está editando, porque los tres viven dentro; el
-- retraso arranca en @initial@. @atFactoryNow@ dice si el layout que se ve ya es el
-- de fábrica, para que «Restablecer» no pregunte en balde.
--
-- __Se pliega con una clase y no desmontando__, y la diferencia importa: con
-- 'dyn' el contenido se re-monta en cada cambio, así que 'layoutSwitcher'
-- perdería su @Dynamic t Layout@ y __volvería a 'raceOverview'__ cada vez que se
-- desplegara. Con 'elDynClass' el DOM se queda montado y solo cambia si se pinta;
-- por lo mismo, plegarla no saca de la edición.
dashboardHeader :: MonadWidget t m
                => Int -> Dynamic t Bool -> (Layout -> Bool) -> Dynamic t Bool
                -> m (Dynamic t Layout, Dynamic t Int, Edit t)
dashboardHeader initial openDyn unfit atFactoryNow =
  elDynClass "div" (headerClass <$> openDyn) $ do
    el "h1" $ text "F1 Functional Dashboard"
    divClass "dashboard-header__controls" $ do
      (active, edit) <- layoutSwitcher unfit atFactoryNow
      delay <- delayField initial
      pure (active, delay, edit)
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
--
-- __Cada capa lleva su layout y su arrastre__ ('Common.Carry'): en edición, una
-- tarjeta se coge por el título y lo que se pinta lo dice 'scene'. Mover no vuelve a
-- montar nada: solo cambian el estilo y la clase de los slots.
--
-- Arranca de lo guardado si encaja ('Common.Saved.restoreLayout') y si no, del de
-- fábrica, con los rectángulos y el lado de cada Lap Comparison. Al salir de la
-- edición guarda lo que se ve, esté activa o no; «Restablecer» devuelve al de fábrica
-- solo la activa, lados incluidos, y se guarda al salir como lo demás. Devuelve si lo
-- que enseña es el de fábrica ('Common.Saved.atFactory').
layer :: MonadWidget t m
      => LiveView t -> Dynamic t Layout -> Edit t -> Layout -> Restored -> m (Dynamic t Bool)
layer live layoutDyn edit l restored = mdo
  active <- holdUniqDyn (((== layoutId l) . layoutId) <$> layoutDyn)
  let revealed = () <$ ffilter id (updated active)
      held     = isJust . boardCarry <$> board
      (start, startSides) = case restored of
        FromSaved ws s -> (ws, s)
        _              -> (widgets l, factorySides (widgets l))
      done     = () <$ ffilter not (updated (editOn edit))
      reset    = gate (current active) (editReset edit)
      sideOf w = Map.findWithDefault defaultControlSide (widgetId w) startSides
  carrying <- liftIO (newIORef False)
  (layerEl, (presses, turns)) <- elDynClass' "div" (layerClass <$> active) $ do
    outs <- mapM (\w -> slot live revealed (sideOf w) reset shown w) (widgets l)
    targetOutline shown
    pure (leftmost (map fst outs), mconcat (map snd outs))
  pressed <- performEvent (measure layerEl <$> gate (current (editOn edit)) presses)
  hands   <- windowHands carrying
  performEvent_ (liftIO . writeIORef carrying <$> updated held)
  board <- foldDyn ($) (boardOf start) $ leftmost
             [ const (boardOf (widgets l)) <$ reset
             , (\(magnet, hand) -> stepBoard magnet hand)
                 <$> attach (current (editMagnet edit)) (leftmost [pressed, gate (current held) hands])
             ]
  shown <- holdUniqDyn (scene <$> editMagnet edit <*> board)
  sides <- foldDyn ($) startSides $ leftmost
             [ const (factorySides (widgets l)) <$ reset
             , Map.union <$> turns
             ]
  let saved = (,) <$> sides <*> (boardLayout <$> board)
  performEvent_ (liftJSM . uncurry (writeSaved l) <$> tag (current saved) done)
  pure (uncurry (atFactory (widgets l)) <$> saved)
  where
    layerClass a
      | a         = "canvas__layer"
      | otherwise = "canvas__layer canvas__layer--hidden"

    -- Coger necesita cuántos px mide el lienzo ahora; la capa mide lo mismo que él.
    measure layerEl (wid, grip, p) = liftJSM $ do
      r <- DOM.getBoundingClientRect (_element_raw layerEl)
      w <- DOM.getWidth r
      h <- DOM.getHeight r
      pure (Press wid grip p (w, h))

-- | De dónde sale un layout al abrir la página, según lo guardado en el navegador. Si
-- el navegador no deja leer, como si no hubiera nada guardado.
readSaved :: Layout -> JSM Restored
readSaved l = restoreLayout (widgets l) . either unreadable id <$> try (do
  storage <- Window.getLocalStorage =<< DOM.currentWindowUnchecked
  Storage.getItem storage (savedKey (layoutId l)))
  where
    unreadable :: SomeException -> Maybe Text
    unreadable _ = Nothing

-- | Guarda en el navegador lo que se ve de un layout. Si no deja escribir, no pasa nada.
writeSaved :: Layout -> Map WidgetId Side -> [WidgetConfig] -> JSM ()
writeSaved l sides ws = either unwritable pure =<< try (do
  storage <- Window.getLocalStorage =<< DOM.currentWindowUnchecked
  Storage.setItem storage (savedKey (layoutId l)) (saveLayout sides ws))
  where
    unwritable :: SomeException -> JSM ()
    unwritable _ = pure ()

-- | Dónde y por dónde aprieta el botón izquierdo sobre la tarjeta en edición, en px
-- de la ventana: por el título o por la esquina ◢. Los controles del título
-- (botones, desplegables, casillas) siguen siendo controles y no cogen la tarjeta; al
-- coger, el navegador no selecciona texto.
slotPresses :: MonadWidget t m => DOM.HTMLElement -> m (Event t (Grip, (Double, Double)))
slotPresses e = fmapMaybe id <$> wrapDomEvent e (`DOM.on` DOM.mouseDown) grab
  where
    grab = do
      which <- Mouse.getButton =<< DOM.event
      grip  <- maybe (pure Nothing) (liftJSM . gripOf) =<< DOM.target
      case grip of
        Just g | which == 0 -> do
          DOM.preventDefault
          (x, y) <- DOM.mouseClientXY
          pure (Just (g, (fromIntegral x, fromIntegral y)))
        _ -> pure Nothing
    gripOf :: DOM.HTMLElement -> JSM (Maybe Grip)
    gripOf t = do
      corner  <- DOM.closest t (".canvas--editing .widget-slot__grip" :: Text)
      title   <- DOM.closest t (".canvas--editing .widget__head" :: Text)
      control <- DOM.closest t ("button, select, input, label, a, textarea" :: Text)
      pure $ case () of
        _ | isJust corner                     -> Just ByCorner
          | isJust title && isNothing control -> Just ByTitle
          | otherwise                         -> Nothing

-- | El ratón y el teclado de toda la ventana, para quien lleva una tarjeta: el
-- puntero llega aunque salga del lienzo, y soltar fuera de la ventana también avisa.
-- Mientras se lleva una (@carrying@), Alt no le pasa el foco al menú del navegador y
-- Esc cancela.
windowHands :: MonadWidget t m => IORef Bool -> m (Event t Hand)
windowHands carrying = do
  win   <- liftJSM DOM.currentWindowUnchecked
  moves <- wrapDomEvent win (`DOM.on` DOM.mouseMove) $ do
    (x, y) <- DOM.mouseClientXY
    alt    <- Mouse.getAltKey =<< DOM.event
    pure (Point (fromIntegral x, fromIntegral y) alt)
  ups   <- wrapDomEvent win (`DOM.on` DOM.mouseUp) (pure Release)
  downs <- wrapDomEvent win (`DOM.on` DOM.keyDown) (keyHand True)
  lifts <- wrapDomEvent win (`DOM.on` DOM.keyUp) (keyHand False)
  pure (leftmost [moves, ups, fmapMaybe id downs, fmapMaybe id lifts])
  where
    keyHand down = do
      k    <- Key.getKey =<< DOM.event
      held <- liftIO (readIORef carrying)
      case (k :: Text) of
        "Alt" | held             -> Just (AltKey down) <$ DOM.preventDefault
        "Escape" | held && down  -> pure (Just Cancel)
        _                        -> pure Nothing

-- | El contorno de donde caerá la tarjeta que se lleva; escondido si no se lleva
-- ninguna o si donde está no se deja.
targetOutline :: MonadWidget t m => Dynamic t Scene -> m ()
targetOutline shown =
  elDynAttr "div" (attrs . sceneTarget <$> shown) $ divClass "canvas__target-box" blank
  where
    attrs (Just r) = "class" =: "canvas__target" <> "style" =: slotStyle r
    attrs Nothing  = "class" =: "canvas__target" <> "hidden" =: ""

-- | Envuelve un widget en su __slot__: el rectángulo que le da sitio en el
-- lienzo, con el estilo que calcula 'slotStyle', y con la esquina ◢ que solo se ve
-- en edición. Devuelve dónde y por dónde se coge ('slotPresses') y cada lado nuevo
-- de su tabla de mando, con su id.
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
slot :: MonadWidget t m
     => LiveView t -> Event t () -> Side -> Event t () -> Dynamic t Scene -> WidgetConfig
     -> m (Event t (WidgetId, Grip, (Double, Double)), Event t (Map WidgetId Side))
slot live revealed side reset shown wc = do
  attrs  <- holdUniqDyn (slotAttrs wc <$> shown)
  (e, turns) <- elDynAttr' "div" attrs $ do
    t <- renderWidget live revealed side reset wc
    divClass "widget-slot__grip" $ text "◢"
    pure t
  grabs  <- slotPresses (DOM.uncheckedCastTo DOM.HTMLElement (_element_raw e))
  pure ((\(g, p) -> (widgetId wc, g, p)) <$> grabs, Map.singleton (widgetId wc) <$> turns)

-- | Clase y estilo del slot según lo que se pinta: la que se lleva sigue al puntero
-- ('heldStyle') y se marca si ahí no se deja; las demás, en su rectángulo.
slotAttrs :: WidgetConfig -> Scene -> Map Text Text
slotAttrs wc s = case sceneHeld s of
  Just h | heldId h == widgetId wc -> "class" =: heldClass h <> "style" =: heldStyle h
  _ -> "class" =: slotClass r <> "style" =: slotStyle r
  where
    r = fromMaybe wc (find ((== widgetId wc) . widgetId) (sceneCards s))
    heldClass h
      | heldFits h = "widget-slot widget-slot--held"
      | otherwise  = "widget-slot widget-slot--held widget-slot--blocked"

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

-- | El modo edición: si se está editando, si el imán está encendido y cuándo se pulsa
-- «Restablecer».
data Edit t = Edit
  { editOn     :: Dynamic t Bool
  , editMagnet :: Dynamic t Bool
  , editReset  :: Event t ()
  }

-- | Barra de botones que conmutan entre los layouts fijos, con los del modo
-- edición a su derecha ('editToggle', 'magnetToggle', 'resetButton'). Sostiene el
-- layout activo (arranca en 'raceOverview') y el modo edición; cambiar de layout no
-- saca de la edición. @unfit@ dice qué layouts volvieron al de fábrica porque lo
-- guardado no encajaba: cada uno lleva un asterisco, y hay __una sola nota__ para
-- todos, bajo el primero, abierta al cargar. Pulsarla la cierra y pasar el ratón por
-- un botón con asterisco la vuelve a enseñar; asteriscos y nota se quitan al entrar
-- en edición.
layoutSwitcher :: MonadWidget t m
               => (Layout -> Bool) -> Dynamic t Bool -> m (Dynamic t Layout, Edit t)
layoutSwitcher unfit atFactoryNow = divClass "layout-switcher" $ mdo
  noted <- holdDyn True (False <$ ffilter id (updated editing))
  open  <- holdDyn True (False <$ leftmost [overviewClose, qualyClose])
  hover <- holdDyn False (leftmost [overviewHover, qualyHover])
  let shown = (&&) <$> noted <*> ((||) <$> open <*> hover)
      names = [name | (l, name) <- [(raceOverview, "Race Overview"), (qualy, "Qualy")], unfit l]
      holder = listToMaybe (filter unfit [raceOverview, qualy])
      item l = layoutButton noted shown (unfit l) (holder == Just l) (unfitNote names)
  (overviewClick, overviewHover, overviewClose) <- item raceOverview "Race Overview"
  (qualyClick, qualyHover, qualyClose)          <- item qualy "Qualy"
  active <- holdDyn raceOverview $ leftmost
    [ raceOverview <$ overviewClick
    , qualy        <$ qualyClick
    ]
  editing <- editToggle
  magnet  <- magnetToggle editing
  reset   <- resetButton editing atFactoryNow
  pure (active, Edit editing magnet reset)

-- | El botón de un layout: con asterisco mientras @noted@ si su guardado no encajó
-- (@unfit@), y con la nota debajo si es quien la lleva (@holds@), enseñada mientras
-- @shown@. Devuelve el clic, si el ratón entra o sale del botón con asterisco, y el
-- clic en la nota.
layoutButton :: MonadWidget t m
             => Dynamic t Bool -> Dynamic t Bool -> Bool -> Bool -> T.Text -> T.Text
             -> m (Event t (), Event t Bool, Event t ())
layoutButton noted shown unfit holds note label = elClass "span" "layout-switcher__item" $ do
  let marked = (&& unfit) <$> noted
  (b, _) <- elDynClass' "button" (buttonClass <$> marked) $ dynText (buttonLabel <$> marked)
  closes <- if holds
    then do
      (n, _) <- elDynClass' "div" (noteClass <$> shown) $ text note
      pure (domEvent Click n)
    else pure never
  let hovers = gate (current marked) $
        leftmost [True <$ domEvent Mouseenter b, False <$ domEvent Mouseleave b]
  pure (domEvent Click b, hovers, closes)
  where
    buttonClass m
      | m         = "switcher__btn switcher__btn--noted"
      | otherwise = "switcher__btn"
    buttonLabel m
      | m         = label <> "*"
      | otherwise = label
    noteClass s
      | s         = "layout-note layout-note--open"
      | otherwise = "layout-note"

-- | «↺ Restablecer», solo visible en edición. Si lo que se ve ya es el de fábrica
-- (@atFactoryNow@) restablece sin más; si no, en su sitio pregunta «¿Volver a la
-- configuración predeterminada? Sí · No», y solo «Sí» restablece. Cualquier clic
-- fuera de la pregunta, y salir de la edición, cuentan como «No».
resetButton :: MonadWidget t m => Dynamic t Bool -> Dynamic t Bool -> m (Event t ())
resetButton editing atFactoryNow = mdo
  (pressed, yes, no) <- elClass "span" "reset-confirm" $ do
    (b, _) <- elDynAttr' "button" (buttonAttrs <$> editing <*> asking) $ text "↺ Restablecer"
    (y, n) <- elDynAttr "span" (questionAttrs <$> editing <*> asking) $ do
      text "¿Volver a la configuración predeterminada?"
      (y, _) <- elClass' "button" "switcher__btn reset-confirm__yes" $ text "Sí"
      (n, _) <- elClass' "button" "switcher__btn" $ text "No"
      pure (domEvent Click y, domEvent Click n)
    pure (domEvent Click b, y, n)
  outside <- clicksOutside ".reset-confirm"
  let direct = gate (current atFactoryNow) pressed
      ask    = gate (not <$> current atFactoryNow) pressed
  asking <- holdDyn False $ leftmost
    [ True <$ ask
    , False <$ leftmost [yes, no, outside, () <$ ffilter not (updated editing)]
    ]
  pure (leftmost [direct, yes])
  where
    buttonAttrs shown a =
      "class" =: "switcher__btn reset-button"
        <> (if shown && not a then mempty else "hidden" =: "")
    questionAttrs shown a =
      "class" =: "reset-confirm__question"
        <> (if shown && a then mempty else "hidden" =: "")

-- | Los clics de la ventana que caen fuera de lo que casa con @selector@.
clicksOutside :: MonadWidget t m => Text -> m (Event t ())
clicksOutside selector = do
  win <- liftJSM DOM.currentWindowUnchecked
  fmapMaybe id <$> wrapDomEvent win (`DOM.on` DOM.click)
    (maybe (pure (Just ())) (liftJSM . away) =<< DOM.target)
  where
    away :: DOM.HTMLElement -> JSM (Maybe ())
    away t = (\hit -> if isJust hit then Nothing else Just ()) <$> DOM.closest t selector

-- | El interruptor del imán, solo visible en edición. Arranca encendido y recuerda
-- cómo se dejó hasta recargar; encendido queda marcado y lleva ✓.
magnetToggle :: MonadWidget t m => Dynamic t Bool -> m (Dynamic t Bool)
magnetToggle editing = mdo
  (e, _) <- elDynAttr' "button" (attrs <$> editing <*> magnet) $ dynText (label <$> magnet)
  magnet <- toggle True (domEvent Click e)
  pure magnet
  where
    attrs shown o =
      "class" =: (if o then "switcher__btn magnet-toggle magnet-toggle--on"
                       else "switcher__btn magnet-toggle")
        <> (if shown then mempty else "hidden" =: "")
    label o
      | o         = "⊞ Imán ✓"
      | otherwise = "⊞ Imán"

-- | El botón del modo edición (2026-09-29 (g)): entra y sale, y arranca fuera.
-- Nombra a dónde lleva, como el aspecto de la banda; en edición queda marcado.
editToggle :: MonadWidget t m => m (Dynamic t Bool)
editToggle = mdo
  (e, _) <- elDynClass' "button" (toggleClass <$> editing) $
              dynText (toggleLabel <$> editing)
  editing <- toggle False (domEvent Click e)
  pure editing
  where
    toggleClass on
      | on        = "switcher__btn edit-toggle edit-toggle--on"
      | otherwise = "switcher__btn edit-toggle"
    toggleLabel on
      | on        = "✓ Terminar edición"
      | otherwise = "✎ Editar layout"

-- | Despacha una 'WidgetConfig' a su widget según 'widgetType'. Total sobre los
-- __siete__ constructores de 'WidgetType'; los aún no implementados caen en un
-- placeholder (no @error@ parcial). 'params' no se consume todavía.
--
-- 'HistoricalStats' y 'ConstructorStats' son dos ramas desde 2026-08-26, una por
-- clasificación: antes 'HistoricalStats' montaba un widget que pintaba las dos
-- tablas. La totalidad de este @case@ es la que cobra el constructor nuevo, y
-- __solo bajo GHCJS__ (@-Wall@ del paquete @frontend@).
--
-- __El refresco del directo, el aviso de que la capa se enseña, el lado de arranque
-- y «Restablecer» atraviesan las siete ramas y cada uno lo usa una__, por la misma
-- razón por la que el rectángulo no lo lleva el widget: quien conoce el dato es
-- quien monta, y darlo solo a la rama que lo pide exigiría que el @case@ devolviera
-- funciones de tipos distintos. Solo Lap Comparison devuelve lados; las demás,
-- 'never'.
renderWidget :: MonadWidget t m
             => LiveView t -> Event t () -> Side -> Event t () -> WidgetConfig -> m (Event t Side)
renderWidget live revealed side reset wc = case widgetType wc of
  LiveTiming       -> never <$ liveTimingWidget live
  Telemetry        -> never <$ telemetryWidget
  LapComparison    -> comparisonWidget revealed side reset
  TyreStrategy     -> never <$ placeholderWidget "Tyre Strategy"
  HistoricalStats  -> never <$ driverStatsWidget
  ConstructorStats -> never <$ constructorStatsWidget
  Custom           -> never <$ placeholderWidget "Custom"

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
