{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}

-- | Widget de Comparación de Vueltas (categoría LapComparison).
--
-- Consume @GET \/api\/comparison@ en runtime vía 'Client.fetchJson' +
-- 'Common.Route.comparisonPathFor' al arrancar, al elegir coches y al pedir trazas
-- (relativos, misma-origen), con los tres estados del fetch
-- ('Loading' \/ 'Failed' \/ 'Loaded') y sin datos dummy locales, igual que
-- 'Widgets.LiveTiming' e 'Widgets.Historical'.
--
-- __Es el primer widget del repo que pinta una serie y no una tabla.__ El tipo 1 pinta
-- los coches de 'Common.Types.LapComparison' (el primero es la referencia) con la base
-- que elige «Δ contra»: una curva por coche que no es la base, una al frente y las
-- demás tenues, y detrás lo que suman los grupos ('Common.Comparison.curvesWith'). Las trazas y el directo pintan el par de
-- los dos primeros ('Common.Comparison.pairWith').
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
-- Los dos switchers de 'Widgets.Historical' filtran __en cliente__ sobre datos ya
-- recibidos
-- (2026-08-01); aquí no se puede, porque la comparación de otros dos coches
-- sencillamente no está en la respuesta actual. De ahí las dos cosas nuevas:
-- un 'Event' de URL que nace de elegir un coche y un estado de recarga que __no borra__
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

import           Client                        (fetchJson, fetchJsonSourcedWith,
                                                fetchJsonWith, stillFor)
import           Common.Account                (Foot (..), Notice (..),
                                                accountFoot, cardNotice,
                                                cutNotice, loginCommand,
                                                noLapsNotice)
import           Common.Blend                  (Blend, Mark (..), Overlay (..),
                                                Point, blendOverlay, lineWidth,
                                                pointsAttr, toPixels)
import           Common.Chart                  (SectorPace (..),
                                                SectorSpan (..),
                                                axisPointsAmong, axisTicks,
                                                axisZeroY, chartHeight,
                                                chartWidth, frontierCells,
                                                frontierCellsAt, sectorSpans)
import           Common.Comparison             (Axis, Baseline (..),
                                                ChartType (..), Curve (..),
                                                LapChoice (..), LapPick (..),
                                                Layer (..), LiveCard (..),
                                                LiveEntry (..), Pair (..),
                                                WithGroups (..), addCar,
                                                addedCars, addedLaps,
                                                axesInOrder, axisFromKey,
                                                axisKey, axisLabel, axisNotice,
                                                axisValues, baselineFromKey,
                                                baselineKey, baselineLabel,
                                                baselineRole, baselinesInOrder,
                                                chartTypeFromKey, chartTypeKey,
                                                chartTypeLabel, chartTypeReady,
                                                chartTypeTraces,
                                                chartTypesInOrder, curveKey,
                                                curvesWith, defaultAxis,
                                                defaultChartType, deltaFormula,
                                                endedNotice, keepCars,
                                                lapButtons, lapChoiceFromKey,
                                                lapChoiceKey, lapPicks,
                                                lapShown, leadingPair,
                                                liveCardRows, liveCardStep,
                                                liveLapLines,
                                                liveMissingReference, maxCars,
                                                missingReference, noneHasLap,
                                                pairWith, pickReference, removeCar,
                                                withGroups)
import           Common.ComparisonCard         (CardControl (..),
                                                CardLayout (..), ChartFirst (..),
                                                ChartMode, chartFirstAreas,
                                                chartFirstFor, stackedLayout,
                                                Side (..), axisColumnWidth,
                                                cardLayout, curveInset,
                                                insideAxisLabels, modeEnabled,
                                                modeFromKey, modeKey,
                                                modeOption, modesInOrder,
                                                otherSide, rowTitle, shownMode,
                                                showsNames, showsValues,
                                                tracesInset, valueHeight,
                                                valuesFitMeasured, vsBeside)
import           Common.Format                 (formatDelta, formatFixed)
import           Common.Origin                 (Sourced (..))
import           Common.Pilots                 (Inks (..), inksOr)
import           Common.Route                  (comparisonPathFor,
                                                driverCodesParam,
                                                driversListParam,
                                                driversPathFor, f1tvPath)
import           Common.Session                (SessionKey, notFoundNotice,
                                                notRunNotice, sessionQuery)
import           Common.Shown                  (Fetched (..))
import           Common.Traces                 (Channel, TraceLayout (..),
                                                TracePiece (..), TraceRows (..),
                                                axisEnd, axisEndLabel,
                                                boundaryXs, channelCaption,
                                                channelHeight, channelName,
                                                channelRange, channelTop,
                                                channelsInOrder, channelsSpan,
                                                frontierXs, pieceFlex,
                                                readSamples, samplesMax,
                                                samplesMin, samplesStart,
                                                samplesStep, spanPiece,
                                                toggleChannel, traceChannels,
                                                traceLayout, traceVertices,
                                                traceXs, tracesWidth, xPercent)
import           Common.Types                  (ComparisonEntry (..),
                                                DriverEntry (..),
                                                LapComparison (..),
                                                TelemetryGap (..))
import           Control.Monad                 (forM, forM_, join, unless, when)
import           Control.Monad.IO.Class        (liftIO)
import           Data.List                     (find)
import           Data.Map                      (Map)
import qualified Data.Map                      as Map
import           Data.Maybe                    (fromMaybe, isJust, isNothing,
                                                listToMaybe)
import           Data.Text                     (Text)
import qualified Data.Text                     as T
import           Data.Time.Clock.POSIX         (utcTimeToPOSIXSeconds)
import           Data.Unique                   (hashUnique, newUnique)
import qualified GHCJS.DOM                     as DOM (currentWindowUnchecked)
import qualified GHCJS.DOM.DOMRectReadOnly     as DOM (getHeight, getWidth)
import qualified GHCJS.DOM.Element             as DOM (getBoundingClientRect,
                                                       getClientHeight)
import qualified GHCJS.DOM.EventM              as DOM (on)
import qualified GHCJS.DOM.GlobalEventHandlers as DOM (resize)
import qualified GHCJS.DOM.HTMLElement         as DOM (getOffsetHeight,
                                                       getOffsetWidth)
import qualified GHCJS.DOM.ParentNode          as DOM (querySelector)
import qualified GHCJS.DOM.Types               as DOM (Element (..),
                                                       HTMLElement (..),
                                                       liftJSM, uncheckedCastTo)
import qualified Language.Javascript.JSaddle   as JS
import           Reflex.Dom
import           Widgets.Card                  (CardExtras (..))
import           Widgets.Comparison.Helper     (CState (..), Item (..),
                                                Refresh (..), View (..),
                                                canvasDrawn, carAt, driverLabel,
                                                dueGap, edgeNotes, gridFor,
                                                groupLaps, indexedGrid,
                                                leftOutLabel, liveEntriesFor,
                                                liveFor, liveInput, markedRule,
                                                noLapNote, notRunOf, positionOf,
                                                refreshOf, rowHeightNow,
                                                rowItems, seriesOf,
                                                shownComparison, shownGap,
                                                shownItemsOf, shownState, step)
import           Widgets.Live                  (LiveView (..), liveBadge)
import           Widgets.Live.Helper           (indicatorOf)

-- | Comparación de la vuelta rápida de dos coches: la tabla de mando (selectores y
-- los dos pilotos con su tiempo), la gráfica del delta acumulado y la leyenda al
-- pie, a todo el ancho.
--
-- La tarjeta se reparte según su ancho medido ('Common.ComparisonCard.cardLayout'):
-- dos columnas, con la tabla de mando en el lado que elige «⇄», o apilada. Hasta la
-- primera medida se pinta apilada. Con una sola gráfica que no es la velocidad
-- ('Common.ComparisonCard.chartFirstFor'), apilada y en la rejilla del acomodo
-- ('mainAttrs'), con los tiempos de todos los elegidos.
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
--
-- __En directo__ ('Common.Comparison.LiveCard') el tipo 1 se arma en la página con el
-- directo retrasado que llega por @live@: los pilotos del directo, la más rápida de
-- cada uno, el «Live» y, al acabar la sesión, lo último con su aviso. Los demás tipos
-- siguen con FastF1.
--
-- La cuenta de F1TV se pide a @\/api\/f1tv@ con cada comparación y cada minuto; con la
-- procedencia de la comparación da la línea del pie y el aviso de encima de la gráfica
-- ('Common.Account'). Con trazas y la telemetría incompleta, el aviso lo dice, y la
-- comparación se vuelve a pedir una vez, el primer minuto después de su hora ('dueGap').
--
-- El lado de la tabla de mando, la banda, el modo elegido, la regla de la vuelta y las
-- gráficas de las trazas arrancan en @start@, y @put@ los pone como trae
-- ('Common.ComparisonCard.CardControl'). Devuelve cada cambio de cualquiera de ellos,
-- también el de @put@. Las curvas se mezclan con
-- @blend@, la que se elige en ☰. De lo que quien la monta le pone dentro
-- ('Widgets.Card.CardExtras') usa lo que va junto al título y bajo la cabecera, y lo que
-- devuelve esto último va junto a esos cambios.
comparisonWidget :: MonadWidget t m
                 => Dynamic t Blend -> Dynamic t (Maybe SessionKey) -> LiveView t -> Event t () -> CardControl
                 -> Event t CardControl -> CardExtras t m a -> m (Event t CardControl, a)
comparisonWidget blend session live revealed start put extras = mdo
  (root, (card, (userMode, state, view, side, band, rule, shownCharts, out))) <-
    elClass' "div" "widget widget--comparison" $ elClass' "div" "comparison__card" $ mdo
      (swap, ty, (axis, frontiers, samples, charts), ruleClicks) <- divClass "widget__head" $ do
        el "h2" $ text "Lap Comparison"
        cardBeside extras
        t  <- typeSelect
        rc <- ruleButtons buttons marked
        tc <- traceControls t (ccCharts start) (ccCharts <$> put)
        elDynAttr "span" (badgeAttrs <$> (liveFor <$> liveCard <*> t)) $
          liveBadge (lvDelay live) (indicatorOf <$> (isJust <$> session) <*> lvPoll live)
        s  <- swapButton (clStacked <$> layout)
        pure (s, t, tc, rc)
      underOut <- cardUnder extras
      side    <- foldDyn ($) (ccSide start) (leftmost [const . ccSide <$> put, otherSide <$ swap])
      pb      <- getPostBuild
      gridRsp <- fetchJsonWith ((\s -> (s, driversPathFor (sessionQuery s))) <$> leftmost [newSession, tag (current session) pb])
      fastGrid <- holdDyn [] (leftmost [[] <$ newSession, fromMaybe [] <$> stillFor (current session) gridRsp])
      grid    <- holdUniqDyn (gridFor <$> liveData <*> fastGrid)
      (((((userCars, livePicked), chosenCars, chosenE), pickE), rowClicks), (b, frontPick)) <-
        elDynAttr "div" (mainAttrs <$> chartFirst <*> chosenCars <*> lapRows) $ do
          inside <- elDynAttr "div" (hiddenIf <$> notRun <*> (bodyAttrs <$> side <*> layout)) $ do
            r <- elDynAttr "div" (controlAttrs <$> layout) $ do
              r' <- carSelector grid (shownComparison <$> stFast) (addedCars <$> current groupsNow) (noLapNote <$> liveEntries <*> st)
                      (isJust <$> liveData) ((leadingPair . snd =<<) <$> liveData) (vsNextTo <$> layout) (isJust <$> chartFirst)
                      (modeSelect (ccMode start) fits shown)
              p  <- switchHold never =<< dyn (controlState <$> liveEntries <*> picks <*> lapRows <*> st)
              pure (r', p)
            clicks <- divClass "comparison__plot" $
              switchHold never =<< dyn
                ( plotView (dyn_ (overlayFor <$> liveCard <*> liveEntries <*> refresh <*> st) >> dyn_ (noticeView <$> notice <*> cut))
                           (\none status -> dyn_ (insteadView status none <$> noLaps <*> notice <*> cut))
                    <$> ((\c s -> RowMode c s band) <$> chosen <*> shown) <*> layout
                    <*> (otherSide <$> side) <*> v <*> liveEntries <*> otherLaps <*> blend <*> st )
            pure (r, clicks)
          dyn_ (notRunView <$> notRun)
          lg <- legendRow blend ty axis notRun front ((,,,) <$> groupsNow <*> shownItems <*> otherLaps <*> viewed) st
          pure (inside, lg)
      band    <- foldDyn ($) (ccBand start) (leftmost [const . ccBand <$> put, not <$ rowClicks])
      front   <- holdDyn Nothing (Just <$> frontPick)
      cars    <- holdUniqDyn (firstTwo <$> chosenCars)
      groupPicks <- holdUniqDyn (cardPicks extras)
      viewed  <- holdUniqDyn (fst <$> cardSessions extras)
      lapsWanted <- holdUniqDyn (addedLaps <$> groupsNow)
      fastLaps <- fmap join . holdDyn (constDyn []) =<< dyn (fetchLaps <$> lapsWanted)
      dyn_ (footView <$> foot)
      wanted  <- holdUniqDyn ((\t n -> if chartTypeTraces t then n else 0) <$> ty <*> samples)
      drivers <- holdDyn Nothing (leftmost [Nothing <$ newSession, Just <$> leftmost [carsAsk, livePicked]])
      let groupsNow = withGroups <$> grid <*> chosenCars <*> groupPicks
          -- Las vueltas de otras sesiones, solo con FastF1: el directo sigue con dos.
          otherLaps = (\l ls -> if isJust l then [] else ls) <$> liveEntries <*> fastLaps
          shownItems = shownItemsOf <$> viewed <*> groupsNow <*> otherLaps <*> st
          lapRows    = rowItems <$> ty <*> (isJust <$> chartFirst) <*> shownItems
          askFor    = driversListParam . wgCars
          offline   = isNothing <$> current liveData
          -- Se pide lo que elige el usuario y, cuando cambian los grupos, la parrilla o lo
          -- pintado, lo que falta para que lo pintado sea la tarjeta más sus grupos. Nunca
          -- otra vez lo último pedido, que corta el bucle cuando la respuesta es el ejemplo,
          -- ni sin nada pintado: tras cambiar de sesión manda su petición.
          userAsk   = attachWithMaybe (\(gr, h) cs -> askFor (withGroups gr cs h)) ((,) <$> current grid <*> current groupPicks) userCars
          shownAsk  = (driversListParam . map ceCar . lcEntries =<<) . shownComparison <$> stFast
          regrouped = tagPromptlyDyn ((,) <$> (askFor <$> groupsNow) <*> shownAsk)
                        (leftmost [() <$ updated groupPicks, () <$ updated grid, () <$ updated stFast])
          syncAsk   = gate offline $
                        attachWithMaybe (\lastAsk (want, have) -> if isJust have && want /= have && want /= lastAsk then want else Nothing)
                          (current drivers) regrouped
          carsAsk   = leftmost [userAsk, syncAsk]
          v       = View <$> ty <*> b <*> axis <*> frontiers <*> front <*> charts
          -- Cada petición va con la sesión para la que sale: la de otra se tira al volver.
          request = leftmost
            [ attachWith (\n s -> (s, pathFor s Nothing n)) (current wanted) newSession
            , (\(s, n) -> (s, pathFor s Nothing n)) <$> tag ((,) <$> current session <*> current wanted) pb
            , attachWith (\(s, n) d -> (s, pathFor s (Just d) n)) ((,) <$> current session <*> current wanted) carsAsk
            , attachWith (\(s, d) n -> (s, pathFor s d n)) ((,) <$> current session <*> current drivers) (ffilter (> 0) (updated wanted))
            , attachWith (\(s, d, n) _ -> (s, pathFor s d n)) ((,,) <$> current session <*> current drivers <*> current wanted) again
            ]
          pathFor s  = comparisonPathFor (sessionQuery s)
          newSession = updated session
          liveData     = liveCardRows <$> (liveFor <$> liveCard <*> ty)
          shownSession = fmap fst <$> liveData
          marked       = markedRule <$> shownSession <*> rule
          picks        = lapPicks <$> shownSession <*> rule <*> excs
          st           = shownState <$> liveEntries <*> stFast
      notRun      <- holdUniqDyn (notRunOf . isJust <$> session <*> lvWait live <*> lvPoll live)
      buttons     <- holdUniqDyn (lapButtons <$> shownSession)
      liveEntries <- holdUniqDyn (liveEntriesFor <$> liveData <*> cars <*> rule <*> excs)
      rule        <- holdDyn (ccLap start) (leftmost [ccLap <$> put, ruleClicks])
      excs        <- foldDyn ($) (Nothing, Nothing) $ leftmost
                       [ const (Nothing, Nothing) <$ leftmost [() <$ ruleClicks, () <$ put, () <$ newSession]
                       , attachWith clearChanged (current cars) (updated cars)
                       , attachWith setPick (current marked) pickE
                       ]
      resp    <- stillFor (current session) <$> fetchJsonSourcedWith request
      let fast = fmap srcValue <$> resp
      refresh <- holdDyn InFlight (leftmost [InFlight <$ request, refreshOf <$> fast])
      stFast  <- foldDyn ($) Loading (leftmost [const Loading <$ newSession, step <$> fast])
      shownAt <- holdDyn (Nothing, Nothing) $
                   leftmost [(Nothing, Nothing) <$ newSession, (\s -> (srcOrigin s, srcFetchedAt s)) <$> fmapMaybe got resp]
      minute  <- tickLossyFromPostBuildTime 60
      asked   <- fetchJson (f1tvPath <$ leftmost [() <$ request, () <$ minute])
      account <- holdDyn Nothing asked
      zone    <- browserZone
      tried   <- holdDyn Nothing (leftmost [Nothing <$ newSession, Just . tgRetryAt <$> again])
      let onLive = isJust <$> liveData
          foot   = accountFoot zone <$> onLive <*> account
          gap    = shownGap <$> ty <*> stFast
          again  = attachWithMaybe dueGap ((,) <$> current gap <*> current tried) (tickMinute <$> minute)
          notice = (\l a (o, at) g -> cardNotice zone l a o at g) <$> onLive <*> account <*> shownAt <*> gap
          noLaps = noLapsNotice zone <$> onLive <*> account
          cut    = cutNotice <$> onLive <*> ((lcCut =<<) . shownComparison <$> stFast)
      pure (chosenE, st, v, side, band, rule, charts, underOut)
  liveIn   <- holdUniqDyn (liveInput <$> lvWait live <*> lvPoll live)
  first    <- sample (current liveIn)
  liveCard <- holdUniqDyn
                =<< foldDyn ($) (maybe Offline (\(src, s, r) -> liveCardStep src s r Offline) first)
                      (leftmost [ const Offline <$ updated session
                                , (\(src, s, r) -> liveCardStep src s r) <$> fmapMaybe id (updated liveIn) ])
  size    <- cardSize root card (current ((,) <$> rowNow <*> drawn)) changed
  stacked <- holdUniqDyn (clStacked <$> layout)
  chosen  <- holdDyn (ccMode start) (leftmost [ccMode <$> put, userMode])
  shown   <- holdUniqDyn (shownMode <$> fits <*> chosen)
  chartFirst <- holdUniqDyn (chartFirstFor <$> inner <*> (traceChannels <$> (vType <$> view) <*> (vCharts <$> view)))
  let inner    = maybe 0 fst <$> size
      -- Con el acomodo, apilada a cualquier ancho.
      layout   = (\w f -> maybe (cardLayout w) (const (stackedLayout w)) f) <$> inner <*> chartFirst
      fits     = maybe True snd <$> size
      rowNow   = rowHeightNow <$> shown <*> view <*> state
      drawn    = canvasDrawn <$> view <*> state
      changed  = leftmost
                   [ () <$ updated shown, () <$ updated state, () <$ updated view
                   , () <$ updated stacked, revealed ]
  pure (updated (control <$> side <*> band <*> chosen <*> rule <*> shownCharts), out)
  where
    control s b m l cs = CardControl {ccSide = s, ccBand = b, ccMode = m, ccLap = l, ccCharts = cs}
    -- El directo sigue con dos: la referencia y el primero de los demás.
    firstTwo cs = (listToMaybe cs, listToMaybe (drop 1 cs))
    controlState :: MonadWidget t m => Maybe [LiveEntry] -> [LapPick] -> [Item] -> CState -> m (Event t (Int, LapChoice))
    controlState les ps items (Loaded _) = lapHeader les ps items
    controlState _ _ _ _                 = pure never
    got (Got x) = Just x
    got _       = Nothing
    -- Un piloto que cambia pierde su excepción.
    clearChanged (r0, o0) (r1, o1) (a, b) = (if r0 == r1 then a else Nothing, if o0 == o1 then b else Nothing)
    -- La que coincide con la regla no es excepción.
    setPick r (i, c) (a, b) =
      let e = if c == r then Nothing else Just c
       in if i == 0 then (e, b) else (a, e)

-- | La vuelta de los pilotos de cada sesión que suman los grupos, una petición por sesión y
-- por siglas ('Common.Comparison.addedLaps'), en cuanto se monta; da las que llegan
-- ('groupLaps'), en su orden.
fetchLaps :: MonadWidget t m => [(SessionKey, [Text])] -> m (Dynamic t [(SessionKey, ComparisonEntry)])
fetchLaps ls = do
  pb  <- getPostBuild
  got <- forM ls $ \(k, codes) -> case driverCodesParam codes of
    Nothing -> pure (constDyn [])
    Just d  -> do
      r <- fetchJsonSourcedWith (((), comparisonPathFor (sessionQuery (Just k)) (Just d) 0) <$ pb)
      holdDyn [] (groupLaps k codes . snd <$> r)
  pure (concat <$> sequence got)

notRunView :: DomBuilder t m => Bool -> m ()
notRunView True  = elClass "p" "status status--empty" $ text notRunNotice
notRunView False = blank

-- | Los atributos con @hidden@ añadido si se cumple.
hiddenIf :: Bool -> Map Text Text -> Map Text Text
hiddenIf True  = Map.insert "hidden" ""
hiddenIf False = id

-- | El envoltorio del cuerpo y de la leyenda: sin acomodo la hoja de estilos lo deja
-- sin caja; con él es la rejilla, con las zonas de 'chartFirstAreas' para los coches
-- elegidos —«+» mientras quepa otro— y las filas de tiempo.
mainAttrs :: Maybe ChartFirst -> [Text] -> [Item] -> Map Text Text
mainAttrs Nothing _ _ = "class" =: "comparison__main"
mainAttrs (Just f) cars items =
  ("class" =: ("comparison__main comparison__main--first " <> modifier f))
    <> ("style" =: ("grid-template-areas: " <> T.unwords (map quoted areas)))
  where
    n      = length cars
    areas  = chartFirstAreas f n (n < maxCars) (length items)
    quoted r = "\"" <> r <> "\""
    modifier FirstSide    = "comparison__main--side"
    modifier FirstStacked = "comparison__main--below"

-- | El envoltorio del «Live»: a la vista mientras se sigue o se congela el directo;
-- oculto sin soltar su sitio al acabar la sesión; fuera con FastF1.
badgeAttrs :: LiveCard -> Map Text Text
badgeAttrs Offline     = "class" =: "comparison__live" <> "hidden" =: ""
badgeAttrs (Ended _ _) = "class" =: "comparison__live" <> "style" =: "visibility: hidden"
badgeAttrs _           = "class" =: "comparison__live"

-- | «Vuelta [más rápida | última | Q1…]»: un botón por vuelta ('Common.Comparison.lapButtons'),
-- marcado el de @marked@; los apagados dicen «solo en directo». Devuelve la pulsada.
ruleButtons :: MonadWidget t m => Dynamic t [(LapChoice, Text, Bool)] -> Dynamic t LapChoice -> m (Event t LapChoice)
ruleButtons buttons marked = divClass "comparison__rule" $ do
  text "Vuelta"
  clicks <- elClass "span" "comparison__rule-seg" $ dyn $ ffor buttons $ \bs ->
    fmap leftmost $ forM bs $ \(c, label, enabled) -> do
      (e, _) <- elDynAttr' "button" (attrs c enabled <$> marked) $ text label
      pure (c <$ domEvent Click e)
  switchHold never clicks
  where
    attrs c enabled m =
      ("type" =: "button")
        <> ("class" =: ("switcher__btn" <> if c == m then " comparison__rule-btn--on" else ""))
        <> (if enabled then mempty else "disabled" =: "disabled" <> "title" =: "solo en directo")

-- | El minuto (desde 1970, UTC) de un tic, el que lee 'Widgets.Comparison.Helper.dueGap'.
tickMinute :: TickInfo -> Int
tickMinute tick = floor (utcTimeToPOSIXSeconds (_tickInfo_lastUTC tick) / 60)

-- | La zona del navegador en los minutos de @getTimezoneOffset@, leída una vez al
-- montar: el @time@ del backend JavaScript de GHC no la sabe leer.
browserZone :: MonadWidget t m => m Int
browserZone = round <$> DOM.liftJSM (JS.eval ("new Date().getTimezoneOffset()" :: Text) >>= JS.valToNumber)

-- | El aviso de la cuenta o de la procedencia, arriba del lienzo ('Common.Account.cardNotice'),
-- y debajo, en el mismo recuadro, la línea del archivo cortado ('Common.Account.cutNotice').
noticeView :: MonadWidget t m => Maybe Notice -> Maybe Text -> m ()
noticeView Nothing Nothing = blank
noticeView notice cut =
  elClass "div" "status status--stale comparison__notice" $ do
    forM_ notice $ \n -> do
      el "div" $ text (noticeText n)
      when (noticeLogin n) $ el "div" $ do
        text "Inicia sesión en una terminal con "
        el "code" $ text loginCommand
        text " "
        (b, _) <- elAttr' "button" ("type" =: "button" <> "class" =: "comparison__copy") $ text "Copiar"
        performEvent_ (DOM.liftJSM (() <$ JS.eval (copyScript loginCommand)) <$ domEvent Click b)
        text "."
    forM_ cut $ elClass "div" "comparison__cut" . text

-- | Lo que va en lugar de la gráfica, fuera del lienzo: el aviso de la tarjeta
-- ('noticeView') encima del estado; si ninguno de los elegidos tiene vuelta y hay aviso
-- de la cuenta ('Common.Account.noLapsNotice'), solo ese, sin el estado (2026-11-25 (k)).
insteadView :: MonadWidget t m => m () -> Bool -> Maybe Notice -> Maybe Notice -> Maybe Text -> m ()
insteadView status none noLaps notice cut = case noLaps of
  Just n | none -> noticeView (Just n) cut
  _             -> noticeView notice cut >> status

-- | Copia un texto sin comillas ni barras al portapapeles. Fuera de un contexto seguro
-- (la página abierta por la IP de la red y no por @localhost@) el navegador no da
-- @navigator.clipboard@, y se copia seleccionando un @textarea@ oculto.
copyScript :: Text -> Text
copyScript t =
  "(function(t){if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(t);}"
    <> "else{var a=document.createElement('textarea');a.value=t;a.style.position='fixed';a.style.opacity='0';"
    <> "document.body.appendChild(a);a.select();document.execCommand('copy');a.remove();}})('" <> t <> "')"

-- | La línea de la cuenta, en su fila debajo de la leyenda ('Common.Account.accountFoot').
footView :: DomBuilder t m => Maybe Foot -> m ()
footView Nothing              = blank
footView (Just (FootQuiet t)) = elClass "p" "comparison__account" $ text t
footView (Just (FootWarn t))  = elClass "p" "comparison__account comparison__account--warn" $ text t

-- | Lo que va encima de la gráfica: en directo, el aviso de la sesión acabada; con
-- FastF1, el de la petición ('banner').
overlayFor :: DomBuilder t m => LiveCard -> Maybe [LiveEntry] -> Refresh -> CState -> m ()
overlayFor (Ended _ _) (Just _) _ _ = elClass "p" "status status--stale" $ text endedNotice
overlayFor _ (Just _) _ _           = blank
overlayFor _ Nothing r s            = banner (r, s)

-- | La fila de la leyenda: «Δ contra [Referencia ▾]» y la leyenda como un bloque,
-- repartidos con @space-evenly@ (2026-10-01 (g)), y la base elegida. El desplegable
-- va fuera del 'dyn_', que lo devolvería a «Referencia» en cada respuesta; la fila
-- se esconde mientras no hay comparación.
--
-- En los tipos con trazas, debajo va siempre el aviso de su eje
-- ('Common.Comparison.axisNotice', 2026-09-30 (a)). Devuelve también las siglas de
-- la curva que se pulsa en la leyenda del tipo 1, la que va al frente ('Common.Comparison.curveKey').
legendRow
  :: MonadWidget t m
  => Dynamic t Blend -> Dynamic t ChartType -> Dynamic t Axis -> Dynamic t Bool -> Dynamic t (Maybe Text)
  -> Dynamic t (WithGroups, [Item], [(SessionKey, ComparisonEntry)], Maybe SessionKey) -> Dynamic t CState
  -> m (Dynamic t Baseline, Event t Text)
legendRow blend ty axis notRun front groups st = do
  (b, picked) <- elDynAttr "div" (hiddenIf <$> notRun <*> (attrs <$> st)) $ do
    b' <- elClass "span" "comparison__against" $ do
      elClass "span" "comparison__against-label" $ text "Δ contra "
      baselineSelect
    p <- elClass "span" "comparison__keys" $
      switchHold never =<< dyn (legendState <$> blend <*> ty <*> b' <*> front <*> groups <*> st)
    pure (b', p)
  dyn_ (note <$> ty <*> axis <*> notRun <*> st)
  pure (b, picked)
  where
    attrs (Loaded _) = "class" =: "comparison__legend"
    attrs _          = ("class" =: "comparison__legend") <> ("hidden" =: "")
    legendState bl t b f (g, items, laps, viewed) (Loaded c)
      | chartTypeTraces t = never <$ traceLegend bl b c
      | otherwise         = legend bl b f g items laps viewed c
    legendState _ _ _ _ _ _ = pure never
    note t a False (Loaded _)
      | chartTypeTraces t = elClass "p" "comparison__note" $ text (axisNotice a)
    note _ _ _ _ = blank

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
-- (2026-09-30 (a)): el eje, las muestras, las fronteras y «Gráficas ▾» ('chartsMenu').
-- Abren en Tiempo, 100, con fronteras y con las gráficas de @charts@. Van siempre
-- montados —escondidos en los otros tipos— para que no vuelvan a su valor inicial al
-- cambiar de tipo.
--
-- Devuelve el eje, si van las fronteras, las muestras que se piden —mientras se
-- arrastra el deslizable, como mucho una vez cada 200 ms y la última al soltar
-- (2026-10-01 (e)); el número de al lado cambia al momento— y las gráficas marcadas.
traceControls
  :: MonadWidget t m
  => Dynamic t ChartType -> [Channel] -> Event t [Channel]
  -> m (Dynamic t Axis, Dynamic t Bool, Dynamic t Int, Dynamic t [Channel])
traceControls ty charts putCharts =
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
    chosen  <- chartsMenu ty charts putCharts
    samples <- holdDyn samplesStart picked
    pure ( fromMaybe defaultAxis . axisFromKey <$> _selectElement_value axisSel
         , _inputElement_checked box
         , samples
         , chosen )
  where
    attrs t
      | chartTypeTraces t = "class" =: "comparison__trace-controls"
      | otherwise         = ("class" =: "comparison__trace-controls") <> ("hidden" =: "")

-- | «Gráficas ▾» (2026-11-23 (m)): un botón que abre, flotando, una casilla por gráfica,
-- como «Columnas ▾» de Live Timing y con su aspecto. Abre con @start@ y vuelve a lo que
-- traiga @put@. La última marcada se apaga, para que no se desmarque
-- ('Common.Traces.toggleChannel'). Se cierra con el botón, pulsando fuera o al cambiar
-- de tipo. Devuelve las marcadas, de arriba abajo.
chartsMenu
  :: MonadWidget t m => Dynamic t ChartType -> [Channel] -> Event t [Channel] -> m (Dynamic t [Channel])
chartsMenu ty start put = elClass "span" "comparison__charts" $ mdo
  (btn, _) <- elAttr' "button" ("type" =: "button" <> "class" =: "live-timing__columns-btn") $
    text "Gráficas ▾"
  backdrop <- dyn (layer <$> open)
  outside  <- switchHold never backdrop
  open     <- foldDyn ($) False $
    leftmost [not <$ domEvent Click btn, const False <$ outside, const False <$ updated ty]
  clicks   <- elDynAttr "div" (panelAttrs <$> open) $
    leftmost <$> mapM (box chosen) channelsInOrder
  chosen   <- foldDyn ($) start (leftmost [const <$> put, toggleChannel <$> clicks])
  pure chosen
  where
    layer True = do
      (e, _) <- elClass' "div" "live-timing__backdrop" blank
      pure (domEvent Click e)
    layer False = pure never
    panelAttrs True  = "class" =: "live-timing__columns-panel"
    panelAttrs False = "class" =: "live-timing__columns-panel" <> "hidden" =: ""
    locked :: [Channel] -> Channel -> Maybe Text
    locked cs c = if cs == [c] then Just "disabled" else Nothing
    box chosenNow c = elClass "label" "live-timing__column" $ do
      input <- inputElement $
        def
          & inputElementConfig_initialChecked .~ (c `elem` start)
          & inputElementConfig_setChecked .~ ((c `elem`) <$> put)
          & initialAttributes .~ ("type" =: "checkbox" <> maybe mempty ("disabled" =:) (locked start c))
          & inputElementConfig_elementConfig . elementConfig_modifyAttributes
              .~ ((\cs -> "disabled" =: locked cs c) <$> updated chosenNow)
      text (channelName c)
      pure (c <$ _inputElement_checkedChange input)

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

-- | Lo que se mide de la tarjeta: su ancho por dentro, en px, y si caben las dos
-- líneas de la fila de fronteras sin que pida scroll
-- ('Common.ComparisonCard.valuesFitMeasured', con el lienzo sin crecer: se descuenta
-- lo que el navegador lo ha estirado). El 'Behavior' da el alto de la fila pintada y
-- el alto sin crecer del lienzo pintado ('canvasDrawn').
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
  -> m (Dynamic t (Maybe (Double, Bool)))
cardSize root card drawnNow changed = mdo
  mounted  <- delay 0 =<< getPostBuild
  win      <- DOM.liftJSM DOM.currentWindowUnchecked
  resized  <- wrapDomEvent win (`DOM.on` DOM.resize) (pure ())
  settled  <- delay 0 changed
  grown    <- sizeChanges [_element_raw root, _element_raw card]
  measured <- performEvent (measure <$> tag drawnNow (leftmost [mounted, resized, settled, grown, retry]))
  let zero = ffilter (\(w, _) -> w <= 0) measured
  tries    <- count zero
  retry    <- delay 0.2 (() <$ ffilter (< measureTries) (tag (current tries) zero))
  holdUniqDyn =<< holdDyn Nothing (Just <$> ffilter (\(w, _) -> w > 0) measured)
  where
    cardEl = DOM.uncheckedCastTo DOM.HTMLElement (_element_raw card)
    measure (row, base) = DOM.liftJSM $ do
      w       <- DOM.getOffsetWidth cardEl
      content <- DOM.getOffsetHeight cardEl
      client  <- DOM.getClientHeight (_element_raw root)
      canvas  <- DOM.querySelector cardEl (".comparison__canvas" :: Text)
      drawnH  <- maybe (pure 0) (\e -> DOM.getHeight =<< DOM.getBoundingClientRect e) canvas
      let extra = maybe 0 (\b -> max 0 (drawnH - b)) base
      pure (w, valuesFitMeasured client content (row + extra))

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

-- | Los coches que se comparan, de 1 a 5 (decisión 10 de
-- @docs/GapGraficasComparacion.md@ §6): la referencia en su desplegable y los demás
-- como etiquetas con su ✕ ('carTags') y «+ ▾» para añadir otro ('addSelect'). Devuelve
-- la lista que sale de cada cambio del usuario —con ella y los grupos compone la URL
-- 'comparisonWidget'— y la lista elegida, la referencia primero. Elegir de referencia a
-- uno de los demás los intercambia ('Common.Comparison.pickReference').
--
-- __La posición inicial del desplegable, 1, no es la selección de verdad:__ es lo que
-- se ve durante el instante que va del arranque a la primera respuesta. La lista que el
-- gráfico pinta la marca el prefill, y tiene que ser así porque
-- @Handler.Comparison.Helper.defaultDrivers@ son los coches @16@ y @1@ y su posición
-- depende de la parrilla.
--
-- El segundo argumento es la comparación de FastF1, de la que sale el prefill; el
-- tercero, los números que añaden los grupos ('Common.Comparison.addedCars'), que el
-- prefill no toma como elegidos; el cuarto, el tooltip de un coche sin barras; el
-- quinto, si la tarjeta va con el directo; el sexto, P1 y P2 del directo; el séptimo, si
-- el «VS» va a la derecha del desplegable ('vsNextTo'); el octavo, si los demás llevan
-- número y equipo ('carTags'). El último se pinta debajo, y su
-- resultado se devuelve con los coches.
--
-- __Cuando cambia la parrilla, siguen los mismos coches__ ('Common.Comparison.keepCars'):
-- el que no está pasa al primero libre. __En directo no hay prefill ni petición__: lo
-- elegido se pinta al momento y sale por el segundo evento, también al entrar en
-- directo. __Si se abre ya en directo__ —sin comparación de FastF1 todavía—, la lista
-- es P1 contra P2.
carSelector
  :: MonadWidget t m
  => Dynamic t [DriverEntry]
  -> Dynamic t (Maybe LapComparison)
  -> Behavior t [Text]
  -> Dynamic t (Text -> Maybe Text)
  -> Dynamic t Bool
  -> Dynamic t (Maybe (Text, Text))
  -> Dynamic t Bool
  -> Dynamic t Bool
  -> m a
  -> m ((Event t [Text], Event t Text), Dynamic t [Text], a)
carSelector grid shown fromGroups noLap liveOn leaders vsNext long beside = divClass "car-selector" $ mdo
  pb <- getPostBuild
  let indexed  = indexedGrid <$> grid
      labels   = Map.map driverLabel <$> indexed
      -- El prefill: los coches de los que habla el gráfico, en su orden, sin los que añaden los grupos.
      prefill  = gate (not <$> current liveOn)
                   (attachWithMaybe (\gs c -> filter (`notElem` gs) . map ceCar . lcEntries <$> c) fromGroups (updated shown))
      kept     = attachWith (\cs idx -> keepCars (map deNumber (Map.elems idx)) cs) (current chosen) (updated indexed)
      switched = leftmost [updated indexed, tag (current indexed) pb]
      opening  = attachWithMaybe openAt (current shown) (tagPromptlyDyn leaders switched)
      -- El desplegable de la referencia sigue a la lista cuando la cambia otra cosa que él
      -- mismo: lo que elige el usuario ya lo enseña, y seguirlo cerraría un ciclo sin 'hold'
      -- con su evento de cambio, que en 'dropdown' depende de 'setValue'.
      fromTags = attachWith (flip ($)) (current chosen) (leftmost [removeCar <$> removed, addCar <$> added])
      setRef   = attachPromptlyDynWithMaybe (\idx cs -> positionOf idx =<< listToMaybe cs) indexed
                   (leftmost [opening, kept, prefill, fromTags])
      refCar   = zipDynWith carAt indexed posRef
      edits    = leftmost [pickReference <$> attachWithMaybe carAt (current indexed) chRef, removeCar <$> removed, addCar <$> added]
      byUser   = attachWith (flip ($)) (current chosen) edits
  ((posRef, chRef), (removed, added)) <- elDynAttr "div" (pairAttrs <$> vsNext) $ do
    r <- carDropdown 1 labels setRef (carSelectAttrs <$> refCar <*> noLap)
    elClass "span" "car-selector__vs" $ text "vs"
    o <- divClass "car-selector__tags" $ do
      x <- switchHold never =<< dyn (carTags <$> long <*> indexed <*> (drop 1 <$> chosen) <*> noLap)
      p <- switchHold never =<< dyn (addSelect <$> indexed <*> chosen)
      pure (x, p)
    pure (r, o)
  chosen <- holdUniqDyn =<< holdDyn [] (leftmost [opening, kept, prefill, byUser])
  a <- divClass "comparison__actions" beside
  let chosenByUser = gate (not <$> current liveOn) byUser
      live = leftmost
        [ attachWithMaybe (\on c -> if on then Just c else Nothing) (current liveOn) (updated chosen)
        , tagPromptlyDyn chosen (ffilter id (updated liveOn))
        ]
  -- 'fmapMaybe' es lo que hace que una selección vacía o con algo que no es un número
  -- __no dispare nada__: un 'Nothing' que llegara a 'comparisonPathFor' daría el path
  -- __sin__ coches, la comparación por defecto presentada como la que se pidió.
  pure ((chosenByUser, fmapMaybe driversListParam live), chosen, a)
  where
    openAt Nothing (Just (p1, p2)) = Just [p1, p2]
    openAt _ _                     = Nothing

-- | Los coches elegidos tras la referencia, cada uno con sus siglas —con el primer
-- argumento, con número y equipo, como en el desplegable ('driverLabel')— y un ✕ que lo
-- quita; con uno solo no hay ✕ ('Common.Comparison.removeCar'). Un coche que sale sin
-- barras lleva el aviso de 'carSelectAttrs'. Devuelve el número del que se quita.
carTags :: MonadWidget t m => Bool -> Map Int DriverEntry -> [Text] -> (Text -> Maybe Text) -> m (Event t Text)
carTags long idx others noLap =
  fmap leftmost . forM others $ \car ->
    elAttr "span" (tagAttrs car) $ do
      elClass "span" "car-selector__tag-name" $ text (nameOf car)
      if length others > 1
        then do
          (x, _) <- elAttr' "button" (Map.fromList [("type", "button"), ("class", "car-selector__tag-x"), ("title", "Quitar")]) $ text "✕"
          pure (car <$ domEvent Click x)
        else pure never
  where
    nameOf car = maybe car (if long then driverLabel else deCode) (find ((== car) . deNumber) (Map.elems idx))
    tagAttrs car = case noLap car of
      Just note -> Map.fromList [("class", "car-selector__tag car-selector__tag--nolap"), ("title", note)]
      Nothing   -> Map.singleton "class" "car-selector__tag"

-- | «+ ▾»: el desplegable nativo de los coches de la parrilla que no están elegidos,
-- mientras quepa otro ('Common.Comparison.maxCars'). Devuelve el número del que se
-- elige; se vuelve a montar con cada cambio de la lista, y vuelve a «+».
addSelect :: MonadWidget t m => Map Int DriverEntry -> [Text] -> m (Event t Text)
addSelect idx cars
  | length cars >= maxCars || null free = pure never
  | otherwise = do
      let cfg = def
            & selectElementConfig_initialValue .~ ""
            & selectElementConfig_elementConfig . elementConfig_initialAttributes
                .~ Map.fromList [("class", "car-selector__select car-selector__add"), ("title", "Añadir un piloto")]
      (sel, _) <- selectElement cfg $ do
        elAttr "option" ("value" =: "") $ text "+"
        forM_ free $ \d -> elAttr "option" ("value" =: deNumber d) $ text (driverLabel d)
      pure (ffilter (not . T.null) (_selectElement_change sel))
  where
    free = [d | d <- Map.elems idx, deNumber d `notElem` cars]

-- | Un selector de coche: la posición inicial y las opciones, que __cambian__
-- cuando llega la parrilla sin remontar el @\<select\>@, así que no se pierde lo
-- que el usuario ya hubiera elegido.
--
-- El tercer argumento es el prefill, que sale de 'carSelector' y cierra el ciclo
-- del @mdo@ de 'comparisonWidget'. Da igual si llega antes que la parrilla:
-- 'dropdown' une la clave de @setValue@ a las opciones (2026-08-07).
--
-- La config se arma con lentes (@&@ y @.~@) y no con @def { ... }@, que aquí no
-- compila (@GHC-39999@, 2026-08-11 (b)). Devuelve la posición y, aparte, la que
-- elige el usuario.
carDropdown
  :: MonadWidget t m
  => Int
  -> Dynamic t (Map Int Text)
  -> Event t Int
  -> Dynamic t (Map Text Text)
  -> m (Dynamic t Int, Event t Int)
carDropdown initial options setPos attrs =
  fmap (\d -> (_dropdown_value d, _dropdown_change d)) . dropdown initial options $
    def
      &  dropdownConfig_attributes .~ attrs
      &  dropdownConfig_setValue   .~ setPos

-- | Atributos de un selector de coche: en amarillo y con su aviso como tooltip
-- ('noLapNote') mientras el coche que tiene elegido aparece sin barras en la
-- comparación que se pinta (2026-10-02).
carSelectAttrs :: Maybe Text -> (Text -> Maybe Text) -> Map Text Text
carSelectAttrs car noLap =
  case noLap =<< car of
    Just note ->
      Map.fromList [("class", "car-selector__select car-selector__select--nolap"), ("title", note)]
    Nothing -> Map.fromList [("class", "car-selector__select")]

-- | El desplegable de modos, nativo: arranca en @start@, enseña el modo que se ve,
-- apaga «Eje y valores» cuando la fila no cabe, y devuelve solo lo que elige el
-- usuario (el valor que pone el código no dispara nada).
modeSelect
  :: MonadWidget t m
  => ChartMode
  -> Dynamic t Bool
  -> Dynamic t ChartMode
  -> m (Event t ChartMode)
modeSelect start fits shown = do
  -- Las opciones reciben su @value@ después de montarse: escrito antes, no casa con
  -- ninguna y el desplegable queda vacío.
  mounted <- delay 0 =<< getPostBuild
  let cfg = def
        & selectElementConfig_initialValue .~ modeKey start
        & selectElementConfig_setValue .~ (modeKey <$> leftmost [updated shown, tag (current shown) mounted])
        & selectElementConfig_elementConfig . elementConfig_initialAttributes
            .~ ("class" =: "car-selector__select comparison__modes")
  (sel, _) <- selectElement cfg $ forM_ modesInOrder $ \m ->
    elDynAttr "option" (optionAttrs m <$> fits) $ dynText ((`modeOption` m) <$> fits)
  pure (fmapMaybe modeFromKey (_selectElement_change sel))
  where
    optionAttrs m f =
      ("value" =: modeKey m) <> if modeEnabled f m then mempty else "disabled" =: "disabled"

-- | Cada coche con su tiempo de vuelta, uno por fila y la referencia primero
-- (2026-11-21 (ad)). El tiempo llega ya formateado (@M:SS.mmm@) por el microservicio,
-- y un coche sin vuelta dice «sin vuelta» ('Common.Comparison.lapShown'). En directo,
-- el texto de cada coche es el suyo ('Common.Comparison.liveLapLines'). Tras el
-- tiempo, el desplegable corto de su vuelta ('Common.Comparison.LapPick'); devuelve la
-- que se elige en cada uno, por su posición (0, la referencia). Entre los dos primeros
-- va el «vs», que la hoja de estilos esconde en columna. Las filas son las de lo que se
-- pinta, en su orden ('Widgets.Comparison.Helper.shownItemsOf'); las que añaden los
-- grupos van tenues (2026-11-21 (ad)).
lapHeader
  :: MonadWidget t m => Maybe [LiveEntry] -> [LapPick] -> [Item] -> m (Event t (Int, LapChoice))
lapHeader les ps items = divClass "comparison__header" $ do
  picked <- forM (zip [0 ..] items) $ \(i, it) -> do
    when (i == 1) $ elClass "span" "comparison__vs" $ text "vs"
    let e = itEntry it
    fmap ((,) i) <$> lapLabel (itGroup it) (itHead it) (itCar it) (linesOf i e) (pickAt i)
  pure (leftmost picked)
  where
    linesOf i e = maybe (lapShown e, Nothing) liveLapLines (listToMaybe . drop i =<< les)
    pickAt i = listToMaybe (drop i ps)

-- | Un piloto, su coche y su tiempo.
--
-- El número de coche no es decoración: es lo que confirma el viaje de vuelta. El
-- widget pide números y recibe acrónimos, así que sin el @#n@ no hay forma de ver
-- que lo que volvió corresponde a lo que se pidió — y en el caso del respaldo, de
-- ver que __no__ corresponde: el dummy siempre habla de @16@ y @1@, así que pedir
-- @44@ y leer @#16@ es exactamente la señal de que el microservicio no contestó.
--
-- El tiempo va en una línea y, si hay, la nota debajo, más pequeña; después, si lo
-- hay, el desplegable corto de su vuelta. El primer argumento la pinta tenue: lo que añade
-- un grupo. Sin número (la vuelta de otra sesión), solo el nombre.
lapLabel :: MonadWidget t m => Bool -> Text -> Text -> (Text, Maybe Text) -> Maybe LapPick -> m (Event t LapChoice)
lapLabel faint name car (time, note) pick = divClass ("comparison__lap" <> if faint then " comparison__lap--group" else "") $ do
  elClass "span" "comparison__who" $ do
    elClass "span" "comparison__driver" $ text name
    unless (T.null car) $ elClass "span" "comparison__car" $ text ("#" <> car)
  elClass "span" "comparison__time" $ do
    text time
    forM_ note $ \n -> el "br" blank >> elClass "span" "comparison__time-note" (text n)
  maybe (pure never) lapPickSelect pick

-- | El desplegable corto de la vuelta de un piloto: en verde si difiere de la regla;
-- apagado, con «solo en directo», con FastF1. Devuelve lo que elige el usuario.
lapPickSelect :: MonadWidget t m => LapPick -> m (Event t LapChoice)
lapPickSelect p = do
  -- Las opciones reciben su @value@ después de montarse: escrito antes, no casa con
  -- ninguna y el desplegable queda vacío ('modeSelect').
  mounted <- delay 0 =<< getPostBuild
  let cfg = def
        & selectElementConfig_initialValue .~ lapChoiceKey (lpValue p)
        & selectElementConfig_setValue .~ (lapChoiceKey (lpValue p) <$ mounted)
        & selectElementConfig_elementConfig . elementConfig_initialAttributes .~ attrs
  (sel, _) <- selectElement cfg $ forM_ (lpOptions p) $ \(c, label) ->
    elAttr "option" ("value" =: lapChoiceKey c) $ text label
  pure (fmapMaybe lapChoiceFromKey (_selectElement_change sel))
  where
    attrs =
      ("class" =: ("car-selector__select comparison__pick" <> if lpDiffers p then " comparison__pick--differs" else ""))
        <> (if lpEnabled p then mempty else "disabled" =: "disabled" <> "title" =: "solo en directo")

-- | Lo que la fila de fronteras necesita para turnarse con la banda de sectores: el
-- modo elegido, que decide qué lleva la banda; el que se ve, que decide la fila y su
-- alto (la banda no lo cambia), y si está puesta la banda.
data RowMode t = RowMode
  { rmChosen :: ChartMode
  , rmShown  :: ChartMode
  , rmBand   :: Dynamic t Bool
  }

-- | La gráfica según el reparto, el lado del eje y el modo de la fila: las curvas, con
-- las vueltas de otras sesiones que suman los grupos ('Common.Comparison.curvesWith'), el
-- eje vertical (en su columna o dentro, según 'clAxisInside') y la fila de fronteras, la
-- del frente. El primer argumento se pinta encima de la curva, dentro de su lienzo:
-- el aviso de la petición. Si la referencia no tiene vuelta, en lugar de todo eso va
-- el aviso de 'Common.Comparison.missingReference' (en directo, el de
-- 'Common.Comparison.liveMissingReference'). Lo que no es gráfica —ese aviso, la carga y
-- los fallos— va por el segundo argumento, que recibe si ninguno de los elegidos tiene
-- vuelta ('Common.Comparison.noneHasLap') y el estado que pintar. Devuelve los clics en la
-- fila ('never' sin fila).
plotView
  :: MonadWidget t m
  => m () -> (Bool -> m () -> m ()) -> RowMode t -> CardLayout -> Side -> View -> Maybe [LiveEntry]
  -> [(SessionKey, ComparisonEntry)] -> Blend -> CState -> m (Event t ())
plotView _ instead _ _ _ _ _ _ _ Loading =
  never <$ instead False (elClass "p" "status status--loading" (text "Cargando…"))
plotView _ instead _ _ _ _ _ _ _ Failed =
  never <$ instead False (elClass "p" "status status--error" (text "Error al cargar /api/comparison"))
plotView _ instead _ _ _ _ _ _ _ NotFound =
  never <$ instead False (elClass "p" "status status--empty" (text notFoundNotice))
plotView overlay instead rm l axis v les laps b (Loaded c)
  | Just note <- maybe (missingReference (vBase v) c) (liveMissingReference (vBase v)) les =
      never <$ instead (noneHasLap c) (elClass "p" "status status--empty" (text note))
  | chartTypeTraces (vType v) = tracesView overlay rm v b c
  | otherwise =
      elAttr "div" (plotRowAttrs axis) $ do
        clicks <- divClass "comparison__plotarea" $ do
          elAttr "div" canvasAttrs $ do
            deltaChart b curves
            mapM_ edgeNote (zip [0 ..] (edgeNotes curves))
            when (clAxisInside l) $
              mapM_ insideTick (insideAxisLabels axis (clChart l) values)
            overlay
          frontierRow rm (maybe [] cvDelta (find ((== Front) . cvLayer) curves))
        unless (clAxisInside l) $ axisColumn axis values
        pure clicks
  where
    -- La base es la línea del cero: no lleva curva.
    curves = [cv | cv <- curvesWith (vBase v) (vFront v) c laps, cvLayer cv /= Behind, not (null (cvDelta cv))]
    values = axisValues curves

-- | Las trazas de los dos primeros coches: los canales del tipo
-- ('Common.Traces.traceChannels') en el eje elegido, con las fronteras de cada coche
-- si van y, debajo, la fila Δ en las fronteras de la referencia. Cada coche con la pareja
-- de su piloto y la mezcla @b@ ('inkedCurve'), al 'traceOpacity' para que donde coinciden se vean
-- los dos, encima la referencia; quien no está en la
-- tabla, con su color de siempre: rojo la referencia, blanco el otro. Un coche sin traza
-- —sin vuelta, o el dummy— no se pinta, y sin ninguna quedan los canales vacíos.
--
-- El lienzo va en trozos ('Common.Traces.traceLayout'): cada fila es un @\<svg\>@ que
-- pinta en px su franja del dibujo entero ('pxSvg'), y las fronteras van en otro encima
-- de las filas, estirado. Lo que crece la tarjeta lo reparte el navegador con el @flex@
-- de cada trozo, y cada fila se repinta a su nuevo tamaño. Los rótulos van en HTML, en
-- porcentaje del ancho. El lienzo y la fila entran 'Common.ComparisonCard.tracesInset'.
tracesView
  :: MonadWidget t m => m () -> RowMode t -> View -> Blend -> LapComparison -> m (Event t ())
tracesView overlay rm v b c = case lcEntries c of
  ref : other : _ -> do
    let axis  = vAxis v
        cars  = [(other, inksOr traceOtherColor (ceDriver other)), (ref, inksOr traceRefColor (ceDriver ref))]
        xMax  = maximum [axisEnd axis ref e | e <- [ref, other]]
        delta = seriesOf (vBase v) c
        cells = case boundaryXs axis ref of
          Just xs | not (null delta) -> frontierCellsAt (map (xPercent xMax) xs) delta
          _                          -> []
    elAttr "div" (Map.fromList [("class", "comparison__canvas comparison__canvas--traces"), ("style", insetStyle tracesInset)]) $ do
      piece (tlTop layout) blank
      elAttr "div" (Map.fromList [("class", "comparison__traces-span"), ("style", pieceFlex (spanPiece (tlSpan layout)))]) $ do
        forM_ (tlSpan layout) $ \p -> piece p $ forM_ (tpChannel p) $ \ch -> do
          let range@(lo, hi) = channelRange ch [ref, other]
              vb = (0, channelTop rows ch, tracesWidth, channelHeight rows ch)
          pxSvg (traceRowAttrs ch) $ \box -> do
            let toBox = toPixels vb box
            forM_ [lo, hi] $ \y -> svgEl "line" (traceGridAttrs (fst box) (snd (toBox (0, rowY ch range y)))) blank
            forM_ cars $ \(e, ink) ->
              svgEl "g" (Map.singleton "opacity" traceOpacity) $
                inkedCurve b ink (map toBox (traceVertices rows ch range xMax (traceXs axis ref e) (ceTrace e)))
          traceLabel "left: 0; top: -13px" (channelCaption ch range)
        when (vFrontiers v) $
          svgEl "svg" (traceFrontiersAttrs rows) $
            forM_ cars $ \(e, ink) ->
              forM_ (frontierPair (frontierXs axis ref e)) $ \x ->
                svgEl "line" (traceFrontierAttrs rows (inkTeam ink) (tracesWidth * xPercent xMax x / 100)) blank
      piece (tlBottom layout) $ do
        traceLabel "left: 0; top: calc(100% - 13px)" "0"
        traceLabel "right: 0; top: calc(100% - 13px)" (axisEndLabel axis xMax)
      when (vFrontiers v) $
        forM_ (zip [0 :: Int ..] cars) $ \(row, (e, ink)) ->
          forM_ (zip ["S1", "S2"] (frontierPair (frontierXs axis ref e))) $ \(name, x) ->
            traceLabelColored (if row == 0 then "comparison__trace-label--other" else "comparison__trace-label--ref")
              ("left: calc(" <> formatFixed 3 (xPercent xMax x) <> "% + 2px); top: " <> px (if row == 0 then 10 else 0)
                 <> "; color: " <> inkTeam ink)
              name
      overlay
    frontierRowAt tracesInset rm delta cells
  _ -> pure never
  where
    rows   = TraceRows (traceChannels (vType v) (vCharts v))
    layout = traceLayout rows
    piece p = elAttr "div" (Map.fromList [("class", "comparison__trace-piece"), ("style", pieceFlex p)])
    frontierPair = maybe [] (\(s1, s2) -> [s1, s2])
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

-- | El @\<svg\>@ de la fila de un canal, que llena su trozo.
traceRowAttrs :: Channel -> Map Text Text
traceRowAttrs ch =
  Map.fromList
    [ ("class", "comparison__traces comparison__traces--row")
    , ("data-channel", T.toLower (T.pack (show ch)))
    ]

-- | Un @\<svg\>@ sin @viewBox@, en px de su caja, con lo que pinte @draw@ para el ancho y
-- el alto de la caja; se repinta cada vez que la caja cambia de tamaño. Nada mientras
-- mide 0.
pxSvg :: MonadWidget t m => Map Text Text -> ((Double, Double) -> m ()) -> m ()
pxSvg attrs draw = mdo
  (e, _) <- elDynAttrNS' svgNamespace "svg" (constDyn attrs) $ dyn_ (maybe blank draw <$> box)
  changes  <- boxChanges (_element_raw e)
  measured <- performEvent (measure e <$ changes)
  box      <- holdUniqDyn =<< holdDyn Nothing (Just <$> ffilter (\(w, h) -> w > 0 && h > 0) measured)
  pure ()
  where
    measure e = DOM.liftJSM $ do
      r <- DOM.getBoundingClientRect (_element_raw e)
      (,) <$> DOM.getWidth r <*> DOM.getHeight r

-- | Un evento cada vez que el navegador ve cambiar el tamaño del elemento, ya pintado
-- (@ResizeObserver@), y al empezar a observarlo. Deja de observarlo cuando sale de la
-- página.
boxChanges :: MonadWidget t m => DOM.Element -> m (Event t ())
boxChanges e = do
  (changes, fire) <- newTriggerEvent
  DOM.liftJSM $ do
    cb  <- JS.function $ \_ _ args -> case args of
      _ : obs : _ -> do
        connected <- JS.valToBool =<< (JS.toJSVal e JS.! ("isConnected" :: Text))
        if connected then liftIO (fire ()) else () <$ (obs JS.# ("disconnect" :: Text) $ ())
      _ -> liftIO (fire ())
    obs <- JS.new (JS.jsg ("ResizeObserver" :: Text)) [JS.toJSVal cb]
    () <$ (obs JS.# ("observe" :: Text) $ [JS.toJSVal e])
  pure changes

-- | La opacidad de cada coche en las trazas, su línea y sus trazos juntos (2026-11-23 (k)).
traceOpacity :: Text
traceOpacity = "0.6"

-- | Una curva en px con la pareja de su piloto: la línea entera en la tinta del equipo y
-- encima la del casco, según la mezcla ('Common.Blend.blendOverlay'); los trazos sueltos,
-- recortados por la línea con una @\<mask\>@. Con las dos tintas iguales, la línea sola.
-- Nada con menos de dos puntos.
inkedCurve :: MonadWidget t m => Blend -> Inks -> [Point] -> m ()
inkedCurve = inkedCurveWide lineWidth

-- | Una curva tenue de 3 a 5 coches (2026-11-21 (l)): la de 'inkedCurve' a 2 px y al 35 %.
faintCurve :: MonadWidget t m => Blend -> Inks -> [Point] -> m ()
faintCurve b ink pts = svgEl "g" (Map.singleton "opacity" "0.35") $ inkedCurveWide 2 b ink pts

-- | La vuelta de otra sesión (2026-11-21 (af)): a puntos con las dos tintas de su piloto, la
-- del casco en los huecos de la del equipo; al frente a 'Common.Blend.lineWidth' y si no,
-- tenue, a 2,5 px y a la mitad. Nada con menos de dos puntos.
dottedCurve :: MonadWidget t m => Bool -> Inks -> [Point] -> m ()
dottedCurve atFront ink pts = when (length pts >= 2) $
  svgEl "g" (Map.singleton "opacity" (if atFront then "1" else "0.5")) $ do
    svgEl "polyline" (dots (inkTeam ink) "0") blank
    svgEl "polyline" (dots (inkHelmet ink) (formatFixed 2 (gap / 2 + 0.5))) blank
  where
    w   = if atFront then lineWidth else 2.5
    gap = 2 * w
    dots color offset =
      curveLineAttrs w color pts
        <> Map.fromList [("stroke-dasharray", "1 " <> formatFixed 2 gap), ("stroke-dashoffset", offset), ("stroke-linecap", "round")]

-- | Una curva de la gráfica según cómo se pinta ('Common.Comparison.Curve'): la de otra
-- sesión, a puntos; la del frente, entera; las demás, tenues.
drawCurve :: MonadWidget t m => Blend -> Inks -> Curve -> [Point] -> m ()
drawCurve b ink cv
  | isJust (cvFrom cv)  = dottedCurve (cvLayer cv == Front) ink
  | cvLayer cv == Faint = faintCurve b ink
  | otherwise           = inkedCurve b ink

-- | 'inkedCurve' con la línea, y la máscara que recorta los trazos, del ancho dado en px.
inkedCurveWide :: MonadWidget t m => Double -> Blend -> Inks -> [Point] -> m ()
inkedCurveWide w b ink pts = when (length pts >= 2) $ do
  svgEl "polyline" (curveLineAttrs w (inkTeam ink) pts) blank
  when (inkHelmet ink /= inkTeam ink) $ case blendOverlay b pts of
    Dashed d ->
      svgEl "polyline" (curveLineAttrs w (inkHelmet ink) pts <> Map.singleton "stroke-dasharray" (num2 d <> " " <> num2 d)) blank
    Marks ms -> do
      mid <- ("pareja-" <>) . T.pack . show . hashUnique <$> liftIO newUnique
      svgEl "mask" (Map.fromList [("id", mid), ("maskUnits", "userSpaceOnUse")]) $
        svgEl "polyline" (curveLineAttrs w "#ffffff" pts) blank
      svgEl "g" (Map.singleton "mask" ("url(#" <> mid <> ")")) $
        forM_ ms $ \m -> svgEl "polyline" (markAttrs (inkHelmet ink) m) blank
  where
    num2 = formatFixed 2
    markAttrs color m =
      Map.fromList
        [ ("points", pointsAttr (markPoints m)), ("fill", "none"), ("stroke", color)
        , ("stroke-width", num2 (markWidth m)), ("stroke-linejoin", "miter") ]

-- | La muestra de una curva en la leyenda: un trozo recto de 28 px con su pareja y la
-- mezcla.
keySwatch :: MonadWidget t m => Blend -> Inks -> m ()
keySwatch b ink =
  svgEl "svg" (Map.fromList [("class", "comparison__swatch"), ("width", "28"), ("height", "8")]) $
    inkedCurve b ink [(0, 4), (28, 4)]

-- | La muestra de una curva como se pinta ('drawCurve').
curveSwatch :: MonadWidget t m => Blend -> Inks -> Curve -> m ()
curveSwatch b ink cv =
  svgEl "svg" (Map.fromList [("class", "comparison__swatch"), ("width", "28"), ("height", "8")]) $
    drawCurve b ink cv [(0, 4), (28, 4)]

-- | La línea de una curva en px, del grosor dado.
curveLineAttrs :: Double -> Text -> [Point] -> Map Text Text
curveLineAttrs w color pts =
  Map.fromList
    [ ("points", pointsAttr pts), ("fill", "none"), ("stroke", color)
    , ("stroke-width", formatFixed 2 w), ("stroke-linejoin", "round") ]

-- | El @\<svg\>@ de las fronteras, encima de las filas: su @viewBox@ va de punta a punta
-- de ellas ('Common.Traces.channelsSpan').
traceFrontiersAttrs :: TraceRows -> Map Text Text
traceFrontiersAttrs rows =
  Map.fromList
    [ ("class", "comparison__traces comparison__traces--frontiers")
    , ("viewBox", "0 " <> num top <> " " <> num tracesWidth <> " " <> num (bottom - top))
    , ("preserveAspectRatio", "none")
    ]
  where
    (top, bottom) = channelsSpan rows

-- | Las líneas tenues del mínimo y el máximo de un canal, en px: de 0 a @w@ a la altura @y@.
traceGridAttrs :: Double -> Double -> Map Text Text
traceGridAttrs w y =
  Map.fromList
    [ ("x1", "0"), ("x2", formatFixed 1 w), ("y1", formatFixed 1 y), ("y2", formatFixed 1 y)
    , ("stroke", "#888888"), ("stroke-opacity", "0.3")
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

-- | La cifra de una curva de otra sesión que se sale del eje, en el borde por donde sale y a
-- la derecha; la @i@-ésima, una línea más adentro.
edgeNote :: DomBuilder t m => (Int, (Bool, Double)) -> m ()
edgeNote (i, (up, v)) =
  elAttr "span" attrs $ text ((if up then "↑ " else "↓ ") <> formatDelta v)
  where
    attrs =
      Map.fromList
        [ ("class", "comparison__tick comparison__edge")
        , ("style", (if up then "top: " else "bottom: ") <> formatFixed 1 (4 + valueHeight * fromIntegral i) <> "px; right: " <> formatFixed 1 curveInset <> "px")
        ]

-- | La posición vertical de un número centrado en la Y de su línea, con la Y del
-- @viewBox@ en tanto por ciento del alto: el lienzo y la columna del eje crecen
-- juntos con la tarjeta.
topAt :: Double -> Text
topAt y =
  "top: calc(" <> formatFixed 3 (y / chartHeight * 100) <> "% - " <> formatFixed 3 (valueHeight / 2) <> "px)"

-- | El delta acumulado de cada curva, con la línea del cero dibujada aparte y una línea
-- tenue por cada número del eje salvo el cero. Todo con el rango de
-- 'Common.Chart.axisRange' sobre 'Common.Comparison.axisValues': lo que se sale se corta en el
-- borde del lienzo. Las líneas van de
-- borde a borde en un lienzo de @viewBox@ fijo; las curvas, en px en otro encima que
-- entra 'curveInset' por lado ('pxSvg'), en el orden de la lista, cada una con la pareja
-- de su piloto y la mezcla @b@: la tenue con 'faintCurve' y la demás con 'inkedCurve'.
--
-- La línea del cero se pinta __siempre__, incluso sin curvas: es la referencia que
-- da sentido al eje ("iban empatados"), no una decoración de los datos. Un coche sin
-- vuelta no trae curva y no se dice nada: lo dice su cabecera, «sin vuelta»
-- (2026-10-02).
deltaChart :: MonadWidget t m => Blend -> [Curve] -> m ()
deltaChart b curves = do
  svgEl "svg" chartAttrs $ do
    mapM_ (\y -> svgEl "line" (gridLineAttrs y) blank)
      [y | (v, y, _) <- axisTicks values, v /= 0]
    svgEl "line" (zeroLineAttrs values) blank
  unless (null curves) $
    pxSvg curveAttrs $ \box ->
      forM_ curves $ \cv ->
        drawCurve b (inksOr deltaColor (ceDriver (cvEntry cv))) cv
          (map (toPixels (0, 0, chartWidth, chartHeight) box) (axisPointsAmong [values] (cvDelta cv)))
  where
    values = axisValues curves

-- | El color de la curva Δ cuando el comparado no está en la tabla de parejas.
deltaColor :: Text
deltaColor = "#e10600"

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

-- | Qué es cada línea: la discontinua (el cero) es la base, y cada curva con la pareja
-- de su piloto, ese coche contra ella ('Common.Comparison.curvesWith'), en el orden de las
-- filas (@items@). La del frente dice que por encima del cero va por detrás, porque la
-- serie es comparado − base; las tenues, solo su nombre y su muestra tenue, y la de otra
-- sesión, su muestra a puntos. Lo que añade un grupo dice «, del grupo», y al final van,
-- en gris, lo de los grupos que no cabe (2026-11-21 (ae)). Cada curva se pulsa para
-- llevarla al frente, y eso es lo que devuelve: su clave ('Common.Comparison.curveKey').
--
-- Sin series no hay curva que explicar, y queda solo la base; si va contra la
-- referencia y es ella la que no tiene vuelta no hay gráfica, y no se pinta nada.
legend
  :: MonadWidget t m
  => Blend -> Baseline -> Maybe Text -> WithGroups -> [Item] -> [(SessionKey, ComparisonEntry)] -> Maybe SessionKey
  -> LapComparison -> m (Event t Text)
legend bl b front g items laps viewed c = case curvesWith b front c laps of
  cvs@(_ : _) | Nothing <- missingReference b c -> do
    forM_ [cvEntry cv | cv <- cvs, cvLayer cv == Behind] $ \e -> do
      elClass "span" "comparison__key comparison__key--ref" $ text "- - -"
      text (" " <> ceDriver e <> " (" <> baselineRole b <> ")")
    let drawn = [cv | cv <- cvs, cvLayer cv /= Behind, not (null (cvDelta cv))]
    picks <- forM [(it, cv) | it <- items, cv <- drawn, curveKey cv == itKey it] $ \(it, cv) -> do
      let ink    = inksOr deltaColor (ceDriver (cvEntry cv))
          front' = cvLayer cv == Front
      (e, _) <- elAttr' "span" (keyAttrs front') $ do
        curveSwatch bl ink cv
        text (" " <> itLegend it <> if front' then ": por encima, va por detrás" else "")
      pure (itKey it <$ domEvent Click e)
    forM_ (wgLeftOut g) $ \a ->
      elClass "span" "comparison__left-out" $ text ("· " <> leftOutLabel viewed a <> ", del grupo, no cabe")
    pure (leftmost picks)
  _ -> pure never
  where
    keyAttrs isFront =
      Map.fromList
        [ ("class", "comparison__key-curve" <> if isFront then " comparison__key-curve--front" else "")
        , ("title", "Pulsa para llevarla al frente")
        ]

-- | La leyenda de las trazas: la pareja de cada coche y qué resta la fila Δ
-- (@«Δ = NOR − LEC»@, el otro menos la base). Sin la Δ, solo las parejas; con el aviso
-- de la referencia sin vuelta, nada.
traceLegend :: MonadWidget t m => Blend -> Baseline -> LapComparison -> m ()
traceLegend bl b c = case (lcEntries c, pairWith b c) of
  (ref : other : _, Just p) | Nothing <- missingReference b c -> do
    keySwatch bl (inksOr traceRefColor (ceDriver ref))
    text (" " <> ceDriver ref <> " (referencia)")
    keySwatch bl (inksOr traceOtherColor (ceDriver other))
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

-- | La caja de la gráfica del tipo 1: nunca más baja que 'Common.Chart.chartHeight';
-- lo que crezca la tarjeta se lo queda ella.
canvasAttrs :: Map Text Text
canvasAttrs =
  Map.fromList
    [ ("class", "comparison__canvas")
    , ("style", "min-height: " <> num chartHeight <> "px")
    ]

-- | Lienzo: @viewBox@ fijo de 'Common.Chart', del ancho y el alto de su caja.
--
-- @preserveAspectRatio=\"none\"@ porque el eje X es la vuelta y el Y son
-- segundos: no son magnitudes comparables, así que conservar la proporción no
-- significa nada y estirar aprovecha la pantalla. Las líneas no engordan al
-- estirarse (@vector-effect@).
chartAttrs :: Map Text Text
chartAttrs =
  Map.fromList
    [ ("class", "comparison__chart")
    , ("viewBox", "0 0 " <> num chartWidth <> " " <> num chartHeight)
    , ("preserveAspectRatio", "none")
    ]

-- | La curva, en su propio lienzo encima del de las líneas: entra 'curveInset' por
-- cada lado, con el mismo alto y en px.
curveAttrs :: Map Text Text
curveAttrs =
  Map.fromList
    [ ("class", "comparison__curve")
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
    , ("vector-effect", "non-scaling-stroke")
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
    , ("vector-effect", "non-scaling-stroke")
    ]
  where
    y = num (axisZeroY series)

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
