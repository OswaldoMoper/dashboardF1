-- | Área Live timing — orquestación del caso de uso.
--
-- Coordina 'Handler.Live.Manager' (efectos: GET a OpenF1) y
-- 'Handler.Live.Helper' (mapeo puro) para producir @[LiveTimingRow]@, con la
-- cache STM del 'Env' como respaldo: intenta el fetch real; si funciona,
-- refresca la cache y devuelve; si falla (red/4xx/5xx) o no trae filas, sirve
-- la última respuesta buena, y si nunca la hubo, el dummy estático.
--
-- Cada peldaño devuelve además __de dónde salió el dato__ ('Common.Origin') y, el
-- de la cache, __cuándo llegó__. La escalera siempre lo supo; hasta ahora lo tiraba.
module Handler.Live.Context where

import           App                    (Env (..))
import           Common.Origin          (Origin (..))
import           Common.Types           (DriverStatus (..), LiveTimingRow (..))
import           Config                 (Config)
import           Control.Concurrent.STM (atomically, readTVarIO, writeTVar)
import           Control.Exception      (SomeException, try)
import           Data.Time.Clock        (UTCTime, getCurrentTime)
import           Handler.Live.Helper    (Of1Interval, assembleRows)
import qualified Handler.Live.Manager   as Manager
import qualified Handler.OpenF1.Manager as OpenF1

-- | Devuelve la tabla de live timing (real de OpenF1, cache o dummy), con su
-- procedencia y, solo cuando sale de la cache, el instante en que llegó.
--
-- El instante va aparte y no dentro de 'Origin' por la razón que da
-- 'Common.Origin.fetchedAtHeader': de un dato fresco la hora es «ahora», y de uno
-- inventado no hay hora.
getLiveTiming :: Env -> IO (Origin, Maybe UTCTime, [LiveTimingRow])
getLiveTiming env = do
  result <-
    try (fetchRows (envConfig env)) :: IO (Either SomeException [LiveTimingRow])
  case result of
    Right rows | not (null rows) -> do
      now <- getCurrentTime
      atomically (writeTVar (envLiveCache env) (Just (now, rows)))
      pure (Fresh, Nothing, rows)
    _ -> do
      cached <- readTVarIO (envLiveCache env)
      pure (maybe (Sample, Nothing, dummy) fromCache cached)
  where
    fromCache (fetchedAt, rows) = (Cached, Just fetchedAt, rows)

-- | Fetch de los 5 endpoints de OpenF1 y ensamblado puro a @[LiveTimingRow]@.
--
-- Recibe la 'Config' —y no el 'Env'— porque lo único que necesita de ella es el
-- techo de duración de los GET ('Handler.PublicApi.Manager'); la cache la maneja el
-- llamador. La firma de 'getLiveTiming' no cambia por esto.
--
-- __Cuatro de los cinco GET son «todo o nada»; el de los intervalos no.__ Si falla
-- @\/drivers@, @\/position@, @\/laps@ o @\/session_result@, la tabla entera cae al
-- respaldo aunque los otros hayan contestado — el mismo criterio que los 2 GET en
-- serie de Historical (2026-07-29). @\/intervals@ está aparte
-- ('fetchIntervalsOrEmpty') porque su fallo __no es un fallo__: el endpoint no
-- existe fuera de carrera, y la tabla sin él sigue siendo la tabla.
--
-- Las marcas de @\/session_result@ tienen además su propio degradado en el default
-- de 'Handler.Live.Helper.Of1Result': un piloto ausente de la respuesta entra como
-- @Running@.
fetchRows :: Config -> IO [LiveTimingRow]
fetchRows cfg = do
  drivers   <- OpenF1.fetchDrivers cfg
  positions <- Manager.fetchPositions cfg
  intervals <- fetchIntervalsOrEmpty cfg
  laps      <- Manager.fetchLaps cfg
  results   <- Manager.fetchResults cfg
  pure (assembleRows drivers positions intervals laps results)

-- | @\/intervals@ con su propio @try@: una lista vacía si el GET no sale, en vez de
-- propagar y tirar los otros cuatro.
--
-- __La ausencia de intervalos es el caso normal, no la excepción.__ Medido el
-- 2026-09-12: el endpoint da @404 «No results found»@ en las tres prácticas y en la
-- Qualy, y solo la carrera lo publica — cuatro de las cinco sesiones del fin de
-- semana. Con los cinco GET en un @try@ común, ese 404 tiraba la tabla entera y la
-- página enseñaba el dummy con la red viva.
--
-- __La lista vacía no vacía las columnas:__ 'Handler.Live.Helper.assembleRows' las
-- rellena entonces desde la clasificación. Y la procedencia sigue siendo @Fresh@,
-- porque lo que se sirve acaba de llegar.
fetchIntervalsOrEmpty :: Config -> IO [Of1Interval]
fetchIntervalsOrEmpty cfg = do
  result <-
    try (Manager.fetchIntervals cfg) :: IO (Either SomeException [Of1Interval])
  pure (either (const []) id result)

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
