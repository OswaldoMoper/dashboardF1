{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}

-- | Widget de Live timing (categoría Timing).
--
-- Renderiza una tabla con las filas de 'LiveTimingRow' del dominio compartido
-- ('Common.Types'). Modela los tres estados del fetch
-- ('Loading' \/ 'Failed' \/ 'Loaded'); ya no hay datos dummy locales.
--
-- __La tarjeta no pide: recibe.__ Quien consume @GET \/api\/live@ es 'livePoll', que
-- vive en este módulo pero la monta la página, y el resultado baja a la tarjeta por
-- argumento. Así la petición es __una por página__ y no una por tarjeta, que es lo
-- que permite que la sirvan a la vez varios consumidores sin solaparse entre ellos.
--
-- __Lo que se enseña y de dónde salió son dos cosas, y las pintan dos sitios.__ La
-- tabla sale de 'liveStateOf', que mira solo si hay filas; el indicador @● Live@
-- de la cabecera sale de 'indicatorOf', que cruza la procedencia, el último refresco
-- y si hay sesión rodando. Por eso un fallo puntual no borra la tabla —la conserva
-- desde el 2026-09-11 (c)— y aun así se ve: lo dice el indicador, no el cuerpo.
--
-- __Cada celda lleva la clase de su columna__ ('Common.Columns.liveColumnClass'):
-- las columnas se pueden cerrar desde «Columnas ▾», y una regla por posición
-- (@nth-child@) cambiaría de columna al cerrar otra.
module Widgets.LiveTiming where

import           Client        (fetchJsonSourced)
import           Common.Columns (LiveColumn (..), canClose, liveColumnClass,
                                 liveColumnLabel, menuColumns, shownColumns,
                                 toggleColumn)
import           Common.Origin (Sourced (..))
import           Common.Route  (livePath)
import           Common.Shown  (Indicator, Poll (..), PollEvent (..),
                                canRequest, delayNote, delayWait,
                                delayWaitLabel, delayedPoll, indicatorClass,
                                indicatorFrom, indicatorTooltip, landed,
                                liveRefreshSeconds, pollIdle, pollStep,
                                recordArrival, shownAge)
import           Common.Types  (DriverStatus (..), LiveTable (..),
                                LiveTimingRow (..), SessionInfo (..),
                                StateReading (..), bestLapMarks,
                                sessionInProgress, statusLabel, waitingTable)
import           Control.Monad (forM_)
import           Data.Set      (Set)
import qualified Data.Set      as Set
import           Data.Text     (Text)
import qualified Data.Text     as T
import           Reflex.Dom

-- | Qué enseña la tarjeta. 'Failed' (no 'Error') para no chocar con
-- nombres de @base@\/@Prelude@.
data LiveState
  = Loading
  | Failed
  | Loaded [LiveTimingRow]
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
-- __Se queda con las filas y descarta la sesión__ que 'Common.Types.LiveTable'
-- trae al lado: de la sesión se encarga la banda de la página
-- ('Pages.Dashboard.sessionBand'), y meterla aquí haría remontar la tabla entera
-- cada vez que avanzara el reloj.
liveStateOf :: Poll (Sourced LiveTable) -> LiveState
liveStateOf p =
  case pollShown p of
    Just shown           -> Loaded (liveRows (srcValue shown))
    Nothing
      | pollLastFailed p -> Failed
      | otherwise        -> Loading

-- | De qué sesión son las filas que se están enseñando, si se sabe.
--
-- Los dos 'Nothing' que atraviesa significan cosas distintas y aquí se juntan a
-- propósito: no haber recibido nada todavía y haber recibido una tabla que no
-- nombra su sesión se ven igual en la banda, porque en los dos casos no hay sesión
-- que enseñar. Es el contrapunto de 'liveStateOf', que se queda con las filas y
-- descarta esto.
sessionOf :: Poll (Sourced LiveTable) -> Maybe SessionInfo
sessionOf p = liveSession . srcValue =<< pollShown p

-- | En qué punto está esa sesión, si alguien lo dijo o el calendario lo permitió
-- deducir. Atraviesa los mismos dos 'Nothing' que 'sessionOf' y uno más —el de la
-- sesión que no trae estado—, y los tres se pintan igual porque los tres son «no se
-- sabe».
stateOf :: Poll (Sourced LiveTable) -> Maybe StateReading
stateOf p = siState =<< sessionOf p

-- | El indicador de la cabecera a partir de lo que ya hay en la mano: la
-- procedencia y el último intento salen del refresco, y si hay carrera sale de la
-- sesión que la tabla trae al lado.
--
-- __Es este módulo quien lo junta y no 'Common.Shown'__, que no conoce el
-- dominio: allí la sesión rodando entra como un 'Bool' y aquí es donde está el
-- 'Common.Types.LiveTable' del que sacarlo.
indicatorOf :: Poll (Sourced LiveTable) -> Indicator
indicatorOf p = indicatorFrom (sessionInProgress (srState <$> stateOf p)) p

-- | El refresco de @\/api\/live@: lo monta la página __una vez__ y lo reparte entre
-- quienes lo pintan.
--
-- __Se refresca solo cada 'liveRefreshSeconds'__ (2026-09-11 (c)), con un reloj que
-- __salta el tic__ si la petición anterior no ha vuelto: nunca hay dos en vuelo, y
-- una respuesta vieja no puede pisar a una nueva. Cuándo pedir y qué conservar si
-- falla es 'Common.Shown', pura y con suite; aquí solo se cablea al reloj y a la
-- petición. La URL es relativa ('Common.Route.livePath'), o sea misma-origen: el
-- backend sirve el bundle y la API en el mismo puerto.
--
-- __El @mdo@ no crea un bucle instantáneo:__ el tic se filtra con 'current' del
-- estado, que es su valor al empezar el frame, y no con su 'updated'. La petición
-- que sale en un frame marca 'Sent' al final de ese frame, y el siguiente tic ya la
-- ve en vuelo.
livePoll :: MonadWidget t m => m (Dynamic t (Poll (Sourced LiveTable)))
livePoll = mdo
  pb   <- getPostBuild
  tick <- tickLossyFromPostBuildTime (fromIntegral liveRefreshSeconds)
  let sent = leftmost [pb, () <$ gate (canRequest <$> current poll) tick]
  resp <- fetchJsonSourced (livePath <$ sent)
  poll <- foldDyn pollStep pollIdle (leftmost [Sent <$ sent, Arrived <$> resp])
  pure poll

-- | El directo tal como se enseña: el refresco visto con el retraso pedido, el
-- retraso, y cuántos segundos faltan para tener algo tan viejo ('Nothing' si ya lo
-- hay o no hay retraso), y cuántos segundos hace que llegó lo enseñado
-- ('Common.Shown.shownAge').
data LiveView t = LiveView
  { lvPoll  :: Dynamic t (Poll (Sourced LiveTable))
  , lvDelay :: Dynamic t Int
  , lvWait  :: Dynamic t (Maybe Int)
  , lvAge   :: Dynamic t (Maybe Int)
  }

-- | Aplica el retraso al refresco, una sola vez para la banda y para la tarjeta.
-- Guarda cada llegada con el segundo en que llegó, contado desde que se montó; lo
-- que se enseña cambia solo cuando cambia lo que se ve ('holdUniqDyn'), aunque el
-- segundero lo recalcule cada segundo.
delayedLive :: MonadWidget t m
            => Dynamic t Int -> Dynamic t (Poll (Sourced LiveTable)) -> m (LiveView t)
delayedLive delay poll = do
  tick     <- tickLossyFromPostBuildTime 1
  now      <- holdDyn 0 (fromIntegral . _tickInfo_n <$> tick)
  arrivals <- foldDyn (uncurry recordArrival) [] $
                attach (current now) (fmapMaybe landed (updated poll))
  shown    <- holdUniqDyn (delayedPoll waiting <$> delay <*> now <*> arrivals <*> poll)
  wait     <- holdUniqDyn (delayWait <$> delay <*> now <*> arrivals)
  age      <- holdUniqDyn (shownAge <$> delay <*> now <*> arrivals)
  pure (LiveView shown delay wait age)
  where
    waiting s = s {srcValue = waitingTable (srcValue s)}

-- | Tabla de live timing, alimentada por el directo que le pasa quien la monta.
liveTimingWidget :: MonadWidget t m => LiveView t -> m ()
liveTimingWidget live = divClass "widget widget--live-timing" $ do
  closed <- divClass "widget__head" $ do
    el "h2" $ text "Live Timing"
    liveBadge (lvDelay live) (indicatorOf <$> lvPoll live)
    columnsMenu
  state <- holdUniqDyn (viewOf <$> lvDelay live <*> lvWait live <*> lvPoll live)
  dyn_ (renderState <$> closed <*> state)
  where
    viewOf n (Just wait) _ = Waiting (delayWaitLabel n wait)
    viewOf _ Nothing p     = liveStateOf p

    -- __El texto es siempre @Live@__ (2026-09-11 (d)) y lo que cambia es el
    -- punto: un texto que cambiara de palabra se leería sin mirar el color, pero
    -- también se movería la fila del título cada diez segundos.
    --
    -- __Hace falta 'elDynAttr' y no 'elDynClass'__ porque son dos atributos: la
    -- clase la pinta la hoja y el @title@ la explica.
    liveBadge :: MonadWidget t m => Dynamic t Int -> Dynamic t Indicator -> m ()
    liveBadge delay indicator =
      elDynAttr "span" (attrsFor <$> delay <*> indicator) $ text "Live"
      where
        attrsFor n i =
          "class" =: indicatorClass i <> "title" =: delayNote n (indicatorTooltip i)

    renderState :: DomBuilder t m => Set LiveColumn -> LiveState -> m ()
    renderState _ Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState _ Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/live"
    renderState _ (Waiting label) =
      elClass "p" "status status--loading" $ text label
    renderState closed (Loaded rows) =
      elClass "table" "live-timing" $ do
        el "thead" $ el "tr" $
          forM_ cols $ \c -> elClass "th" (liveColumnClass c) $ text (liveColumnLabel c)
        el "tbody" $ mapM_ (row cols) (zip rows (bestLapMarks rows))
      where
        cols = shownColumns closed

    row :: DomBuilder t m => [LiveColumn] -> (LiveTimingRow, (Bool, Bool)) -> m ()
    row cols (r, marks) = elClass "tr" (rowClass (ltStatus r)) $
      forM_ cols $ \c -> elClass "td" (cellClass c marks) $ text (cellText c r)

    cellText :: LiveColumn -> LiveTimingRow -> Text
    cellText ColPos      = T.pack . show . ltPosition
    cellText ColDriver   = ltDriver
    cellText ColTeam     = ltTeam
    cellText ColGap      = ltGap
    cellText ColInterval = ltInterval
    cellText ColLastLap  = ltLastLap
    cellText ColBestLap  = ltBestLap
    cellText ColState    = statusLabel . ltStatus

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
    rowClass :: DriverStatus -> Text
    rowClass Running = "live-timing__row"
    rowClass _       = "live-timing__row live-timing__row--out"

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
