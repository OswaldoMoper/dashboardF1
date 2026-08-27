-- | Área Live timing — orquestación del caso de uso.
--
-- Coordina 'Handler.Live.Manager' (efectos: GET a OpenF1) y
-- 'Handler.Live.Helper' (mapeo puro) para producir @[LiveTimingRow]@, con la
-- cache STM del 'Env' como respaldo: intenta el fetch real; si funciona,
-- refresca la cache y devuelve; si falla (red/4xx/5xx) o no trae filas, sirve
-- la última respuesta buena, y si nunca la hubo, el dummy estático.
module Handler.Live.Context where

import           App                    (Env (..))
import           Common.Types           (DriverStatus (..), LiveTimingRow (..))
import           Config                 (Config)
import           Control.Concurrent.STM (atomically, readTVarIO, writeTVar)
import           Control.Exception      (SomeException, try)
import           Data.Maybe             (fromMaybe)
import           Handler.Live.Helper    (assembleRows)
import qualified Handler.Live.Manager   as Manager
import qualified Handler.OpenF1.Manager as OpenF1

-- | Devuelve la tabla de live timing (real de OpenF1, cache o dummy).
getLiveTiming :: Env -> IO [LiveTimingRow]
getLiveTiming env = do
  result <-
    try (fetchRows (envConfig env)) :: IO (Either SomeException [LiveTimingRow])
  case result of
    Right rows | not (null rows) -> do
      atomically (writeTVar (envLiveCache env) (Just rows))
      pure rows
    _ -> do
      cached <- readTVarIO (envLiveCache env)
      pure (fromMaybe dummy cached)

-- | Fetch de los 5 endpoints de OpenF1 y ensamblado puro a @[LiveTimingRow]@.
--
-- Recibe la 'Config' —y no el 'Env'— porque lo único que necesita de ella es el
-- techo de duración de los GET ('Handler.PublicApi.Manager'); la cache la maneja el
-- llamador. La firma de 'getLiveTiming' no cambia por esto.
--
-- __El quinto GET entra en el mismo @try@ que los otros cuatro, y eso es «todo o
-- nada» aceptado a sabiendas:__ si @\/session_result@ falla, la tabla entera cae
-- al respaldo aunque los cuatro primeros hayan contestado. Es el mismo criterio
-- que los 2 GET en serie de Historical (2026-07-29) y la
-- misma contrapartida ya anotada: más superficie
-- de fallo en un solo @try@. Degradar solo las marcas pediría un @try@ por GET,
-- que es un cambio de forma del área — y la asimetría estaría
-- mal puesta, porque las marcas ya tienen su propio degradado en el default de
-- 'Of1Result': un piloto ausente de la respuesta entra como @Running@.
fetchRows :: Config -> IO [LiveTimingRow]
fetchRows cfg = do
  drivers   <- OpenF1.fetchDrivers cfg
  positions <- Manager.fetchPositions cfg
  intervals <- Manager.fetchIntervals cfg
  laps      <- Manager.fetchLaps cfg
  results   <- Manager.fetchResults cfg
  pure (assembleRows drivers positions intervals laps results)

-- | Top 3 estático (respaldo cuando aún no hay respuesta real de OpenF1).
--
-- Los tres van 'Running': el dummy representa una sesión en marcha, y marcar un
-- abandono inventado haría creer en un incidente que nadie reportó.
dummy :: [LiveTimingRow]
dummy =
  [ LiveTimingRow 1 "VER" "Red Bull" "LEADER" "-" "1:29.345" Running
  , LiveTimingRow 2 "LEC" "Ferrari" "+1.234" "+1.234" "1:29.512" Running
  , LiveTimingRow 3 "NOR" "McLaren" "+3.877" "+2.643" "1:29.701" Running
  ]
