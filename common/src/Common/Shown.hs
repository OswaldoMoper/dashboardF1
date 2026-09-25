-- | Qué se enseña de un dato que se refresca solo: cuándo volver a pedirlo, qué
-- dejar en pantalla mientras, y qué dice de sí mismo el indicador __@● Live@__ que
-- lo acompaña.
--
-- Es la parte con decisiones del refresco periódico de 'Widgets.LiveTiming', sacada
-- del widget para que no sea ciega: el widget solo cablea un reloj, la respuesta de
-- la petición y el resultado a una clase y a un atributo @title@. Es el criterio del
-- 2026-08-04 —lo puro y sin Reflex va a @common@, que es lo único con suite—, el
-- mismo que trajo 'Common.Format', 'Common.Layout' y 'Common.Origin'.
--
-- __El indicador depende del refresco y no al revés.__ Qué punto pintar sale de si
-- el último intento volvió, que es 'Poll', y el periodo que dice el tooltip sale de
-- 'liveRefreshSeconds'; el refresco no necesita nada del indicador para decidir
-- cuándo pedir.
--
-- __El reloj salta el tic si hay una petición en vuelo__ (2026-09-11 (c)), y por eso
-- el estado sabe si la hay. Con un reloj que pidiera pasara lo que pasara, una
-- fuente lenta —OpenF1 ha tardado 37–49 s en contestar— acumularía peticiones, y una
-- respuesta vieja podría llegar después de una nueva y hacer retroceder la tabla.
--
-- __El color y el parpadeo dicen cosas distintas, y por eso son dos señales.__
-- El color es la procedencia del dato que hay en pantalla y nunca miente sobre
-- ella; el parpadeo es «esto es la carrera, ahora mismo», y por eso solo lo
-- lleva el dato fresco cuyo último refresco volvió. Un refresco fallido sobre
-- dato guardado o de ejemplo no cambia el punto: vive en el tooltip.
--
-- __El parpadeo afirma algo sobre la SESIÓN y no sobre el refresco__, y de ahí que no
-- lo herede lo reciente: que la página siga pidiendo cada pocos segundos no convierte
-- en directo la clasificación final de una sesión acabada.
--
-- __Si hay sesión rodando es la tercera pregunta, y no se deduce de las otras dos__
-- (2026-09-21). Fuera de sesión el backend sirve la clasificación final de la última
-- con el sello 'Common.Origin.Fresh', y el sello no miente —el dato acaba de
-- llegar—: lo que mentiría es el punto del directo. Por eso entra por argumento en
-- vez de adivinarse desde la procedencia, y por eso los dos sellos de refresco
-- bueno —'Common.Origin.Fresh' y 'Common.Origin.Recent'— caen sin ella en el mismo
-- apagado. Fuera de sesión el backend se frena, así que la respuesta llega con uno
-- y con otro un ciclo sí y otro no; con un punto por sello, el punto latiría.
--
-- __El parpadeo no se apaga con @prefers-reduced-motion@__, solo se alarga
-- (1 s → 3 s, en la hoja de estilos). No es decoración: es la única señal de que
-- lo que se lee está pasando ahora, y apagarla dejaría dos estados distintos
-- pintados igual.
module Common.Shown
  ( Poll (..)
  , PollEvent (..)
  , pollIdle
  , pollStep
  , canRequest
  , liveRefreshSeconds
  , Kept (..)
  , keptNothing
  , keepLast
  , Indicator (..)
  , indicatorFrom
  , indicatorClass
  , indicatorTooltip
  , fetchedAtLabel
    -- * Retraso
  , delayMaxSeconds
  , delayDefaultSeconds
  , readDelay
  , Arrivals
  , recordArrival
  , delayedShown
  , delayedPoll
  , delayWait
  , delayWaitLabel
  , delayNote
  ) where

import           Common.Format (ClockForm (..), formatClock, formatCountdown)
import           Common.Origin (Origin (..), Source, Sourced (..), originNotice,
                                sourceName)
import           Data.Char     (isDigit)
import           Data.List     (find)
import           Data.Maybe    (fromMaybe, isJust)
import           Data.Text     (Text)
import qualified Data.Text     as T

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
-- Cada refresco que llegue a OpenF1 son seis GET, y OpenF1 acepta __30 peticiones
-- por minuto__ — lo dice él mismo en su rechazo, medido el 2026-09-17—. A este
-- periodo saldrían 36, y __quien respeta el techo es el backend y no este número__,
-- que es de la página y no sabe cuántas páginas hay: el backend no vuelve a bajar a
-- OpenF1 si lo que guardó aún vale, y así la consulta cada 20 s. El directo, que
-- sirve el feed y no tiene techo, sigue a este ritmo.
-- Va en segundos enteros y no en @NominalDiffTime@ para que @common@ no dependa de
-- @time@; el widget lo convierte con 'fromIntegral'.
liveRefreshSeconds :: Int
liveRefreshSeconds = 10

-- | Lo último que se supo de algo que la respuesta a veces no trae, y si es de
-- ahora o de antes.
--
-- __'keptStale' solo puede ser 'True' con algo en 'keptValue'__: lo que nunca llegó
-- no se conserva, se espera.
data Kept a = Kept
  { keptValue :: Maybe a
  , keptStale :: Bool
  }
  deriving stock (Eq, Show)

-- | Antes de la primera llegada buena: nada que enseñar y nada que marcar.
keptNothing :: Kept a
keptNothing = Kept {keptValue = Nothing, keptStale = False}

-- | Lo conservado tras una llegada, que puede no traer el dato.
--
-- __Una llegada vacía no es un fallo, y por eso no lo decide 'pollStep'__: la
-- respuesta llegó entera y con su sello, y lo que falta es un campo de dentro.
-- Quien llama proyecta ese campo y esto decide qué queda en pantalla.
--
-- __Es idempotente en los dos casos__, que es lo que permite cablearlo a un
-- refresco que cambia dos veces por ciclo —al pedir y al llegar— sin filtrar antes.
keepLast :: Maybe a -> Kept a -> Kept a
keepLast (Just x) _ = Kept {keptValue = Just x, keptStale = False}
keepLast Nothing  k = k {keptStale = isJust (keptValue k)}

-- | Lo que el indicador necesita saber para pintarse.
--
-- __'indOrigin', 'indSource' e 'indFetched' solo significan algo con 'indShown' a
-- 'True'__: son la procedencia de lo que hay en pantalla, y sin pantalla no hay
-- procedencia. El único constructor legítimo es 'indicatorFrom', que mantiene
-- esa relación; el récord es plano por la misma razón que 'Poll' lo es, y no para
-- poder construirlo a mano.
--
-- 'indShown' no cambia ningún color —sin dato la procedencia es desconocida, que
-- ya es gris— pero sí el tooltip: «se muestra la tabla anterior» es falso cuando
-- no hay tabla anterior, que es justo el caso del fallo en la primera carga.
data Indicator = Indicator
  { indShown   :: Bool
    -- ^ Hay algo en pantalla, aunque sea de una respuesta vieja.
  , indOrigin  :: Maybe Origin
    -- ^ Procedencia de lo que se ve; 'Nothing' si la cabecera faltaba, no se
    -- reconoció o aún no ha llegado ninguna respuesta.
  , indSource  :: Maybe Source
    -- ^ Fuente de lo que se ve; 'Nothing' también cuando el dato es el respaldo
    -- estático, que no salió de ninguna.
  , indFetched :: Maybe Text
    -- ^ El instante tal cual viajó en la cabecera, sin formatear.
  , indFailed  :: Bool
    -- ^ El último refresco no volvió.
  , indRunning :: Bool
    -- ^ Consta que hay una sesión en curso. __No sale de los otros campos__: un
    -- dato recién traído fuera de sesión sigue siendo fresco, y el sello no dice
    -- nada de si hay carrera.
  }
  deriving stock (Eq, Show)

-- | El indicador que corresponde al estado del refresco y al de la sesión.
--
-- __Si la sesión rueda entra por argumento y no se saca del 'Poll'__, que es lo que
-- mantiene esto genérico en @a@ y sin conocer el dominio: quien llama tiene la tabla
-- y sabe proyectarla ('Widgets.LiveTiming.stateOf'), y aquí solo se decide qué
-- pintar con la respuesta.
indicatorFrom :: Bool -> Poll (Sourced a) -> Indicator
indicatorFrom running p = Indicator
  { indShown   = isJust (pollShown p)
  , indOrigin  = srcOrigin =<< pollShown p
  , indSource  = srcSource =<< pollShown p
  , indFetched = srcFetchedAt =<< pollShown p
  , indFailed  = pollLastFailed p
  , indRunning = running
  }

-- | Clase de la etiqueta, bloque y modificador.
--
-- __El modificador va siempre__, al revés que el de 'Widgets.LiveTiming.rowClass'
-- (2026-08-27, donde lo normal no lleva marca): aquí los estados son todos
-- igual de dignos de señalar, y el modificador ausente sería uno más sin color.
--
-- __Los modificadores son siete y las procedencias cuatro__, porque no hay
-- biyección: 'Common.Origin.Fresh' y 'Common.Origin.Recent' se separan según si el
-- último refresco volvió, y los dos que no volvieron caen en el mismo — un dato que
-- no se ha podido recargar se lee igual venga de donde venga.
-- 'Common.Origin.Cached' no se desdobla porque su fallo lo cuenta el tooltip
-- (2026-09-12).
--
-- __Sin sesión rodando los dos de refresco bueno caen juntos en el apagado__, que es
-- el séptimo. Los que sí son un fallo —guardado, de ejemplo, refresco caído— no lo
-- cruzan: pintarlos como el estado normal escondería lo único que el punto existe
-- para avisar.
--
-- Solo el del directo parpadea, y el parpadeo lo pone la hoja de estilos: aquí se
-- decide __cuándo__, no cómo.
indicatorClass :: Indicator -> Text
indicatorClass i = "widget__badge widget__badge--" <> modifier
  where
    modifier =
      case (indOrigin i, indFailed i) of
        (Just Fresh,  False) -> withSession "live"
        (Just Fresh,  True)  -> "stalled"
        (Just Recent, False) -> withSession "recent"
        (Just Recent, True)  -> "stalled"
        (Just Cached, _)     -> "saved"
        (Just Sample, _)     -> "sample"
        (Nothing,     _)     -> "unknown"

    withSession m
      | indRunning i = m
      | otherwise    = "idle"

-- | El texto del tooltip. __Nunca vacío__: la etiqueta dice siempre @Live@, así
-- que todo lo que la explica vive aquí.
--
-- __Se compone cuando hay dos cosas que decir.__ Un dato guardado cuyo refresco
-- además falló son dos hechos —de cuándo es lo que se ve, y que no se ha podido
-- cambiar— y el punto solo puede pintar uno. Los textos de la procedencia son
-- los de 'originNotice' tal cual, sin redactarlos otra vez: una segunda
-- redacción de lo mismo envejece mal.
--
-- El dato fresco es la excepción, y por dos motivos: si su refresco falló o si no
-- hay sesión rodando, «en vivo» ya no es cierto, así que no se compone — se
-- sustituye.
--
-- __Lo reciente conserva el suyo aunque comparta punto con el fresco fuera de
-- sesión.__ El punto es lo que se ve sin querer y tiene que estar quieto; el aviso
-- solo aparece al apuntarlo, y ahí decir de cuándo es el dato y por qué salió de lo
-- guardado vale más que repetir que no hay carrera.
--
-- __La fuente va delante y como etiqueta__, separada por @·@ y no por un punto: es
-- lo primero que se lee y no alarga la cadena de frases, que en el peor caso ya son
-- dos. El respaldo estático no lleva ninguna porque no salió de ninguna fuente.
indicatorTooltip :: Indicator -> Text
indicatorTooltip i = maybe body (\s -> sourceName s <> " · " <> body) (indSource i)
  where
    body =
      case (indOrigin i, indFailed i) of
        (Just Fresh, False) | indRunning i -> liveNotice
                            | otherwise    -> idleNotice
        (Just Fresh, True)  -> retryFailedNotice
        (origin, failed)    -> withFailure failed (noticeOf origin)

    noticeOf (Just origin) =
      fromMaybe unknownNotice (originNotice origin (fetchedAtLabel =<< indFetched i))
    noticeOf Nothing = unknownNotice

    -- Sin nada en pantalla el fallo no se menciona: el cuerpo de la tarjeta ya
    -- pinta su «Error al cargar», y «se muestra la tabla anterior» sería falso.
    withFailure True t | indShown i = t <> ". " <> retryFailedNotice
    withFailure _    t = t

-- | Lo que pasa cuando el refresco está volviendo bien, con la cabeza que cambia
-- delante.
--
-- __El periodo sale de 'liveRefreshSeconds' y no de un número escrito aquí__: si el
-- refresco cambia de ritmo, el tooltip no puede quedarse diciendo el viejo. Y va una
-- sola vez porque lo dicen los dos avisos: lo único que los separa es la cabeza.
refreshedEvery :: Text -> Text
refreshedEvery lead =
  lead <> ": se actualiza cada " <> T.pack (show liveRefreshSeconds) <> " s"

liveNotice :: Text
liveNotice = refreshedEvery "En vivo"

-- | __El periodo sigue siendo cierto sin sesión__, y por eso no se calla: la página
-- pregunta al mismo ritmo pase lo que pase; quien se frena por detrás es el backend,
-- y eso no lo decide este lado.
idleNotice :: Text
idleNotice = refreshedEvery "Sin sesión en marcha"

retryFailedNotice :: Text
retryFailedNotice = "No se pudo recargar: se muestra la tabla anterior"

-- | Cubre la cabecera ausente y la irreconocible, que 'Common.Origin.originFrom'
-- ya decidió no distinguir, y también el hueco antes de la primera respuesta.
unknownNotice :: Text
unknownNotice = "Procedencia desconocida"

-- | La hora de un instante ISO 8601, para leerla: de @2026-09-11T14:03:22Z@ sale
-- @14:03 UTC@.
--
-- __Es puro y no depende de @time@__, que es lo que permite probarlo en
-- @backend-test@ sin traer la dependencia a @common@. A cambio no interpreta la
-- fecha: recorta la hora y el minuto que vienen detrás de la @T@ y comprueba su
-- __forma__, no su rango — el emisor es el propio backend (2026-09-11 (b)), que
-- la escribe en UTC y sin fracción.
--
-- Un texto que no tenga esa forma da 'Nothing', y el tooltip va sin hora: un
-- 'Common.Origin.Cached' sin hora sigue avisando, porque perder el cuándo no
-- convierte el dato en fresco.
fetchedAtLabel :: Text -> Maybe Text
fetchedAtLabel raw
  | [hh, mm] <- T.splitOn ":" hhmm
  , twoDigits hh
  , twoDigits mm
  = Just (hhmm <> " UTC")
  | otherwise = Nothing
  where
    hhmm = T.take 5 (T.drop 1 (T.dropWhile (/= 'T') (T.strip raw)))
    twoDigits t = T.length t == 2 && T.all isDigit t

-- | El retraso más largo que acepta la página: 45 minutos, en segundos.
delayMaxSeconds :: Int
delayMaxSeconds = 2700

-- | El retraso con el que abre la página cuando la dirección no trae otro.
delayDefaultSeconds :: Int
delayDefaultSeconds = 41

-- | Un retraso tecleado, en el campo o en la dirección: segundos a secas (@41@) o
-- @m:ss@ (@0:41@), con los segundos a dos dígitos y por debajo de 60. Lo que no
-- tenga esa forma o pase de 'delayMaxSeconds' da 'Nothing'.
readDelay :: Text -> Maybe Int
readDelay raw = case T.splitOn ":" raw of
  [s] | digits s -> bounded (number s)
  [m, s]
    | digits m, T.length s == 2, digits s, number s < 60 ->
        bounded (60 * number m + number s)
  _ -> Nothing
  where
    digits t = not (T.null t) && T.all isDigit t
    number :: Text -> Integer
    number = T.foldl' (\acc c -> acc * 10 + toInteger (fromEnum c - fromEnum '0')) 0
    bounded n
      | n <= toInteger delayMaxSeconds = Just (fromInteger n)
      | otherwise                      = Nothing

-- | Lo que ha llegado, cada cosa con el segundo en que llegó, lo más nuevo delante.
-- Los segundos se cuentan desde que se abrió la página.
type Arrivals a = [(Int, a)]

-- | Una llegada más. Poda lo que ya no puede enseñarse con ningún retraso aceptado:
-- de lo que tiene 'delayMaxSeconds' o más, conserva solo lo más nuevo.
recordArrival :: Int -> a -> Arrivals a -> Arrivals a
recordArrival now x xs = (now, x) : young <> take 1 old
  where
    (young, old) = span (\(t, _) -> now - t < delayMaxSeconds) xs

-- | Lo más nuevo que llegó hace al menos @n@ segundos; 'Nothing' si nada es tan viejo.
delayedShown :: Int -> Int -> Arrivals a -> Maybe a
delayedShown n now = fmap snd . find (\(t, _) -> now - t >= n)

-- | El refresco visto con @n@ segundos de retraso: lo enseñado sale de
-- 'delayedShown', y lo que está en vuelo y el último fallo siguen siendo los de
-- ahora, así que una caída del servidor se ve al momento. Con @n <= 0@ es el
-- refresco tal cual.
delayedPoll :: Int -> Int -> Arrivals a -> Poll a -> Poll a
delayedPoll n now xs p
  | n <= 0    = p
  | otherwise = p {pollShown = delayedShown n now xs}

-- | Cuántos segundos faltan para que haya algo que enseñar con @n@ de retraso.
-- 'Nothing' si ya lo hay o si no hay retraso; sin ninguna llegada, cuenta como si
-- la primera fuera ahora.
delayWait :: Int -> Int -> Arrivals a -> Maybe Int
delayWait n now xs
  | n <= 0                         = Nothing
  | isJust (delayedShown n now xs) = Nothing
  | otherwise                      = Just (n - oldestAge)
  where
    oldestAge = case reverse xs of
      (t, _) : _ -> now - t
      []         -> 0

-- | El aviso de Live Timing mientras espera: @En espera · diferido 0:41 · empieza en
-- 32 s@.
delayWaitLabel :: Int -> Int -> Text
delayWaitLabel n wait =
  "En espera · diferido " <> formatClock ClockCompact n <> " · empieza en "
    <> formatCountdown wait

-- | El tooltip del indicador con el retraso añadido al final; sin retraso, igual.
delayNote :: Int -> Text -> Text
delayNote n tooltip
  | n <= 0    = tooltip
  | otherwise = tooltip <> " · diferido " <> formatClock ClockCompact n
