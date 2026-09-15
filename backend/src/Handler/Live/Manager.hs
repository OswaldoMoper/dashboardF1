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

import           Config                 (Config)
import           Handler.Live.Helper    (Of1Interval, Of1Lap, Of1Meeting,
                                         Of1Position, Of1Result, Of1Session)
import           Handler.OpenF1.Manager (fetchList, fetchListWith, meetingKey)

-- Los cuatro reciben la 'Config' por lo mismo que 'fetchList': de ella sale el
-- techo de duración del intento.
fetchPositions :: Config -> IO [Of1Position]
fetchPositions cfg = fetchList cfg "position"

fetchIntervals :: Config -> IO [Of1Interval]
fetchIntervals cfg = fetchList cfg "intervals"

fetchLaps :: Config -> IO [Of1Lap]
fetchLaps cfg = fetchList cfg "laps"

-- | @/session_result@ es el único de los cuatro que no es serie temporal: una
-- fila por piloto, sin @date@ que reducir.
fetchResults :: Config -> IO [Of1Result]
fetchResults cfg = fetchList cfg "session_result"

-- | @/sessions@: de qué sesión habla la que OpenF1 sirve como @latest@.
--
-- Devuelve arreglo como los demás, y __vacío es una respuesta legítima__: significa
-- que no hay ninguna sesión que nombrar.
fetchSession :: Config -> IO [Of1Session]
fetchSession cfg = fetchList cfg "sessions"

-- | @/meetings@: el gran premio al que pertenece una sesión.
--
-- __Es el único de los siete que no se pide por la sesión en curso__, sino por la
-- clave que 'fetchSession' acaba de dar; de ahí que use 'fetchListWith' en vez de
-- 'fetchList'.
fetchMeeting :: Config -> Int -> IO [Of1Meeting]
fetchMeeting cfg key = fetchListWith cfg "meetings" (meetingKey key)
