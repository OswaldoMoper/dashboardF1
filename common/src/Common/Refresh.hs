-- | Cuándo volver a pedir un dato que se refresca solo, y qué enseñar mientras.
--
-- Es la parte con decisiones del refresco periódico de 'Widgets.LiveTiming', sacada
-- del widget para que no sea ciega: el widget solo la cablea a un reloj y a la
-- respuesta de la petición, y todo lo que puede salir mal —dos peticiones a la vez,
-- una tabla que se borra por un fallo puntual— vive aquí, donde la suite lo alcanza.
-- Es el criterio del 2026-08-04 —lo puro y sin Reflex va a @common@—, el mismo que
-- trajo 'Common.Format', 'Common.Layout' y 'Common.Origin'.
--
-- __El reloj salta el tic si hay una petición en vuelo__ (2026-09-11 (c)), y por eso
-- el estado sabe si la hay. Con un reloj que pidiera pasara lo que pasara, una
-- fuente lenta —OpenF1 ha tardado 37–49 s en contestar— acumularía peticiones, y una
-- respuesta vieja podría llegar después de una nueva y hacer retroceder la tabla.
module Common.Refresh
  ( Poll (..)
  , PollEvent (..)
  , pollIdle
  , pollStep
  , canRequest
  , liveRefreshSeconds
  ) where

-- | Estado de un dato que se pide periódicamente.
data Poll a = Poll
  { pollInFlight   :: Bool
    -- ^ Hay una petición enviada cuya respuesta no ha llegado.
  , pollShown      :: Maybe a
    -- ^ Lo último que llegó bien; 'Nothing' hasta la primera respuesta buena.
  , pollLastFailed :: Bool
    -- ^ La última respuesta fue un fallo. __No borra 'pollShown'.__
  }
  deriving stock (Eq, Show)

-- | Lo que le pasa al dato: se pide, o llega la respuesta ('Nothing' si falló).
data PollEvent a
  = Sent
  | Arrived (Maybe a)
  deriving stock (Eq, Show)

-- | Antes de la primera petición: nada en vuelo, nada que enseñar, ningún fallo.
pollIdle :: Poll a
pollIdle = Poll {pollInFlight = False, pollShown = Nothing, pollLastFailed = False}

-- | El estado tras un evento.
--
-- __Un fallo conserva lo que se enseñaba__ (2026-09-11 (c)): con refresco, un fallo
-- puntual a media sesión borraría la tabla, y sustituir datos por un error es
-- peor que enseñar los anteriores sabiendo que lo son — que 'pollLastFailed' lo
-- sepa es lo que evita que conservarlos equivalga a mentir. Es el mismo criterio
-- que el @step@ de 'Widgets.Comparison'.
pollStep :: PollEvent a -> Poll a -> Poll a
pollStep Sent p =
  p {pollInFlight = True}
pollStep (Arrived (Just x)) p =
  p {pollInFlight = False, pollShown = Just x, pollLastFailed = False}
pollStep (Arrived Nothing) p =
  p {pollInFlight = False, pollLastFailed = True}

-- | Si un tic del reloj puede lanzar otra petición: solo sin ninguna en vuelo.
canRequest :: Poll a -> Bool
canRequest = not . pollInFlight

-- | Cada cuántos segundos se refresca Live Timing (2026-09-11 (c)).
--
-- Cada refresco son cinco GET a OpenF1, cuyo límite de peticiones no está medido.
-- Va en segundos enteros y no en @NominalDiffTime@ para que @common@ no dependa de
-- @time@; el widget lo convierte con 'fromIntegral'.
liveRefreshSeconds :: Int
liveRefreshSeconds = 10
