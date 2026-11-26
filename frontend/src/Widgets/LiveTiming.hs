{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}

-- | Widget de Live timing (categoría Timing).
--
-- Renderiza una tabla con las filas de 'LiveTimingRow' del dominio compartido
-- ('Common.Types'). Modela los tres estados del fetch
-- ('Loading' \/ 'Failed' \/ 'Loaded'); ya no hay datos dummy locales.
--
-- __La tarjeta no pide: recibe__ el directo que monta la página ('Widgets.Live').
--
-- __Lo que se enseña y de dónde salió son dos cosas, y las pintan dos sitios.__ La
-- tabla sale de 'Widgets.LiveTiming.Helper.liveStateOf', que mira solo si hay filas; el indicador @● Live@
-- de la cabecera sale de 'Widgets.Live.Helper.indicatorOf'. Por eso un fallo puntual no
-- borra la tabla —la conserva desde el 2026-09-11 (c)— y aun así se ve: lo dice el
-- indicador, no el cuerpo.
--
-- __Cada celda lleva la clase de su columna__ ('Common.Columns.liveColumnClass'):
-- las columnas se pueden cerrar desde «Columnas ▾», y una regla por posición
-- (@nth-child@) cambiaría de columna al cerrar otra.
module Widgets.LiveTiming where

import           Client                    (decodeXhr, getReq)
import           Common.Columns            (LiveColumn (..), canClose,
                                            liveColumnClass, liveColumnLabel,
                                            menuColumns, shownColumns,
                                            toggleColumn)
import           Common.Group              (bestPerSession, fromTag)
import           Common.Pilots             (highlightEdge, highlightFill)
import           Common.Route              (livePathFor)
import           Common.Session            (SessionKey, notFoundNotice,
                                            notRunNotice, sessionQuery)
import           Common.Types              (DriverStatus (..), LiveTable (..),
                                            LiveTimingRow (..), RowBreak (..),
                                            bestLapMarks, cutOffLabel,
                                            lapSeconds, statusLabel)
import           Control.Monad             (forM_, when)
import           Control.Monad.IO.Class    (liftIO)
import           Data.List                 (zip4)
import           Data.Map                  (Map)
import qualified Data.Map                  as Map
import           Data.Maybe                (fromMaybe, isJust)
import           Data.Set                  (Set)
import qualified Data.Set                  as Set
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import qualified GHCJS.DOM.Types           as DOM (Element, liftJSM)
import qualified Language.Javascript.JSaddle as JS
import           Reflex.Dom
import           Widgets.Card              (CardExtras (..))
import           Widgets.Live              (LiveView (..), liveBadge)
import           Widgets.Live.Helper       (indicatorOf, sessionOf)
import           Widgets.LiveTiming.Helper (LiveState (..), hasTable,
                                            liveViewOf)

-- | Tabla de live timing, alimentada por el directo que le pasa quien la monta, con lo que
-- quien la monta le pone dentro ('Widgets.Card.CardExtras'): junto al título, bajo la
-- cabecera (lo que devuelve es lo que devuelve la tarjeta), las filas que destaca
-- ('Common.Pilots.highlightFill') y las sesiones que suma: con alguna, la Best Lap lleva una
-- cifra por sesión ('bestCell'), lado a lado si la tabla cabe así en su ancho ('sideFits') y si
-- no una debajo de otra.
liveTimingWidget :: MonadWidget t m => Dynamic t (Maybe SessionKey) -> LiveView t -> CardExtras t m a -> m a
liveTimingWidget session live extras = divClass "widget widget--live-timing" $ do
  cutOff <- holdUniqDyn ((cutOffLabel =<<) . sessionOf <$> lvPoll live)
  state <- holdUniqDyn (liveViewOf <$> (isJust <$> session) <*> lvDelay live <*> lvWait live <*> lvPoll live)
  closed <- divClass "widget__head" $ do
    el "h2" $ do
      text "Live Timing"
      elClass "span" "live-timing__cutoff" $ dynText (fromMaybe "" <$> cutOff)
    cardBeside extras
    c <- columnsMenu (hasTable <$> state)
    liveBadge (lvDelay live) (indicatorOf <$> (isJust <$> session) <*> lvPoll live)
    pure c
  out <- cardUnder extras
  marked <- holdUniqDyn (cardHighlight extras)
  sessions <- holdUniqDyn (cardSessions extras)
  added <- addedTables (snd <$> sessions)
  let from = fromSessions <$> sessions <*> added
  rec (box, _) <- elClass' "div" "live-timing__box" $
        dyn_ (renderState <$> closed <*> marked <*> from <*> side <*> state)
      changed <- watchBox (_element_raw box)
      fits    <- performEvent (DOM.liftJSM (sideFits (_element_raw box)) <$ changed)
      side    <- holdUniqDyn =<< holdDyn False fits
  pure out
  where
    fromSessions (Just viewed, ks@(_ : _)) tables =
      Just (viewed, [(k, rows) | k <- ks, Just rows <- [Map.lookup k tables]])
    fromSessions _ _ = Nothing

    renderState :: DomBuilder t m
                => Set LiveColumn -> [Text] -> Maybe (SessionKey, [(SessionKey, [LiveTimingRow])]) -> Bool
                -> LiveState -> m ()
    renderState _ _ _ _ Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState _ _ _ _ Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/live"
    renderState _ _ _ _ (Waiting label) =
      elClass "p" "status status--loading" $ text label
    renderState _ _ _ _ NotRun =
      elClass "p" "status status--empty" $ text notRunNotice
    renderState _ _ _ _ NotFound =
      elClass "p" "status status--empty" $ text notFoundNotice
    renderState closed marked from side (Loaded rows breaks overs) =
      elClass "table" ("live-timing" <> if side then " live-timing--side" else "") $ do
        el "thead" $ el "tr" $
          forM_ cols $ \c -> elClass "th" (liveColumnClass c) $ do
            text (liveColumnLabel c)
            case (c, from) of
              (ColBestLap, Just (viewed, tables)) -> bestHeads viewed (map fst tables)
              _                                   -> blank
        el "tbody" $
          mapM_ (row cols marked from) (zip4 rows (bestLapMarks rows) breaks overs)
      where
        cols = shownColumns closed

    -- Las etiquetas de las sesiones de la Best Lap, una sobre cada cifra; solo se ven lado a
    -- lado, cuando las filas no las llevan (2026-11-21 (ag)).
    bestHeads :: DomBuilder t m => SessionKey -> [SessionKey] -> m ()
    bestHeads viewed ks =
      elClass "span" "live-timing__heads" $
        forM_ (viewed : ks) $ \k ->
          elClass "span" "live-timing__head" $ fromLabel viewed k

    row :: DomBuilder t m
        => [LiveColumn] -> [Text] -> Maybe (SessionKey, [(SessionKey, [LiveTimingRow])])
        -> (LiveTimingRow, (Bool, Bool), Maybe RowBreak, Bool) -> m ()
    row cols marked from (r, marks, brk, over) = do
      case brk of
        Just (BreakKnockedOut label) ->
          elClass "tr" "live-timing__break" $
            elAttr "td" ("colspan" =: T.pack (show (length cols))) $ text label
        _ -> blank
      elAttr "tr" ("class" =: rowClass r brk <> lit highlightFill) $
        forM_ (zip [0 :: Int ..] cols) $ \(i, c) ->
          elAttr "td" ("class" =: cellClass c (if isJust from then (False, False) else marks)
                         <> (if i == 0 then lit highlightEdge else mempty)) $
            case (c, from) of
              (ColBestLap, Just (viewed, tables)) -> bestCell viewed tables marks r
              _                                   -> text (cellText c over r)
      where
        lit f
          | ltDriver r `elem` marked = "style" =: f (ltDriver r)
          | otherwise                = mempty

    -- La Best Lap con las sesiones que suma la tarjeta (2026-11-21 (z), (aa)): la de la sesión que
    -- se ve, con su negrita y su morado, y detrás una por sesión sumada, en su orden; la más rápida
    -- de cada una, en morado tenue. Cada cifra lleva la etiqueta de su sesión (2026-11-20 (n)); donde
    -- una sesión no trae al piloto, un hueco, para que lado a lado cada sesión quede en su columna.
    bestCell :: DomBuilder t m
             => SessionKey -> [(SessionKey, [LiveTimingRow])] -> (Bool, Bool) -> LiveTimingRow -> m ()
    bestCell viewed tables (sessionBest, partBest) r = do
      figure (["live-timing__best--session" | sessionBest] <> ["live-timing__best--part" | partBest]) viewed (ltBestLap r)
      forM_ (bestPerSession tables r) $ \(k, fig) -> case fig of
        Just (lap, fastest) -> figure ["live-timing__fig--other-fastest" | fastest] k lap
        Nothing             -> elClass "span" "live-timing__fig live-timing__fig--none" blank
      where
        figure extra k lap =
          elClass "span" (T.unwords ("live-timing__fig" : extra)) $ do
            text lap
            when (isJust (lapSeconds lap)) $ fromLabel viewed k

    -- La etiqueta de la sesión de una cifra, vista desde @viewed@: la que se ve, tenue; otra, con
    -- contorno (2026-11-20 (n)).
    fromLabel :: DomBuilder t m => SessionKey -> SessionKey -> m ()
    fromLabel viewed k =
      elClass "span" ("live-timing__from " <> if k == viewed then "live-timing__from--here" else "live-timing__from--other") $
        text (fromTag viewed k)

    -- Un abandono gana a «>107 %»: dice más de por qué la fila no cuenta.
    cellText :: LiveColumn -> Bool -> LiveTimingRow -> Text
    cellText ColPos _      = T.pack . show . ltPosition
    cellText ColDriver _   = ltDriver
    cellText ColTeam _     = ltTeam
    cellText ColGap _      = ltGap
    cellText ColInterval _ = ltInterval
    cellText ColLastLap _  = ltLastLap
    cellText ColBestLap _  = ltBestLap
    cellText ColState over = \r ->
      if over && ltStatus r == Running then ">107 %" else statusLabel (ltStatus r)

    -- La más rápida de la sesión, en negrita; la de la parte en curso, en morado
    -- ('Common.Types.bestLapMarks').
    cellClass :: LiveColumn -> (Bool, Bool) -> Text
    cellClass ColBestLap (session, part) =
      T.unwords $
        [liveColumnClass ColBestLap]
          <> ["live-timing__best--session" | session]
          <> ["live-timing__best--part" | part]
    cellClass c _ = liveColumnClass c

    -- Modificador solo cuando hay algo que señalar: 16 de las 22 filas de una
    -- carrera son 'Running', y emitir un modificador que no modifica nada
    -- convierte la clase en ruido.
    --
    -- __Las tres marcas comparten modificador y no llevan uno cada una.__ La
    -- distinción la hace la sigla de la celda, que es texto y se lee; el
    -- modificador solo dice «esta fila no cuenta para la carrera», que es lo
    -- mismo en los tres casos. Tres reglas de color para tres estados que el
    -- usuario ya distingue leyendo serían tres cosas que mantener sincronizadas
    -- con el tipo de 'common'.
    --
    -- El eliminado y la raya roja van aparte: un eliminado no ha dejado de correr
    -- por avería, y la raya marca dónde empieza la zona, no una fila distinta.
    rowClass :: LiveTimingRow -> Maybe RowBreak -> Text
    rowClass r brk =
      T.unwords $
        ["live-timing__row"]
          <> ["live-timing__row--out" | ltStatus r /= Running]
          <> ["live-timing__row--knocked" | ltKnockedOut r]
          <> ["live-timing__row--cut" | brk == Just BreakCut]

-- | Las filas de cada sesión de @keys@, pedidas a @/api/live@ cada vez que cambian; hasta que
-- llegan, las de antes. Una sesión cuya petición falla no está.
addedTables :: MonadWidget t m => Dynamic t [SessionKey] -> m (Dynamic t (Map SessionKey [LiveTimingRow]))
addedTables keys = do
  pb <- getPostBuild
  let asked = Map.fromList . map (\k -> (k, getReq (livePathFor (sessionQuery (Just k))))) <$> leftmost [updated keys, tag (current keys) pb]
  resp <- performRequestsAsync (ffilter (not . Map.null) asked)
  holdDyn Map.empty (Map.mapMaybe (fmap liveRows . decodeXhr) <$> resp)

-- | Si la tabla de @box@ cabe en su ancho con las cifras de la Best Lap lado a lado (2026-11-21
-- (z), la regla del «VS»: cabe o no cabe): una copia de la tabla en esa forma, invisible y a su
-- ancho natural, se mide contra el de @box@ y se quita en el mismo paso. Sin tabla, no.
sideFits :: DOM.Element -> JS.JSM Bool
sideFits box = do
  f <- JS.eval probe
  JS.valToBool =<< JS.call f f [JS.toJSVal box]
  where
    probe :: Text
    probe =
      "(function (b) { var t = b.querySelector('table.live-timing'); if (!t) return false;\
      \ var c = t.cloneNode(true); c.classList.add('live-timing--side', 'live-timing--probe');\
      \ b.appendChild(c); var w = c.offsetWidth; b.removeChild(c); return w <= b.clientWidth; })"

-- | Un evento cada vez que cambia el tamaño de @box@ o lo que tiene dentro (la copia de
-- 'sideFits' no cuenta). Observa desde que se monta, esté ya o no en la página, y no deja de
-- observar: los observadores se van con la caja.
watchBox :: MonadWidget t m => DOM.Element -> m (Event t ())
watchBox box = do
  (changes, fire) <- newTriggerEvent
  DOM.liftJSM $ do
    cb <- JS.function $ \_ _ _ -> liftIO (fire ())
    f  <- JS.eval watch
    () <$ JS.call f f [JS.toJSVal box, JS.toJSVal cb]
  pure changes
  where
    watch :: Text
    watch =
      "(function (b, cb) { function real(n) { return !(n.classList && n.classList.contains('live-timing--probe')); }\
      \ new ResizeObserver(function () { cb(); }).observe(b);\
      \ new MutationObserver(function (ms) { if (ms.some(function (m) { return [].some.call(m.addedNodes, real)\
      \ || [].some.call(m.removedNodes, real); })) cb(); }).observe(b, { childList: true }); })"

-- | «Columnas ▾»: un botón en el título que abre, flotando encima de la tabla, una
-- casilla por columna que se puede cerrar ('Common.Columns.menuColumns'), y las
-- columnas cerradas. Se cierra con el botón o pulsando fuera: mientras está abierto,
-- una capa transparente fija cubre la página y pulsarla lo cierra (2026-10-02).
--
-- Una casilla se apaga cuando cerrarla dejaría sin ninguna de las que cuentan
-- ('Common.Columns.canClose'). Lo elegido no se recuerda al recargar (hasta el 18).
--
-- Con @shown@ falso ocupa su sitio sin verse, para que la cabecera no salte, y se cierra
-- si estaba abierto.
columnsMenu :: MonadWidget t m => Dynamic t Bool -> m (Dynamic t (Set LiveColumn))
columnsMenu shown = elDynClass "div" (wrapClass <$> shown) $ mdo
  (btn, _) <- elAttr' "button" ("type" =: "button" <> "class" =: "live-timing__columns-btn") $
    text "Columnas ▾"
  backdrop <- dyn (layer <$> open)
  outside  <- switchHold never backdrop
  open     <- foldDyn ($) False $
    leftmost [not <$ domEvent Click btn, const False <$ outside, const False <$ ffilter not (updated shown)]
  toggles  <- elDynAttr "div" (panelAttrs <$> open) $
    leftmost <$> mapM (box closed) menuColumns
  closed   <- foldDyn (\(c, on) -> toggleColumn c on) Set.empty toggles
  pure closed
  where
    wrapClass True  = "live-timing__columns"
    wrapClass False = "live-timing__columns live-timing__columns--hidden"
    layer True = do
      (e, _) <- elClass' "div" "live-timing__backdrop" blank
      pure (domEvent Click e)
    layer False = pure never
    panelAttrs True  = "class" =: "live-timing__columns-panel"
    panelAttrs False = "class" =: "live-timing__columns-panel" <> "hidden" =: ""
    box closed c = elClass "label" "live-timing__column" $ do
      input <- inputElement $
        def
          & inputElementConfig_initialChecked .~ True
          & initialAttributes .~ ("type" =: "checkbox")
          & inputElementConfig_elementConfig . elementConfig_modifyAttributes
              .~ (disabledFor c <$> updated closed)
      text (liveColumnLabel c)
      pure ((,) c <$> _inputElement_checkedChange input)
    disabledFor c closedNow =
      "disabled" =: if Set.notMember c closedNow && not (canClose closedNow c) then Just "disabled" else Nothing
