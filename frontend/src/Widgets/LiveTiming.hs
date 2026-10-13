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
-- tabla sale de 'liveStateOf', que mira solo si hay filas; el indicador @● Live@
-- de la cabecera sale de 'Widgets.Live.indicatorOf'. Por eso un fallo puntual no
-- borra la tabla —la conserva desde el 2026-09-11 (c)— y aun así se ve: lo dice el
-- indicador, no el cuerpo.
--
-- __Cada celda lleva la clase de su columna__ ('Common.Columns.liveColumnClass'):
-- las columnas se pueden cerrar desde «Columnas ▾», y una regla por posición
-- (@nth-child@) cambiaría de columna al cerrar otra.
module Widgets.LiveTiming where

import           Common.Columns (LiveColumn (..), canClose, liveColumnClass,
                                 liveColumnLabel, menuColumns, shownColumns,
                                 toggleColumn)
import           Common.Origin  (Sourced (..))
import           Common.Shown   (Poll (..), delayWaitLabel)
import           Common.Types   (DriverStatus (..), LiveTable (..),
                                 LiveTimingRow (..), RowBreak (..),
                                 bestLapMarks, cutOffLabel, overCutOff,
                                 rowBreaks, statusLabel)
import           Control.Monad  (forM_)
import           Data.List      (zip4)
import           Data.Maybe     (fromMaybe)
import           Data.Set       (Set)
import qualified Data.Set       as Set
import           Data.Text      (Text)
import qualified Data.Text      as T
import           Reflex.Dom
import           Widgets.Live   (LiveView (..), indicatorOf, liveBadge,
                                 sessionOf)

-- | Qué enseña la tarjeta. 'Failed' (no 'Error') para no chocar con
-- nombres de @base@\/@Prelude@.
data LiveState
  = Loading
  | Failed
  | Loaded [LiveTimingRow] [Maybe RowBreak] [Bool]
    -- ^ Las filas, la raya que va encima de cada una ('Common.Types.rowBreaks') y
    -- si va fuera del 107 % ('Common.Types.overCutOff').
  | Waiting Text
    -- ^ Con retraso, mientras nada es tan viejo: el aviso de la espera.
  deriving (Eq)

-- | Lo que se enseña a partir del estado del refresco.
--
-- __Deja fuera a propósito si hay una petición en vuelo.__ Si entrara, la tabla se
-- volvería a montar al pedir y otra vez al llegar la respuesta —dos veces cada
-- diez segundos— aunque el dato no hubiera cambiado. Con 'holdUniqDyn' encima, se
-- monta solo cuando cambia lo que se ve.
--
-- __Se queda con las filas y, de la sesión, solo con sus rayas y el 107 %__
-- ('Common.Types.rowBreaks', 'Common.Types.overCutOff'): de la sesión se encarga la banda de la página
-- ('Pages.Dashboard.sessionBand'), y meterla entera aquí haría remontar la tabla
-- cada vez que avanzara el reloj.
liveStateOf :: Poll (Sourced LiveTable) -> LiveState
liveStateOf p =
  case pollShown p of
    Just shown           -> loaded (srcValue shown)
    Nothing
      | pollLastFailed p -> Failed
      | otherwise        -> Loading
  where
    loaded t =
      Loaded (liveRows t) (rowBreaks (liveSession t) (liveRows t))
        (overCutOff (liveSession t) (liveRows t))

-- | Tabla de live timing, alimentada por el directo que le pasa quien la monta.
liveTimingWidget :: MonadWidget t m => LiveView t -> m ()
liveTimingWidget live = divClass "widget widget--live-timing" $ do
  cutOff <- holdUniqDyn ((cutOffLabel =<<) . sessionOf <$> lvPoll live)
  closed <- divClass "widget__head" $ do
    el "h2" $ do
      text "Live Timing"
      elClass "span" "live-timing__cutoff" $ dynText (fromMaybe "" <$> cutOff)
    c <- columnsMenu
    liveBadge (lvDelay live) (indicatorOf <$> lvPoll live)
    pure c
  state <- holdUniqDyn (viewOf <$> lvDelay live <*> lvWait live <*> lvPoll live)
  dyn_ (renderState <$> closed <*> state)
  where
    viewOf n (Just wait) _ = Waiting (delayWaitLabel n wait)
    viewOf _ Nothing p     = liveStateOf p

    renderState :: DomBuilder t m => Set LiveColumn -> LiveState -> m ()
    renderState _ Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState _ Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/live"
    renderState _ (Waiting label) =
      elClass "p" "status status--loading" $ text label
    renderState closed (Loaded rows breaks overs) =
      elClass "table" "live-timing" $ do
        el "thead" $ el "tr" $
          forM_ cols $ \c -> elClass "th" (liveColumnClass c) $ text (liveColumnLabel c)
        el "tbody" $
          mapM_ (row cols) (zip4 rows (bestLapMarks rows) breaks overs)
      where
        cols = shownColumns closed

    row :: DomBuilder t m
        => [LiveColumn] -> (LiveTimingRow, (Bool, Bool), Maybe RowBreak, Bool) -> m ()
    row cols (r, marks, brk, over) = do
      case brk of
        Just (BreakKnockedOut label) ->
          elClass "tr" "live-timing__break" $
            elAttr "td" ("colspan" =: T.pack (show (length cols))) $ text label
        _ -> blank
      elClass "tr" (rowClass r brk) $
        forM_ cols $ \c -> elClass "td" (cellClass c marks) $ text (cellText c over r)

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

-- | «Columnas ▾»: un botón en el título que abre, flotando encima de la tabla, una
-- casilla por columna que se puede cerrar ('Common.Columns.menuColumns'), y las
-- columnas cerradas. Se cierra con el botón o pulsando fuera: mientras está abierto,
-- una capa transparente fija cubre la página y pulsarla lo cierra (2026-10-02).
--
-- Una casilla se apaga cuando cerrarla dejaría sin ninguna de las que cuentan
-- ('Common.Columns.canClose'). Lo elegido no se recuerda al recargar (hasta el 18).
columnsMenu :: MonadWidget t m => m (Dynamic t (Set LiveColumn))
columnsMenu = elClass "div" "live-timing__columns" $ mdo
  (btn, _) <- elAttr' "button" ("type" =: "button" <> "class" =: "live-timing__columns-btn") $
    text "Columnas ▾"
  backdrop <- dyn (layer <$> open)
  outside  <- switchHold never backdrop
  open     <- foldDyn ($) False (leftmost [not <$ domEvent Click btn, const False <$ outside])
  toggles  <- elDynAttr "div" (panelAttrs <$> open) $
    leftmost <$> mapM (box closed) menuColumns
  closed   <- foldDyn (\(c, on) -> toggleColumn c on) Set.empty toggles
  pure closed
  where
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
