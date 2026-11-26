-- | Área Live timing — capa de efectos.
--
-- GET específicos de Live a los endpoints de series temporales de OpenF1
-- (@/position@, @/intervals@, @/laps@), a la clasificación (@/session_result@) y a
-- los dos que dicen de qué sesión se habla (@/sessions@, @/meetings@),
-- decodificados a los tipos crudos de
-- 'Handler.Live.Helper'. El plumbing HTTP compartido ('fetchList', base de URL,
-- opciones de selección) y el común @/drivers@ viven en 'Handler.OpenF1.Manager'.
-- Sin lógica de negocio: la orquestación vive en 'Handler.Live.Context' y el mapeo
-- puro en 'Handler.Live.Helper'.
module Handler.Live.Manager where

import           Config                      (Config (..))
import           Data.Aeson                  (FromJSON)
import           Data.Text                   (Text)
import           Data.Time.Clock             (UTCTime)
import           Handler.FastF1.Helper       (sessionTimeout)
import           Handler.FastF1.Manager      (fastf1OptionsWithin, runFastF1)
import           Handler.Live.Helper         (FastF1Lap, FastF1Session,
                                              FastF1Stints, Of1Interval, Of1Lap,
                                              Of1Listed, Of1Meeting,
                                              Of1Position, Of1Result,
                                              Of1Session)
import           Handler.OpenF1.Helper       (Of1Stint)
import           Handler.OpenF1.Manager      (endsAfter, fetchList,
                                              fetchListWith, meetingKey,
                                              meetingYear)
import           Network.HTTP.Req
import           Provenance                  (isoInstant)

-- Los cuatro reciben la 'Config' por lo mismo que 'fetchList': de ella sale el
-- techo de duración del intento. La opción dice de qué sesión
-- ('Handler.OpenF1.Manager.latestSession' o 'Handler.OpenF1.Manager.sessionKey').
fetchPositions :: Config -> Option 'Https -> IO [Of1Position]
fetchPositions cfg = fetchListWith cfg "position"

fetchIntervals :: Config -> Option 'Https -> IO [Of1Interval]
fetchIntervals cfg = fetchListWith cfg "intervals"

fetchLaps :: Config -> Option 'Https -> IO [Of1Lap]
fetchLaps cfg = fetchListWith cfg "laps"

-- | @/session_result@ es el único de los cuatro que no es serie temporal: una
-- fila por piloto, sin @date@ que reducir.
fetchResults :: Config -> Option 'Https -> IO [Of1Result]
fetchResults cfg = fetchListWith cfg "session_result"

-- | @/stints@ de la sesión que diga la opción.
fetchStints :: Config -> Option 'Https -> IO [Of1Stint]
fetchStints cfg = fetchListWith cfg "stints"

-- | @/sessions?year=@: todas las sesiones de un año, canceladas incluidas.
fetchYearSessions :: Config -> Integer -> IO [Of1Listed]
fetchYearSessions cfg year = fetchListWith cfg "sessions" (meetingYear year)

-- | @/fastf1/stints/{sesión}@ del microservicio, con la clave @AÑO-RONDA-SESIÓN@.
fetchFastF1Stints :: Config -> Text -> IO FastF1Stints
fetchFastF1Stints cfg = fetchFastF1 cfg "stints"

-- | 'fetchFastF1Stints' con el techo de la configuración aunque la clave sea de una sesión
-- concreta: para los stints de la última sesión sin @?session=@, que @dashboardF1-dev@ ya
-- tiene cargada (2026-11-18 (h)).
fetchLatestStints :: Config -> Text -> IO FastF1Stints
fetchLatestStints cfg = fetchFastF1Within cfg (cfgTelemetryTimeout cfg) "stints"

-- | @/fastf1/session/{sesión}@: de qué sesión habla el microservicio.
fetchFastF1Session :: Config -> Text -> IO FastF1Session
fetchFastF1Session cfg = fetchFastF1 cfg "session"

-- | @/fastf1/results/{sesión}@, con la forma de OpenF1 @\/session_result@ y ya ordenada.
fetchFastF1Results :: Config -> Text -> IO [Of1Result]
fetchFastF1Results cfg = fetchFastF1 cfg "results"

-- | @/fastf1/laps/{sesión}@, todas las vueltas de la sesión.
fetchFastF1Laps :: Config -> Text -> IO [FastF1Lap]
fetchFastF1Laps cfg = fetchFastF1 cfg "laps"

-- | @GET \/fastf1\/{endpoint}\/{sesión}@ del microservicio, decodificado. Lanza si el
-- servicio no contesta, si la sesión no resuelve (@404@) o si la respuesta trae otra
-- forma; qué hacer con eso lo decide quien llama.
fetchFastF1 :: FromJSON a => Config -> Text -> Text -> IO a
fetchFastF1 cfg endpoint key =
  fetchFastF1Within cfg (sessionTimeout (cfgTelemetryTimeout cfg) key) endpoint key

-- | 'fetchFastF1' con el techo dado, en segundos, en vez del de la sesión.
fetchFastF1Within :: FromJSON a => Config -> Int -> Text -> Text -> IO a
fetchFastF1Within cfg seconds endpoint key = runFastF1 cfg $ do
  res <-
    req
      GET
      (http (cfgTelemetryHost cfg) /: "fastf1" /: endpoint /: key)
      NoReqBody
      jsonResponse
      (fastf1OptionsWithin cfg seconds)
  pure (responseBody res)

-- | @/sessions@: de qué sesión habla la que OpenF1 sirve como @latest@.
--
-- Devuelve arreglo como los demás, y __vacío es una respuesta legítima__: significa
-- que no hay ninguna sesión que nombrar.
fetchSession :: Config -> IO [Of1Session]
fetchSession cfg = fetchList cfg "sessions"

-- | @/meetings@: el gran premio al que pertenece una sesión.
--
-- __Es el único GET de Live que no se pide por la sesión en curso__, sino por la
-- clave que 'fetchSession' acaba de dar; de ahí que use 'fetchListWith' en vez de
-- 'fetchList'.
--
-- __Y desde el 2026-09-18 es también el único que no sale en cada refresco:__
-- 'Handler.Live.Context.grandPrixName' lo llama solo ante una clave que no conoce,
-- porque el nombre de un gran premio no cambia.
fetchMeeting :: Config -> Int -> IO [Of1Meeting]
fetchMeeting cfg key = fetchListWith cfg "meetings" (meetingKey key)

-- | @/meetings?year=@: todos los grandes premios de un año, para nombrar el
-- calendario entero.
--
-- __Una petición y no una por gran premio.__ El calendario trae 9 grandes premios
-- distintos, y pedirlos de uno en uno son nueve peticiones seguidas contra un
-- servicio que limita por ritmo. Medido el 2026-09-17: el año entero son 27 grandes
-- premios en 20,5 KB y 0,63 s.
--
-- __Recibe el año por argumento__ y no lo saca del reloj, por lo mismo que
-- 'fetchCalendar' recibe el instante: la URL es función de sus argumentos y nada más.
fetchMeetings :: Config -> Integer -> IO [Of1Meeting]
fetchMeetings cfg year = fetchListWith cfg "meetings" (meetingYear year)

-- | El calendario: las sesiones que aún no han terminado a la hora dada.
--
-- __El instante entra por argumento__ y no se pide al reloj aquí, para que la URL
-- que esta función construye sea función de sus argumentos y nada más.
--
-- Medido el 2026-09-15: 45 sesiones en 16,6 KB y 0,62 s, sin acotar por arriba —así
-- que no hace falta inventar ninguna ventana de días— y sin filtrar por año, que
-- daría lo mismo hoy y se rompería en el cambio de año.
fetchCalendar :: Config -> UTCTime -> IO [Of1Session]
fetchCalendar cfg now = fetchListWith cfg "sessions" (endsAfter (isoInstant now))
