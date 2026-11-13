{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}

-- | El directo que comparten las tarjetas: el refresco de @GET \/api\/live@, el retraso
-- con que se enseña y el indicador @● Live@ de las cabeceras.
--
-- __Las tarjetas no piden: reciben.__ Quien consume @GET \/api\/live@ es 'livePoll', que
-- monta la página una sola vez, y el resultado baja a cada tarjeta por argumento. Así
-- la petición es __una por página__ y no una por tarjeta, que es lo que permite que la
-- sirvan a la vez varios consumidores sin solaparse entre ellos.
--
-- __Lo que se enseña y de dónde salió son dos cosas.__ El indicador sale de
-- 'indicatorOf', que cruza la procedencia, el último refresco y si hay sesión
-- rodando; lo que pinta cada tarjeta lo decide ella. Por eso un fallo puntual no borra
-- lo que se ve y aun así se nota: lo dice el indicador, no el cuerpo.
module Widgets.Live where

import           Client        (fetchJsonSourcedNumbered)
import           Common.Origin (Sourced (..))
import           Common.Route  (livePath)
import           Common.Shown  (Indicator, Poll (..), PollEvent (..),
                                canRequest, delayNote, delayWait, delayedPoll,
                                indicatorClass, indicatorFrom, indicatorTooltip,
                                landed, liveRefreshSeconds,
                                liveRequestTimeoutSeconds, nextRequest, pollIdle,
                                pollStep, recordArrival, shownAge)
import           Common.Types  (LiveTable (..), SessionInfo (..),
                                SessionState (..), StateReading (..),
                                sessionInProgress, waitingTable)
import qualified GHCJS.DOM          as DOM (currentDocumentUnchecked)
import qualified GHCJS.DOM.Document as DOM (getHidden, visibilitychange)
import qualified GHCJS.DOM.EventM   as DOM (on)
import qualified GHCJS.DOM.Types    as DOM (Document (..), liftJSM)
import           Reflex.Dom

-- | De qué sesión son las filas que se están enseñando, si se sabe.
--
-- Los dos 'Nothing' que atraviesa significan cosas distintas y aquí se juntan a
-- propósito: no haber recibido nada todavía y haber recibido una tabla que no
-- nombra su sesión se ven igual en la banda, porque en los dos casos no hay sesión
-- que enseñar. Es el contrapunto de 'Widgets.LiveTiming.liveStateOf', que se queda
-- con las filas y descarta esto.
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
-- dominio: allí la sesión rodando y la finalizada entran como 'Bool' y aquí es
-- donde está el 'Common.Types.LiveTable' del que sacarlas.
indicatorOf :: Poll (Sourced LiveTable) -> Indicator
indicatorOf p = indicatorFrom (sessionInProgress state) (state == Just SessionFinalised) p
  where
    state = srState <$> stateOf p

-- | El refresco de @\/api\/live@: lo monta la página __una vez__ y lo reparte entre
-- quienes lo pintan.
--
-- __Se refresca solo cada 'liveRefreshSeconds'__ (2026-09-11 (c)), con un reloj que
-- __salta el tic__ si la petición anterior no ha vuelto: nunca hay dos en vuelo, y
-- una respuesta vieja no puede pisar a una nueva. __Al volver a verse la pestaña__
-- se pide en el momento, con la misma regla: si hay una en vuelo, no. __Una petición sin
-- respuesta en 'liveRequestTimeoutSeconds' se da por perdida__: cuenta como fallo, el tic
-- siguiente pide, y si contesta después no cambia nada. Cuándo pedir y qué conservar si
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
  back <- tabShown
  let sent = leftmost [pb, gate (canRequest <$> current poll) (leftmost [() <$ tick, back])]
  let numbered = attachWith (\p _ -> (nextRequest p, livePath)) (current poll) sent
  resp <- fetchJsonSourcedNumbered numbered
  lost <- delay (fromIntegral liveRequestTimeoutSeconds) (fst <$> numbered)
  poll <-
    foldDyn pollStep pollIdle $
      leftmost [Sent <$ sent, uncurry Arrived <$> resp, (`Arrived` Nothing) <$> lost]
  pure poll

-- | Cada vez que la pestaña vuelve a verse (@visibilitychange@ con el documento ya no
-- oculto): al cambiar de pestaña, al restaurar la ventana minimizada.
tabShown :: MonadWidget t m => m (Event t ())
tabShown = do
  doc    <- DOM.liftJSM DOM.currentDocumentUnchecked
  hidden <- wrapDomEvent doc (`DOM.on` DOM.visibilitychange) (DOM.getHidden doc)
  pure (() <$ ffilter not hidden)

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

-- | Aplica el retraso al refresco, una sola vez para la banda y para las tarjetas.
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

-- | El @● Live@ de una cabecera: el retraso y el indicador ('indicatorOf').
--
-- __El texto es siempre @Live@__ (2026-09-11 (d)) y lo que cambia es el punto: un
-- texto que cambiara de palabra se leería sin mirar el color, pero también se movería
-- la fila del título cada diez segundos.
--
-- __Hace falta 'elDynAttr' y no 'elDynClass'__ porque son dos atributos: la clase la
-- pinta la hoja y el @title@ la explica.
liveBadge :: MonadWidget t m => Dynamic t Int -> Dynamic t Indicator -> m ()
liveBadge delay indicator =
  elDynAttr "span" (attrsFor <$> delay <*> indicator) $ text "Live"
  where
    attrsFor n i =
      "class" =: indicatorClass i <> "title" =: delayNote n (indicatorTooltip i)
