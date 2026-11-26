{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}

-- | Página Dashboard (un módulo por flujo, convención @Pages.\<Flujo\>@).
--
-- La pantalla no monta widgets hardcodeados: se **deriva de un 'Layout'**
-- ('Common.Types'). 'renderWidget' despacha por
-- 'widgetType' a los widgets existentes ('liveTimingWidget' \/ 'comparisonWidget' \/ …) y
-- da un placeholder para los tipos aún no implementados. Tres botones conmutan entre
-- tres 'Layout' fijos ('raceOverview' \/ 'qualy' \/ 'strategy') sosteniendo un
-- @Dynamic t Layout@; todos se montan una vez, cada uno en su capa, y los inactivos se ocultan
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

import           Client                        (fetchJson)
import           Common.Blend                  (Blend, blendFromKey, blendKey,
                                                blendLabel, blendOnOpen,
                                                blendStoreKey, blendsInOrder)
import           Common.Carry                 (Board (..), Grip (..),
                                                Hand (..), Scene (..), boardOf,
                                                scene, stepBoard)
import           Common.ComparisonCard         (CardControl, defaultControl)
import           Common.FixedLayouts           (qualy, raceOverview, strategy)
import           Common.Format                 (ClockForm (..), formatClock)
import           Common.Group                  (GroupEdit, applyGroupEdit)
import           Common.Layout                 (slotStyle)
import           Common.Origin                 (Sourced (..))
import           Common.Route                  (circuitSeasonsPathFor, seasonPath)
import           Common.Saved                  (Restored (..), Shown (..),
                                                atFactory, factoryShown,
                                                resetQuestion, restoreLayout,
                                                sameShown, saveLayout, savedKey,
                                                unfitNote)
import           Common.Session                (SeasonRace (..),
                                                SeasonSession (..),
                                                SessionKey (..),
                                                SessionPick (..),
                                                latestStartedKey, queryWith,
                                                renderSessionKey,
                                                rollingKey, selectorLabel,
                                                selectorRaces, sessionCodeText,
                                                sessionFromUrl)
import           Common.Shown                  (Kept (..), Poll (..),
                                                delayFromUrl, delayKey,
                                                delayOnOpen, delayQuery,
                                                keepLast, keptNothing, landed,
                                                readDelay)
import           Common.Types                  (BandFlag (..), BandPiece,
                                                Countdown, Layout (..),
                                                LiveTable (..), SessionClock,
                                                SessionInfo (..),
                                                StateReading (..),
                                                TrackCondition, UpNext (..),
                                                WidgetConfig (..),
                                                WidgetId (..), WidgetType (..),
                                                bandMark, bandNote, bandPieces,
                                                bandRight, catchUp,
                                                countdownAfter, countdownText,
                                                flagName, isDerived, pieceFlag,
                                                pieceSeparator, pieceWord,
                                                sessionTitle, shownClock,
                                                shownNext, tickClock)
import           Control.Exception             (SomeException, try)
import           Control.Monad                 (forM_, when)
import           Control.Monad.IO.Class        (liftIO)
import           Data.IORef                    (IORef, newIORef, readIORef,
                                                writeIORef)
import           Data.Map                      (Map)
import qualified Data.Map                      as Map
import           Data.Maybe                    (fromMaybe, isJust, isNothing,
                                                listToMaybe)
import           Data.Text                     (Text)
import qualified Data.Text                     as T
import           Data.Time.Clock               (UTCTime (..), getCurrentTime)
import           Data.Time.Clock.POSIX         (utcTimeToPOSIXSeconds)
import qualified GHCJS.DOM                     as DOM (currentWindowUnchecked)
import qualified GHCJS.DOM.DOMRectReadOnly     as DOM (getHeight, getWidth)
import qualified GHCJS.DOM.Element             as DOM (closest,
                                                       getBoundingClientRect)
import qualified GHCJS.DOM.EventM              as DOM (event, mouseClientXY, on,
                                                       preventDefault, target)
import qualified GHCJS.DOM.GlobalEventHandlers as DOM (click, keyDown, keyUp,
                                                       mouseDown, mouseMove,
                                                       mouseUp)
import qualified GHCJS.DOM.History             as History (pushState,
                                                           replaceState)
import qualified GHCJS.DOM.HTMLInputElement    as Input (getValue)
import qualified GHCJS.DOM.KeyboardEvent       as Key (getKey)
import qualified GHCJS.DOM.Location            as Location (getHref,
                                                            getPathname,
                                                            getSearch)
import qualified GHCJS.DOM.MouseEvent          as Mouse (getAltKey, getButton)
import qualified GHCJS.DOM.Storage             as Storage (getItem, setItem)
import qualified GHCJS.DOM.Types               as DOM (Element (..),
                                                       HTMLElement (..),
                                                       History, JSVal,
                                                       MouseEvent (..),
                                                       uncheckedCastTo)
import qualified GHCJS.DOM.Window              as Window (getHistory,
                                                          getLocalStorage,
                                                          getLocation)
import qualified GHCJS.DOM.WindowEventHandlers as DOM (popState)
import           Language.Javascript.JSaddle   (JSM, eval, jsNull, liftJSM,
                                                valToNumber)
import           Pages.Dashboard.Helper        (slotAttrs)
import           Reflex.Dom
import           Widgets.Card                  (CardExtras (..))
import           Widgets.Comparison            (comparisonWidget)
import           Widgets.Groups                (GroupContext (..), cardExtras,
                                                rowTitle)
import           Widgets.Historical            (constructorStatsWidget,
                                                driverStatsWidget)
import           Widgets.Live                  (LiveView (..), chosenPoll,
                                                delayedLive, livePoll,
                                                shownView)
import           Widgets.Live.Helper           (liveAside, missingTitle,
                                                sessionOf)
import           Widgets.LiveTiming            (liveTimingWidget)
import           Widgets.TyreStrategy          (tyreStrategyWidget)

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
-- __El refresco del directo lo monta la página y no la tarjeta__ ('Widgets.Live.livePoll'):
-- los dos layouts están montados a la vez y los dos llevan Live Timing, así que una
-- petición por tarjeta saldría dos veces. Así comparten una sola.
--
-- __Es 'mdo' porque la cabecera lee de las capas__: «Restablecer» necesita saber si la
-- capa que se ve ya es la de fábrica, y «Cancelar» si alguna cambió desde que se entró
-- en la edición, y las capas se montan después de la cabecera.
--
-- __La sesión sale de la dirección__ (@?sesion=@): al abrir, cada vez que el navegador
-- vuelve atrás o adelante ('addressChanges') y al elegirla en la banda, que la escribe en
-- el historial ('pushAddress'); un paso que no la cambia no la vuelve a pedir.
dashboardPage :: MonadWidget t m => m ()
dashboardPage = divClass "page page--dashboard" $ mdo
  toggleClick <- headerToggle
  openDyn     <- toggle True toggleClick
  url         <- getLocationUrl
  moved       <- addressChanges
  let chosen = attachWithMaybe (\cur k -> if k == cur then Nothing else Just k) (current session) picked
  performEvent_ (liftJSM . pushAddress <$> chosen)
  session     <- holdUniqDyn =<< holdDyn (sessionFromUrl url) (leftmost [chosen, sessionFromUrl <$> moved])
  saved       <- liftJSM (readStored delayKey)
  let initial = delayOnOpen url saved
  savedBlend  <- liftJSM (readStored blendStoreKey)
  pb          <- getPostBuild
  when (isNothing (delayFromUrl url)) $
    performEvent_ (liftJSM (setAddress History.replaceState (delayQuery initial)) <$ pb)
  poll        <- livePoll
  chosenP     <- chosenPoll session
  restored    <- mapM (\l -> (,) l <$> liftJSM (readSaved l)) [raceOverview, qualy, strategy]
  let unfit l = lookup l restored == Just Unfit
  (layoutDyn, live, edit, picked, blend) <- divClass "top-bar" $ do
    (active, delay, blendNow, editing) <-
      dashboardHeader initial (blendOnOpen savedBlend) (isJust <$> session) openDyn unfit shownAtFactory anyMoved
        shownGroupCount
    performEvent_ (liftJSM . rememberDelay <$> updated delay)
    performEvent_ (liftJSM . writeStored blendStoreKey . blendKey <$> updated blendNow)
    delayed <- delayedLive never delay poll
    chosenV <- delayedLive (() <$ updated session) (constDyn 0) chosenP
    let shown = shownView session delayed chosenV
    p <- sessionBand openDyn session (lvPoll delayed) (lvPoll shown) (lvAge shown)
    pure (active, shown, editing, p, blendNow)
  layers <- elDynClass "div" (canvasClass <$> openDyn <*> editOn edit) $
    mapM (\(l, r) -> (,) (layoutId l) <$> layer blend session live layoutDyn edit l r) restored
  let ofActive none pick =
        (\l vs -> fromMaybe none (lookup (layoutId l) vs))
          <$> layoutDyn <*> traverse (\(i, out) -> (,) i <$> pick out) layers
      shownAtFactory  = ofActive True layerAtFactory
      shownGroupCount = ofActive 0 layerGroupCount
      anyMoved = or <$> traverse (layerMoved . snd) layers
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

-- | Escribe en el historial la dirección con esa sesión ('Common.Session.queryWith'), sin
-- recargar; 'Nothing' la quita.
pushAddress :: Maybe SessionKey -> JSM ()
pushAddress k = setAddress History.pushState (queryWith k)

-- | El retraso aplicado en el campo: a la dirección, en su sitio y sin una entrada más en
-- «atrás» ('Common.Shown.delayQuery'), y al navegador ('Common.Shown.delayKey').
rememberDelay :: Int -> JSM ()
rememberDelay n = do
  setAddress History.replaceState (delayQuery n)
  writeStored delayKey (formatClock ClockCompact n)

-- | Cambia la query de la dirección con @f@, sin recargar, con @write@:
-- 'History.pushState' la añade al historial y 'History.replaceState' la cambia en su sitio.
setAddress :: (DOM.History -> DOM.JSVal -> Text -> Maybe Text -> JSM ()) -> (Text -> Text) -> JSM ()
setAddress write f = do
  win    <- DOM.currentWindowUnchecked
  loc    <- Window.getLocation win
  path   <- Location.getPathname loc
  search <- Location.getSearch loc
  hist   <- Window.getHistory win
  write hist jsNull "" (Just (path <> f search))

-- | La dirección de la página cada vez que el navegador vuelve atrás o adelante en su
-- historial (@popstate@).
addressChanges :: MonadWidget t m => m (Event t Text)
addressChanges = do
  win <- liftJSM DOM.currentWindowUnchecked
  wrapDomEvent win (`DOM.on` DOM.popState) (Location.getHref =<< Window.getLocation win)

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

-- | La cabecera: título, conmutación de layouts, el modo edición, la mezcla de las dos
-- tintas de cada curva y el retraso del directo, que se pliegan __juntos__ (2026-09-07).
-- Devuelve el layout activo, el retraso en segundos, la mezcla y si se está editando,
-- porque viven dentro; el retraso arranca en @initial@ y la mezcla en @initialBlend@.
-- @chosenNow@ dice si hay una sesión elegida, a la que el
-- retraso no se aplica ('delayField'). @atFactoryNow@ y @movedNow@ dicen si el layout que se
-- ve ya es el de fábrica y si algo cambió desde que se entró en la edición, para que
-- «Restablecer» y «Cancelar» no pregunten en balde; @groupsNow@, cuántos grupos tiene,
-- para que «Restablecer» diga cuántos quita.
--
-- __Se pliega con una clase y no desmontando__, y la diferencia importa: con
-- 'dyn' el contenido se re-monta en cada cambio, así que 'layoutSwitcher'
-- perdería su @Dynamic t Layout@ y __volvería a 'raceOverview'__ cada vez que se
-- desplegara. Con 'elDynClass' el DOM se queda montado y solo cambia si se pinta;
-- por lo mismo, plegarla no saca de la edición.
dashboardHeader :: MonadWidget t m
                => Int -> Blend -> Dynamic t Bool -> Dynamic t Bool -> (Layout -> Bool) -> Dynamic t Bool
                -> Dynamic t Bool -> Dynamic t Int -> m (Dynamic t Layout, Dynamic t Int, Dynamic t Blend, Edit t)
dashboardHeader initial initialBlend chosenNow openDyn unfit atFactoryNow movedNow groupsNow =
  elDynClass "div" (headerClass <$> openDyn) $ do
    el "h1" $ text "F1 Functional Dashboard"
    divClass "dashboard-header__controls" $ do
      (active, edit) <- layoutSwitcher unfit atFactoryNow movedNow groupsNow
      (blend, delay) <- divClass "dashboard-header__options" $
        (,) <$> blendField initialBlend <*> delayField initial chosenNow
      pure (active, delay, blend, edit)
  where
    headerClass open
      | open      = "dashboard-header"
      | otherwise = "dashboard-header dashboard-header--hidden"

-- | El desplegable de la mezcla, nativo, con las tres en el orden de
-- 'Common.Blend.blendsInOrder'; arranca en @initial@. Vale para todas las gráficas
-- (2026-11-20 (z) y (ab)).
blendField :: MonadWidget t m => Blend -> m (Dynamic t Blend)
blendField initial = elClass "label" "blend-field" $ do
  elClass "span" "blend-field__label" $ text "Mezcla"
  let cfg = def
        & selectElementConfig_initialValue .~ blendKey initial
        & selectElementConfig_elementConfig . elementConfig_initialAttributes
            .~ ("class" =: "car-selector__select blend-field__select")
  (sel, _) <- selectElement cfg $ forM_ blendsInOrder $ \b ->
    elAttr "option" ("value" =: blendKey b) $ text (blendLabel b)
  pure (fromMaybe initial . blendFromKey <$> _selectElement_value sel)

-- | El campo del retraso, en @m:ss@. Lo tecleado se aplica __al pulsar Enter o al
-- salir del campo__, nunca tecla a tecla: camino de @0:41@ se pasa por @0@, que
-- quitaría el retraso. Lo que se aplica es lo que hay en la caja en ese momento, leído del
-- elemento. Lo que no vale ('Common.Shown.readDelay') no cambia nada, y al aplicarse el
-- campo vuelve a escribir el retraso vigente.
--
-- Con una sesión elegida (@chosen@) se atenúa y dice «(solo para el directo)»: el retraso
-- se le aplica solo al directo, y se puede seguir cambiando (2026-11-13 (n), 11b).
delayField :: MonadWidget t m => Int -> Dynamic t Bool -> m (Dynamic t Int)
delayField initial chosen = elDynClass "label" (fieldClass <$> chosen) $ mdo
  elClass "span" "delay-field__label" $ text "Diferido"
  input <- inputElement $
    def
      & inputElementConfig_initialValue .~ formatClock ClockCompact initial
      & inputElementConfig_setValue     .~ (formatClock ClockCompact <$> applied)
      & initialAttributes               .~ ("class" =: "delay-field__input" <> "size" =: "5")
  elDynAttr "span" (noteAttrs <$> chosen) $ text "(solo para el directo)"
  let committed = leftmost [() <$ ffilter (== 13) (domEvent Keypress input), domEvent Blur input]
  typed <- performEvent (liftJSM (Input.getValue (_inputElement_raw input)) <$ committed)
  let applied = attachWith (\old t -> fromMaybe old (readDelay t)) (current delay) typed
  delay <- holdDyn initial applied
  pure delay
  where
    fieldClass c = T.unwords (["delay-field"] <> ["delay-field--idle" | c])
    noteAttrs c  = "class" =: "delay-field__note" <> (if c then mempty else "hidden" =: "")

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
-- ('Common.Shown.keepLast', 2026-09-22 (b)); al elegir otra, la olvida.
--
-- Un solo tic de un segundo mueve los dos relojes de la banda —la cuenta atrás y la
-- edad de lo conservado—, para que no se desincronicen.
--
-- Una sesión elegida que no existe lo dice a la izquierda, con su clave
-- ('Widgets.Live.Helper.missingTitle'); el aviso va en un @span@ con @hidden@ mientras
-- está vacío, para que sin él la banda no cambie.
--
-- __El título es el selector__ ('sessionPicker'): devuelve cada sesión que se elige en él.
--
-- Con una sesión elegida y el directo rodando, el aviso «● EN DIRECTO: … [Volver]» ocupa el
-- sitio de la cuenta atrás (2026-11-13 (l); 'Widgets.Live.Helper.liveAside'), leído de
-- @live@, el directo con su diferido. «Volver» se devuelve como «Ahora» ('Nothing').
sessionBand :: MonadWidget t m
            => Dynamic t Bool -> Dynamic t (Maybe SessionKey) -> Dynamic t (Poll (Sourced LiveTable))
            -> Dynamic t (Poll (Sourced LiveTable)) -> Dynamic t (Maybe Int) -> m (Event t (Maybe SessionKey))
sessionBand openDyn session live poll lag = mdo
  tick    <- tickLossyFromPostBuildTime 1
  day     <- localTimeOfDay tick
  let arrived = sessionOf <$> ffilter (isJust . landed) (updated poll)
  -- Al volver al directo la llegada cae en el mismo frame que el cambio: primero se olvida
  -- lo anterior y luego se guarda lo que llega.
  kept    <- foldDyn ($) keptNothing $
               mergeWith (\forget keep -> keep . forget) [const keptNothing <$ updated session, keepLast <$> arrived]
  age     <- sessionAge tick arrived
  title   <- holdUniqDyn (maybe "" sessionTitle . keptValue <$> kept)
  missing <- holdUniqDyn (missingTitle <$> session <*> poll)
  aside   <- holdUniqDyn (liveAside <$> session <*> live)
  reading <- holdUniqDyn ((\k -> siState =<< keptValue k) <$> kept)
  track   <- holdUniqDyn ((\k -> siTrack =<< keptValue k) <$> kept)
  next    <- countdown tick lag (shownNext . fmap srcValue . pollShown <$> poll)
  restart <- ticked Nothing (fmap . countdownAfter) tick lag
               ((siCountdown =<<) . sessionOf <$> poll)
  clock   <- sessionClock tick ((shownClock =<<) . sessionOf <$> poll)
  let laps = (siLaps =<<) . sessionOf <$> poll
      restartText = (\d -> fmap (countdownText d)) <$> day <*> restart
  asCard  <- toggle True lookClick
  (lookClick, picked) <- elDynClass "div" (bandClass <$> openDyn <*> asCard) $ do
    p <- sessionPicker session live title
    elDynAttr "span" (missingAttrs <$> missing) $ dynText missing
    sessionState reading track restartText (keptStale <$> kept) age
    elDynAttr "span" (shownUnless "session-band__next" . isJust <$> aside) $
      dynText (bandRight <$> day <*> next <*> laps <*> clock)
    back <- elDynAttr "span" (shownUnless "session-band__live" . isNothing <$> aside) $ do
      elClass "span" "session-band__live-text" $ do
        elClass "span" "session-band__live-dot" $ text "●"
        text " "
        el "b" $ text "EN DIRECTO:"
        text " "
        dynText (fromMaybe "" <$> aside)
      (b, _) <- elAttr' "button" ("type" =: "button" <> "class" =: "session-band__back") $ text "Volver"
      pure (domEvent Click b)
    l <- lookSwitch asCard
    pure (l, leftmost [p, Nothing <$ back])
  pure picked
  where
    shownUnless cls hide = "class" =: cls <> (if hide then "hidden" =: "" else mempty)

    bandClass open card =
      T.unwords $
        ["session-band", lookClass card]
          <> ["session-band--header-hidden" | not open]

    lookClass card
      | card      = "session-band--card"
      | otherwise = "session-band--bar"

    missingAttrs t =
      "class" =: "session-band__missing" <> (if T.null t then "hidden" =: "" else mempty)

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

-- | El selector de sesión: el título de la banda como botón y, al pulsarlo, la lista por
-- gran premio de la temporada (@\/api\/season@, pedida una vez al montarse), con «Ahora»
-- arriba (2026-11-17 (o)). Devuelve cada elección: 'Nothing' es «Ahora», sin sesión elegida.
-- La lista se cierra al elegir, con Escape y al pulsar fuera de ella.
--
-- La sesión que rueda en @live@, el directo con su diferido ('Common.Session.rollingKey'),
-- lleva «●», y elegirla es elegir «Ahora». La lista solo se vuelve a montar cuando cambia.
sessionPicker :: MonadWidget t m
              => Dynamic t (Maybe SessionKey) -> Dynamic t (Poll (Sourced LiveTable)) -> Dynamic t Text
              -> m (Event t (Maybe SessionKey))
sessionPicker session live title = elClass "div" "session-band__picker" $ mdo
  pb      <- getPostBuild
  asked   <- fetchJson (seasonPath <$ pb)
  season  <- holdDyn [] (fromMaybe [] <$> asked)
  start   <- liftIO getCurrentTime
  minute  <- tickLossyFromPostBuildTime 60
  now     <- holdDyn (seconds start) (seconds . _tickInfo_lastUTC <$> minute)
  (btn, _) <- elAttr' "button" ("type" =: "button" <> "class" =: "session-band__pick") $
                dynText ((<> " ▾") <$> (selectorLabel <$> title <*> session <*> season))
  outside <- clicksOutside ".session-band__picker"
  escape  <- escapeKeys
  open    <- foldDyn ($) False $ leftmost
               [ const False <$ leftmost [() <$ picked, outside, escape]
               , not <$ domEvent Click btn ]
  picked  <- elDynAttr "div" (panelAttrs <$> open) $ do
    elClass "p" "session-band__season" $ dynText (heading <$> season)
    (ahora, _) <- elAttr' "button" ("type" =: "button" <> "class" =: "session-band__now") $
                    text "Ahora (lo último y el directo)"
    liveKey <- holdUniqDyn (rollingKey <$> now <*> season <*> (sessionOf <$> live))
    races   <- holdUniqDyn (selectorRaces <$> now <*> session <*> liveKey <*> season)
    rows <- switchHold never =<< dyn (raceList <$> races)
    elClass "p" "session-band__legend" $
      text "rojo lleno = la elegida · ● = en directo · gris = aún no se ha corrido"
    pure (leftmost [Nothing <$ domEvent Click ahora, rows])
  pure picked
  where
    seconds :: UTCTime -> Int
    seconds = floor . utcTimeToPOSIXSeconds

    panelAttrs o = "class" =: "session-band__panel" <> (if o then mempty else "hidden" =: "")

    heading races = case concatMap raceSessions races of
      s : _ -> "Temporada " <> T.pack (show (skYear (ssnKey s))) <> " · la más reciente arriba"
      []    -> "Cargando la temporada…"

    raceList :: MonadWidget t m => [(SeasonRace, [SessionPick])] -> m (Event t (Maybe SessionKey))
    raceList races = leftmost <$> mapM raceRow races

    raceRow :: MonadWidget t m => (SeasonRace, [SessionPick]) -> m (Event t (Maybe SessionKey))
    raceRow (r, picks) =
      elClass "div" (rowClass picks) $ do
        elClass "span" "session-band__race-name" $
          text ("R" <> T.pack (show (raceRound r)) <> " " <> raceName r)
        leftmost <$> mapM pickButton picks

    -- La que rueda lleva «●» y pulsarla es «Ahora».
    pickButton :: MonadWidget t m => SessionPick -> m (Event t (Maybe SessionKey))
    pickButton p = do
      (b, _) <- elAttr' "button" (pickAttrs p) $ do
        when (spLive p) $ elClass "span" "session-band__live-dot" (text "●") >> text " "
        text (sessionCodeText (skCode (spKey p)))
      pure ((if spLive p then Nothing else Just (spKey p)) <$ domEvent Click b)

    pickAttrs p =
      "type" =: "button"
        <> "class" =: T.unwords (["session-band__code"] <> ["session-band__code--chosen" | spChosen p])
        <> (if spStarted p then mempty else "disabled" =: "")

    rowClass ps =
      T.unwords (["session-band__race"] <> ["session-band__race--chosen" | any spChosen ps])

-- | Cada Escape que se pulsa en la ventana.
escapeKeys :: MonadWidget t m => m (Event t ())
escapeKeys = do
  win  <- liftJSM DOM.currentWindowUnchecked
  keys <- wrapDomEvent win (`DOM.on` DOM.keyDown) (Key.getKey =<< DOM.event)
  pure (() <$ ffilter (== ("Escape" :: Text)) keys)

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
-- fábrica, con los rectángulos, lo de cada Lap Comparison (lado, banda y modo) y los
-- grupos. Al terminar la edición guarda lo que se ve, esté activa o no, y al cancelarla
-- vuelve a como estaba al entrar, sin guardar; «Restablecer» devuelve al de fábrica solo
-- la activa, Lap Comparison y grupos incluidos, y se guarda al terminar como lo demás.
-- Fuera de la edición, lo que se turna en Lap Comparison se guarda al momento, salvo si
-- lo guardado no encajó: eso espera al siguiente «Terminar».
layer :: MonadWidget t m
      => Dynamic t Blend -> Dynamic t (Maybe SessionKey) -> LiveView t -> Dynamic t Layout -> Edit t -> Layout -> Restored
      -> m (LayerState t)
layer blend session live layoutDyn edit l restored = mdo
  active <- holdUniqDyn (((== layoutId l) . layoutId) <$> layoutDyn)
  let revealed = () <$ ffilter id (updated active)
      held     = isJust . boardCarry <$> board
      factory  = factoryShown l
      begin    = case restored of
        FromSaved s -> s
        _           -> factory
      startControls = shownControls begin
      reset    = gate (current active) (editReset edit)
      undone   = tag (current entry) (editCancel edit)
      controlOf w = Map.findWithDefault defaultControl (widgetId w)
      putControl w = leftmost [defaultControl <$ reset, controlOf w . shownControls <$> undone]
      outside  =(\editing waits -> not editing && not waits) <$> editOn edit <*> unfitWaits
  entry <- holdDyn begin (tag (current saved) (ffilter id (updated (editOn edit))))
  unfitWaits <- holdDyn (restored == Unfit) (False <$ editFinish edit)
  carrying <- liftIO (newIORef False)
  pb       <- getPostBuild
  asked    <- fetchJson (seasonPath <$ pb)
  season   <- holdDyn [] (fromMaybe [] <$> asked)
  opened   <- liftIO getCurrentTime
  viewed   <- holdUniqDyn
                ((\chosen ss info -> maybe (latestStartedKey (floor (utcTimeToPOSIXSeconds opened)) ss info) Just chosen)
                   <$> session <*> season <*> (sessionOf <$> lvPoll live))
  circuit  <- fetchJson (circuitSeasonsPathFor . fmap renderSessionKey <$> leftmost [updated viewed, tag (current viewed) pb])
  rounds   <- holdDyn [] (fromMaybe [] <$> circuit)
  let ctx = GroupContext
        { gcEditing = editOn edit
        , gcGroups  = groups
        , gcCards   = boardLayout <$> board
        , gcSession = session
        , gcLive    = sessionOf <$> lvPoll live
        , gcViewed  = viewed
        , gcRounds  = rounds
        }
  (layerEl, (presses, turns, groupEdits)) <- elDynClass' "div" (layerClass <$> active) $ do
    outs <- mapM (\w -> slot blend session live revealed (controlOf w startControls) (putControl w) ctx shown w) (widgets l)
    targetOutline shown
    pure ( leftmost [p | (p, _, _) <- outs]
         , mconcat [t | (_, t, _) <- outs]
         , leftmost [g | (_, _, g) <- outs] )
  let edited = attachWith (\(gs, ws) (wid, e) -> applyGroupEdit wid e (gs, ws))
                 ((,) <$> current groups <*> current (boardLayout <$> board)) groupEdits
  pressed <- performEvent (measure layerEl <$> gate (current (editOn edit)) presses)
  hands   <- windowHands carrying
  performEvent_ (liftIO . writeIORef carrying <$> updated held)
  board <- foldDyn ($) (boardOf (shownCards begin)) $ leftmost
             [ const (boardOf (shownCards factory)) <$ reset
             , const . boardOf . shownCards <$> undone
             , (\ws b -> b { boardLayout = ws }) . snd <$> edited
             , (\(magnet, hand) -> stepBoard magnet hand)
                 <$> attach (current (editMagnet edit)) (leftmost [pressed, gate (current held) hands])
             ]
  shown <- holdUniqDyn (scene <$> editMagnet edit <*> board)
  controls <- foldDyn ($) startControls $ leftmost
                [ const (shownControls factory) <$ reset
                , const . shownControls <$> undone
                , Map.union <$> turns
                ]
  groups <- holdDyn (shownGroups begin) $ leftmost
              [ shownGroups factory <$ reset
              , shownGroups <$> undone
              , fst <$> edited
              ]
  let saved = Shown <$> controls <*> groups <*> (boardLayout <$> board)
  performEvent_ (liftJSM . writeSaved l <$> leftmost
    [ tag (current saved) (editFinish edit)
    , gate (current outside) (updated saved)
    ])
  pure LayerState
    { layerAtFactory  = atFactory l <$> saved
    , layerMoved      = (\e s -> not (sameShown e s)) <$> entry <*> saved
    , layerGroupCount = length . shownGroups <$> saved
    }
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

-- | Lo que una capa le dice a la cabecera.
data LayerState t = LayerState
  { layerAtFactory  :: Dynamic t Bool
    -- ^ Si lo que enseña es el de fábrica ('Common.Saved.atFactory').
  , layerMoved      :: Dynamic t Bool
    -- ^ Si cambió desde que se entró en la edición ('Common.Saved.sameShown').
  , layerGroupCount :: Dynamic t Int
    -- ^ Cuántos grupos tiene.
  }

-- | De dónde sale un layout al abrir la página, según lo guardado en el navegador. Si
-- el navegador no deja leer, como si no hubiera nada guardado.
readSaved :: Layout -> JSM Restored
readSaved l = restoreLayout (widgets l) <$> readStored (savedKey (layoutId l))

-- | Guarda en el navegador lo que se ve de un layout. Si no deja escribir, no pasa nada.
writeSaved :: Layout -> Shown -> JSM ()
writeSaved l = writeStored (savedKey (layoutId l)) . saveLayout

-- | Lo guardado en el navegador con esa clave. Si no deja leer, como si no hubiera nada.
readStored :: Text -> JSM (Maybe Text)
readStored key = either unreadable id <$> try (do
  storage <- Window.getLocalStorage =<< DOM.currentWindowUnchecked
  Storage.getItem storage key)
  where
    unreadable :: SomeException -> Maybe Text
    unreadable _ = Nothing

-- | Guarda en el navegador ese valor con esa clave. Si no deja escribir, no pasa nada.
writeStored :: Text -> Text -> JSM ()
writeStored key content = either unwritable pure =<< try (do
  storage <- Window.getLocalStorage =<< DOM.currentWindowUnchecked
  Storage.setItem storage key content)
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
        "Alt" | held            -> Just (AltKey down) <$ DOM.preventDefault
        "Escape" | held && down -> pure (Just Cancel)
        _                       -> pure Nothing

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
--
-- Devuelve también cada cambio de grupos que se pide desde su fila, con su id.
slot :: MonadWidget t m
     => Dynamic t Blend -> Dynamic t (Maybe SessionKey) -> LiveView t -> Event t () -> CardControl -> Event t CardControl
     -> GroupContext t -> Dynamic t Scene -> WidgetConfig
     -> m (Event t (WidgetId, Grip, (Double, Double)), Event t (Map WidgetId CardControl), Event t (WidgetId, GroupEdit))
slot blend session live revealed control put ctx shown wc = do
  attrs  <- holdUniqDyn (slotAttrs wc <$> shown)
  let extras = maybe (CardExtras blank (pure never) (constDyn []) (constDyn (Nothing, [])) (constDyn [])) (\title -> cardExtras title (widgetId wc) ctx)
                 (rowTitle (widgetType wc))
  (e, (turns, edits)) <- elDynAttr' "div" attrs $ do
    t <- renderWidget blend session live revealed control put extras wc
    divClass "widget-slot__grip" $ text "◢"
    pure t
  grabs  <- slotPresses (DOM.uncheckedCastTo DOM.HTMLElement (_element_raw e))
  pure ( (\(g, p) -> (widgetId wc, g, p)) <$> grabs
       , Map.singleton (widgetId wc) <$> turns
       , (,) (widgetId wc) <$> edits )

-- | El modo edición: si se está editando, si el imán está encendido, y cuándo se
-- restablece, se termina (y se guarda) o se cancela (y no se guarda nada).
data Edit t = Edit
  { editOn     :: Dynamic t Bool
  , editMagnet :: Dynamic t Bool
  , editReset  :: Event t ()
  , editFinish :: Event t ()
  , editCancel :: Event t ()
  }

-- | Barra de botones que conmutan entre los layouts fijos, con los del modo
-- edición a su derecha ('editToggle', 'magnetToggle', y «Restablecer» y «Cancelar»
-- con 'confirmButton'). Sostiene el layout activo (arranca en 'raceOverview') y el
-- modo edición; cambiar de layout no saca de la edición. @unfit@ dice qué layouts
-- volvieron al de fábrica porque lo guardado no encajaba: cada uno lleva un
-- asterisco, y hay __una sola nota__ para todos, bajo el primero, abierta al cargar.
-- Pulsarla la cierra y pasar el ratón por un botón con asterisco la vuelve a
-- enseñar; asteriscos y nota se quitan al entrar en edición y vuelven si se cancela.
-- «Restablecer» pregunta si lo que se ve no es el de fábrica (@atFactoryNow@), y dice
-- cuántos grupos quita (@groupsNow@); «Cancelar», si algo cambió desde que se entró
-- (@movedNow@).
layoutSwitcher :: MonadWidget t m
               => (Layout -> Bool) -> Dynamic t Bool -> Dynamic t Bool -> Dynamic t Int
               -> m (Dynamic t Layout, Edit t)
layoutSwitcher unfit atFactoryNow movedNow groupsNow = divClass "layout-switcher" $ mdo
  let entering = () <$ ffilter id (updated editing)
  notedAtEntry <- holdDyn True (tag (current noted) entering)
  noted <- holdDyn True $ leftmost [False <$ entering, tag (current notedAtEntry) cancel]
  open  <- holdDyn True (False <$ leftmost [overviewClose, qualyClose, strategyClose])
  hover <- holdDyn False (leftmost [overviewHover, qualyHover, strategyHover])
  let shown = (&&) <$> noted <*> ((||) <$> open <*> hover)
      names = [name | (l, name) <- [(raceOverview, "Race Overview"), (qualy, "Qualy"), (strategy, "Strategy")], unfit l]
      holder = listToMaybe (filter unfit [raceOverview, qualy, strategy])
      item l = layoutButton noted shown (unfit l) (holder == Just l) (unfitNote names)
  (overviewClick, overviewHover, overviewClose) <- item raceOverview "Race Overview"
  (qualyClick, qualyHover, qualyClose)          <- item qualy "Qualy"
  (strategyClick, strategyHover, strategyClose) <- item strategy "Strategy"
  active <- holdDyn raceOverview $ leftmost
    [ raceOverview <$ overviewClick
    , qualy        <$ qualyClick
    , strategy     <$ strategyClick
    ]
  (editing, finish) <- editToggle cancel
  magnet <- magnetToggle editing cancel
  reset  <- confirmButton resetConfirm editing (not <$> atFactoryNow)
  cancel <- confirmButton cancelConfirm editing movedNow
  pure (active, Edit editing magnet reset finish cancel)
  where
    resetConfirm  = Confirm "reset" "↺ Restablecer" (resetQuestion <$> groupsNow)
    cancelConfirm = Confirm "cancel" "✗ Cancelar" (constDyn "¿Descartar los cambios?")

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

-- | Un botón de la edición que pregunta antes de actuar: su clase (@reset@ da
-- @confirm--reset@ y @reset-button@), su texto y su pregunta.
data Confirm t = Confirm
  { confirmKind     :: Text
  , confirmLabel    :: Text
  , confirmQuestion :: Dynamic t Text
  }

-- | Un botón solo visible en edición. Si @risky@ no lo es, actúa sin más; si lo es,
-- en su sitio pregunta «… Sí · No», y solo «Sí» actúa. Cualquier clic fuera de la
-- pregunta, y salir de la edición, cuentan como «No».
confirmButton :: MonadWidget t m => Confirm t -> Dynamic t Bool -> Dynamic t Bool -> m (Event t ())
confirmButton c editing risky = mdo
  (pressed, yes, no) <- elClass "span" ("confirm confirm--" <> confirmKind c) $ do
    (b, _) <- elDynAttr' "button" (buttonAttrs <$> editing <*> asking) $ text (confirmLabel c)
    (y, n) <- elDynAttr "span" (questionAttrs <$> editing <*> asking) $ do
      dynText (confirmQuestion c)
      (y, _) <- elClass' "button" "switcher__btn confirm__yes" $ text "Sí"
      (n, _) <- elClass' "button" "switcher__btn" $ text "No"
      pure (domEvent Click y, domEvent Click n)
    pure (domEvent Click b, y, n)
  outside <- clicksOutside (".confirm--" <> confirmKind c)
  asking <- holdDyn False $ leftmost
    [ True <$ gate (current risky) pressed
    , False <$ leftmost [yes, no, outside, () <$ ffilter not (updated editing)]
    ]
  pure (leftmost [gate (not <$> current risky) pressed, yes])
  where
    buttonAttrs shown a =
      "class" =: ("switcher__btn " <> confirmKind c <> "-button")
        <> (if shown && not a then mempty else "hidden" =: "")
    questionAttrs shown a =
      "class" =: "confirm__question"
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
-- cómo se dejó hasta recargar; @cancel@ lo devuelve a como estaba al entrar en la
-- edición. Encendido queda marcado y lleva ✓.
magnetToggle :: MonadWidget t m => Dynamic t Bool -> Event t () -> m (Dynamic t Bool)
magnetToggle editing cancel = mdo
  (e, _) <- elDynAttr' "button" (attrs <$> editing <*> magnet) $ dynText (label <$> magnet)
  atEntry <- holdDyn True (tag (current magnet) (ffilter id (updated editing)))
  magnet  <- holdDyn True $ leftmost
    [ tag (current atEntry) cancel
    , not <$> tag (current magnet) (domEvent Click e)
    ]
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
-- Devuelve si se edita y cuándo se termina con él; @cancel@ también saca de la
-- edición, pero no es terminar.
editToggle :: MonadWidget t m => Event t () -> m (Dynamic t Bool, Event t ())
editToggle cancel = mdo
  (e, _) <- elDynClass' "button" (toggleClass <$> editing) $
              dynText (toggleLabel <$> editing)
  let clicks = domEvent Click e
  editing <- holdDyn False $ leftmost [False <$ cancel, not <$> tag (current editing) clicks]
  pure (editing, gate (current editing) clicks)
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
-- __El refresco del directo, el aviso de que la capa se enseña, lo de Lap Comparison
-- al arrancar y lo que ponen «Restablecer» y «Cancelar» atraviesan las siete ramas y
-- cada uno lo usa una__, por la misma razón por la que el rectángulo no lo lleva el
-- widget: quien conoce el dato es quien monta, y darlo solo a la rama que lo pide
-- exigiría que el @case@ devolviera funciones de tipos distintos. Solo Lap Comparison
-- devuelve sus cambios; las demás, 'never'.
--
-- @extras@ es lo que los grupos le ponen a la tarjeta ('Widgets.Groups.cardExtras'): los
-- puntos, la fila bajo la cabecera y lo que destaca; lo que pide la fila se devuelve junto a
-- lo demás. Constructores no lo monta.
renderWidget :: MonadWidget t m
             => Dynamic t Blend -> Dynamic t (Maybe SessionKey) -> LiveView t -> Event t () -> CardControl -> Event t CardControl
             -> CardExtras t m (Event t GroupEdit) -> WidgetConfig -> m (Event t CardControl, Event t GroupEdit)
renderWidget blend session live revealed control put extras wc = case widgetType wc of
  LiveTiming       -> (,) never <$> liveTimingWidget session live extras
  LapComparison    -> comparisonWidget blend session live revealed control put extras
  TyreStrategy     -> (,) never <$> tyreStrategyWidget session live extras
  HistoricalStats  -> (,) never <$> driverStatsWidget session extras
  ConstructorStats -> (never, never) <$ constructorStatsWidget session
  Custom           -> (never, never) <$ placeholderWidget "Custom"

-- | Widget aún no disponible: recuadro con etiqueta del tipo.
placeholderWidget :: DomBuilder t m => T.Text -> m ()
placeholderWidget name = divClass "widget widget--placeholder" $ do
  divClass "widget__head" $ el "h2" $ text name
  elClass "p" "status status--placeholder" $ text "Widget no disponible"
