-- | Área Live timing — orquestación del caso de uso.
--
-- Coordina las dos fuentes —'Handler.Feed.Manager' y 'Handler.Live.Manager'— con
-- 'Handler.Live.Helper' (mapeo puro) para producir @[LiveTimingRow]@, y la cache STM
-- del 'Env' como respaldo de las dos.
--
-- __El feed va delante de OpenF1, y el orden lo decide qué contesta, no qué hora
-- es__ (2026-09-12): OpenF1 responde @401@ en todos sus endpoints mientras una
-- sesión rueda —incluidas las pasadas— y abre después; el feed publica mientras
-- rueda y calla después. Son complementarias, así que la escalera se alarga en vez
-- de cambiar de fuente.
--
-- Cada peldaño devuelve además __de dónde salió el dato__ —el peldaño y la fuente,
-- que son dos preguntas ('Common.Origin')— y, el de la cache, __cuándo llegó__.
module Handler.Live.Context where

import           App                    (Env (..))
import           Common.Origin          (Origin (..), Source (..))
import           Common.Types           (DriverStatus (..), LiveTimingRow (..))
import           Config                 (Config)
import           Control.Concurrent.STM (atomically, readTVarIO, writeTVar)
import           Control.Exception      (SomeException, try)
import           Data.Time.Clock        (UTCTime, getCurrentTime)
import           Handler.Feed.Helper    (FeedRow)
import qualified Handler.Feed.Manager   as Feed
import           Handler.Live.Helper    (Of1Interval, assembleRows, feedRows)
import qualified Handler.Live.Manager   as Manager
import qualified Handler.OpenF1.Manager as OpenF1

-- | La tabla de live timing con todo lo que hace falta para servirla: qué peldaño
-- la produjo, de qué fuente salió y, solo cuando sale de la cache, cuándo llegó.
--
-- El instante va aparte de 'Origin' por la razón que da
-- 'Common.Origin.fetchedAtHeader': de un dato fresco la hora es «ahora», y de uno
-- inventado no hay hora. La fuente va en 'Maybe' por la simétrica: el respaldo
-- estático no salió de ninguna.
data LiveResult = LiveResult
  { lrOrigin    :: Origin
  , lrSource    :: Maybe Source
  , lrFetchedAt :: Maybe UTCTime
  , lrRows      :: [LiveTimingRow]
  }
  deriving (Eq, Show)

-- | Devuelve la tabla de live timing por la escalera de cuatro peldaños.
--
-- __El fallo del feed y su lista vacía significan cosas distintas y se tratan
-- distinto__ (2026-09-12):
--
-- * __Filas__ → son de la sesión en marcha, y es la única fuente que las tiene.
-- * __Lista vacía__ → no hay sesión rodando, que es exactamente cuando OpenF1
--   contesta: se baja a él.
-- * __Excepción__ (microservicio apagado, @503@ del feed o techo vencido) → se sirve
--   desde la cache __sin__ intentar OpenF1.
--
-- Ese último peldaño tiene un precio que conviene tener escrito: con el
-- microservicio apagado y OpenF1 abierto —el estado más frecuente fuera de
-- sesión— la tabla sale de la cache aunque haya dato real disponible. Se eligió
-- a sabiendas, para que un feed roto durante la carrera no pague además los @401@
-- de OpenF1 antes de enseñar algo.
getLiveTiming :: Env -> IO LiveResult
getLiveTiming env = do
  feed <-
    try (Feed.fetchFeedRows (envConfig env)) :: IO (Either SomeException [FeedRow])
  case feed of
    Left _       -> fromCache env
    Right []     -> fromOpenF1 env
    Right raw    -> serveFresh env Feed (feedRows raw)

-- | El peldaño de OpenF1: los cinco GET y el ensamblado, con la cache detrás.
--
-- La condición de éxito es __traer filas__ y no solo no fallar: una lista vacía es
-- una sesión sin parrilla publicada, y servirla dejaría la tabla en blanco teniendo
-- una anterior buena guardada.
fromOpenF1 :: Env -> IO LiveResult
fromOpenF1 env = do
  result <-
    try (fetchRows (envConfig env)) :: IO (Either SomeException [LiveTimingRow])
  case result of
    Right rows | not (null rows) -> serveFresh env OpenF1 rows
    _                            -> fromCache env

-- | Sirve lo que acaba de llegar y refresca la cache con su fuente.
serveFresh :: Env -> Source -> [LiveTimingRow] -> IO LiveResult
serveFresh env source rows = do
  now <- getCurrentTime
  atomically (writeTVar (envLiveCache env) (Just (now, source, rows)))
  pure (LiveResult Fresh (Just source) Nothing rows)

-- | El respaldo: la última respuesta buena con su fuente y su instante, y si nunca
-- la hubo, el dummy — que no tiene fuente porque no salió de ninguna.
fromCache :: Env -> IO LiveResult
fromCache env = do
  cached <- readTVarIO (envLiveCache env)
  pure (maybe sample fromEntry cached)
  where
    fromEntry (fetchedAt, source, rows) =
      LiveResult Cached (Just source) (Just fetchedAt) rows
    sample = LiveResult Sample Nothing Nothing dummy

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

-- | Top 3 estático (respaldo cuando aún no hay respuesta real de ninguna fuente).
--
-- Los tres van 'Running': el dummy representa una sesión en marcha, y marcar un
-- abandono inventado haría creer en un incidente que nadie reportó.
dummy :: [LiveTimingRow]
dummy =
  [ LiveTimingRow 1 "VER" "Red Bull" "LEADER" "-" "1:29.345" Running
  , LiveTimingRow 2 "LEC" "Ferrari" "+1.234" "+1.234" "1:29.512" Running
  , LiveTimingRow 3 "NOR" "McLaren" "+3.877" "+2.643" "1:29.701" Running
  ]
