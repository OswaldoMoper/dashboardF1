-- | Bootstrap del backend: construye el 'Env' a partir de la 'Config'.
--
-- El 'Env' transporta la configuración y el estado mutable compartido entre
-- handlers. Fase 3: gana la cache en memoria (STM) de live timing, poblada por
-- 'Handler.Live.Context' con la última respuesta buena de cualquiera de sus dos
-- fuentes. Fase 4: las cajas de telemetría y comparación — importan más que las
-- otras tres porque el microservicio FastF1 es __nuestro__ y estará apagado la
-- mayor parte del tiempo, y son las dos que llevan __clave__, porque son los dos
-- endpoints que aceptan parámetros. El pool de PostgreSQL y otros clientes
-- externos aterrizan aquí conforme lleguen.
module App where

import           Common.Origin          (Source)
import           Common.Types           (DriverEntry, HistoricalStat,
                                         LapComparison, LiveTable,
                                         TelemetryPoint, TyreStint)
import           Config                 (Config)
import           Control.Concurrent.STM (TVar, newTVarIO)
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Text              (Text)
import           Data.Time.Clock        (UTCTime)

-- | Lo que se sabe sobre cuándo hay sesión que mirar.
--
-- __Las horas son las previstas por el calendario, no las reales__, y por eso quien
-- decide con ellas les resta un margen ('Handler.Live.Helper.feedWindowOpen'). Se
-- guardan como instantes y no como sesiones para que este módulo, que es infra, no
-- tenga que conocer los tipos crudos de una fuente.
--
-- __La lista vacía es «no se sabe» y hace preguntar__, no callar: no saber cuándo
-- empieza la siguiente sesión no es saber que no hay ninguna. Es el estado con el
-- que arranca el proceso y en el que se queda si OpenF1 no contesta — que es lo que
-- hace durante una sesión, justo cuando más falta haría saberlo.
data FeedWindow = FeedWindow
  { fwStarts      :: [UTCTime]
    -- ^ Horas de arranque previstas de las sesiones que aún no habían terminado
    -- cuando se pidió el calendario.
  , fwFinalisedAt :: Maybe UTCTime
    -- ^ Cuándo se vio por última vez que el feed daba una sesión por finalizada.
    -- Es lo que cierra la ventana, en vez de una hora de fin: una carrera alargada
    -- por bandera roja sigue cubierta sin inventar cuánto puede alargarse.
  }
  deriving (Eq, Show)

data Env = Env
  { envConfig          :: Config
  , envLiveCache       :: TVar (Maybe (UTCTime, Source, LiveTable))
    -- ^ Última respuesta buena de @/api/live@, __el instante en que llegó y de
    -- qué fuente salió__ (respaldo si ninguna de las dos contesta).
    --
    -- El instante es lo que deja a 'Handler.Live' emitir @X-Data-Fetched-At@
    -- cuando sirve desde aquí ('Common.Origin.Cached'). Va en la misma caja y no
    -- en una aparte porque dato e instante son un solo hecho: dos cajas se
    -- escribirían en dos pasos y podrían contar historias distintas.
    --
    -- La fuente va por lo mismo y por una razón propia: quien sirve desde aquí
    -- tiene que poder decir de dónde salió lo guardado, o el tooltip afirmaría
    -- una fuente que no es. Guardarla aquí es lo que impide que se adivine.
    --
    -- __Se guarda la tabla entera y no solo sus filas__, por el mismo argumento
    -- llevado un paso más: lo guardado tiene que poder decir __de qué sesión__
    -- era. Lo único que caduca de ella es el reloj, y de pararlo se encarga
    -- 'Handler.Live.Helper.freezeClock' al servir.
  , envTyreCache       :: TVar (Maybe [TyreStint])
    -- ^ Última respuesta buena de @/api/tyre-strategy@ (respaldo si OpenF1 falla).
  , envHistoricalCache :: TVar (Maybe [HistoricalStat])
    -- ^ Última respuesta buena de @/api/historical@ (respaldo si Jolpica falla).
  , envTelemetryCache  :: TVar (Map (Text, Text) [TelemetryPoint])
    -- ^ Última respuesta buena de @/api/telemetry@ __por clave__ @(sesión,
    -- piloto)@ ya resuelta (respaldo si el microservicio FastF1 no responde).
    --
    -- Es la única de las cuatro cajas que no es un @Maybe@, y la diferencia no
    -- es de rendimiento sino de __correctitud__: desde que el endpoint acepta
    -- parámetros (2026-08-01), una caja única serviría la
    -- última respuesta buena de @all@ a quien pidió un piloto concreto — datos
    -- de otros coches presentados como suyos. Con clave, una combinación nunca
    -- pedida degrada al dummy, que es honesto.
  , envComparisonCache :: TVar (Map (Text, Text) LapComparison)
    -- ^ Última respuesta buena de @/api/comparison@ __por clave__ @(sesión,
    -- coches)@ ya resuelta (respaldo si el microservicio FastF1 no responde).
    --
    -- Nace con clave, sin pasar por la caja única de las tres primeras: el
    -- endpoint acepta parámetros desde el primer día, así que la decisión del
    -- 2026-08-01 se __aplica__, no se vuelve a discutir. Es también la única caja
    -- cuyo valor no es una lista — 'LapComparison' es un objeto, y de ahí que el
    -- criterio de fallo del 'Handler.Comparison.Context' sea @null . lcDelta@ y no
    -- \"lista vacía\".
  , envFeedWindow      :: TVar FeedWindow
    -- ^ Lo que el backend sabe sobre __cuándo merece la pena pedirle la foto al
    -- feed__, que cuesta 16-23 s y fuera de sesión no trae nada que servir.
    --
    -- No es una cache: no guarda una respuesta para volver a servirla, sino lo que
    -- hace falta para decidir si preguntar. De ahí que no caduque ni tenga
    -- respaldo — su valor vacío significa «se pregunta», no «se sirve el dummy».
  , envDriversCache    :: TVar (Map Text [DriverEntry])
    -- ^ Última parrilla buena de @/api/drivers@ __por sesión__ (respaldo si el
    -- microservicio FastF1 no responde).
    --
    -- Sexta caja, y la primera cuya clave tiene una sola componente: el endpoint
    -- no filtra por coche, así que @session_key@ la determina entera. Que la
    -- lleve es correctitud y no rendimiento — la parrilla es la de __esa__
    -- sesión, y un sustituto o un tercer coche en libres la cambian, así que una
    -- caja única serviría la de otra sesión presentada como la pedida.
  }

-- El récord se construye __por nombre__ y no por posición: un campo nuevo en medio
-- no borra ninguna línea, así que con posiciones el compilador solo se queja cuando
-- los tipos no casan y calla cuando casan.
mkEnv :: Config -> IO Env
mkEnv cfg = do
  liveCache <- newTVarIO Nothing
  tyreCache <- newTVarIO Nothing
  historicalCache <- newTVarIO Nothing
  telemetryCache <- newTVarIO Map.empty
  comparisonCache <- newTVarIO Map.empty
  feedWindow <- newTVarIO (FeedWindow [] Nothing)
  driversCache <- newTVarIO Map.empty
  pure
    Env
      { envConfig          = cfg
      , envLiveCache       = liveCache
      , envTyreCache       = tyreCache
      , envHistoricalCache = historicalCache
      , envTelemetryCache  = telemetryCache
      , envComparisonCache = comparisonCache
      , envFeedWindow      = feedWindow
      , envDriversCache    = driversCache
      }
