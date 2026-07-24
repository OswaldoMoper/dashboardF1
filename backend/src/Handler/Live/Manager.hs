-- | Área Live timing — capa de efectos.
--
-- GET específicos de Live a los endpoints de series temporales de OpenF1
-- (@/position@, @/intervals@, @/laps@), decodificados a los tipos crudos de
-- 'Handler.Live.Helper'. El plumbing HTTP compartido ('fetchList', base de URL,
-- sesión @latest@) y el común @/drivers@ viven en 'Handler.OpenF1.Manager'. Sin
-- lógica de negocio: la orquestación vive en 'Handler.Live.Context' y el mapeo
-- puro en 'Handler.Live.Helper'.
module Handler.Live.Manager where

import           Handler.Live.Helper    (Of1Interval, Of1Lap, Of1Position)
import           Handler.OpenF1.Manager (fetchList)

fetchPositions :: IO [Of1Position]
fetchPositions = fetchList "position"

fetchIntervals :: IO [Of1Interval]
fetchIntervals = fetchList "intervals"

fetchLaps :: IO [Of1Lap]
fetchLaps = fetchList "laps"
