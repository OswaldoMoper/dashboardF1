-- | Área Live timing — capa de efectos.
--
-- GET específicos de Live a los endpoints de series temporales de OpenF1
-- (@/position@, @/intervals@, @/laps@), decodificados a los tipos crudos de
-- 'Handler.Live.Helper'. El plumbing HTTP compartido ('fetchList', base de URL,
-- sesión @latest@) y el común @/drivers@ viven en 'Handler.OpenF1.Manager'. Sin
-- lógica de negocio: la orquestación vive en 'Handler.Live.Context' y el mapeo
-- puro en 'Handler.Live.Helper'.
module Handler.Live.Manager where

import           Config                 (Config)
import           Handler.Live.Helper    (Of1Interval, Of1Lap, Of1Position)
import           Handler.OpenF1.Manager (fetchList)

-- Los tres reciben la 'Config' por lo mismo que 'fetchList': de ella sale el techo
-- de duración del intento.
fetchPositions :: Config -> IO [Of1Position]
fetchPositions cfg = fetchList cfg "position"

fetchIntervals :: Config -> IO [Of1Interval]
fetchIntervals cfg = fetchList cfg "intervals"

fetchLaps :: Config -> IO [Of1Lap]
fetchLaps cfg = fetchList cfg "laps"
