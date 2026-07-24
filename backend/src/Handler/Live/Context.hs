-- | Área Live timing — orquestación del caso de uso.
--
-- Coordina 'Handler.Live.Manager' (efectos: GET a OpenF1) y
-- 'Handler.Live.Helper' (mapeo puro) para producir @[LiveTimingRow]@, con la
-- cache STM del 'Env' como respaldo: intenta el fetch real; si funciona,
-- refresca la cache y devuelve; si falla (red/4xx/5xx) o no trae filas, sirve
-- la última respuesta buena, y si nunca la hubo, el dummy estático.
module Handler.Live.Context where

import           App                    (Env (..))
import           Common.Types           (LiveTimingRow (..))
import           Control.Concurrent.STM (atomically, readTVarIO, writeTVar)
import           Control.Exception      (SomeException, try)
import           Data.Maybe             (fromMaybe)
import           Handler.Live.Helper    (assembleRows)
import qualified Handler.Live.Manager   as Manager
import qualified Handler.OpenF1.Manager as OpenF1

-- | Devuelve la tabla de live timing (real de OpenF1, cache o dummy).
getLiveTiming :: Env -> IO [LiveTimingRow]
getLiveTiming env = do
  result <- try fetchRows :: IO (Either SomeException [LiveTimingRow])
  case result of
    Right rows | not (null rows) -> do
      atomically (writeTVar (envLiveCache env) (Just rows))
      pure rows
    _ -> do
      cached <- readTVarIO (envLiveCache env)
      pure (fromMaybe dummy cached)

-- | Fetch de los 4 endpoints de OpenF1 y ensamblado puro a @[LiveTimingRow]@.
fetchRows :: IO [LiveTimingRow]
fetchRows = do
  drivers   <- OpenF1.fetchDrivers
  positions <- Manager.fetchPositions
  intervals <- Manager.fetchIntervals
  laps      <- Manager.fetchLaps
  pure (assembleRows drivers positions intervals laps)

-- | Top 3 estático (respaldo cuando aún no hay respuesta real de OpenF1).
dummy :: [LiveTimingRow]
dummy =
  [ LiveTimingRow 1 "VER" "Red Bull" "LEADER" "-" "1:29.345"
  , LiveTimingRow 2 "LEC" "Ferrari" "+1.234" "+1.234" "1:29.512"
  , LiveTimingRow 3 "NOR" "McLaren" "+3.877" "+2.643" "1:29.701"
  ]
