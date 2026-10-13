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

import           Common.Origin           (Source)
import           Common.Types            (DriverEntry, HistoricalStat,
                                          LapComparison, LiveTable,
                                          TelemetryPoint, TyreStint)
import           Config                  (Config)
import           Control.Concurrent.MVar (MVar, newMVar)
import           Control.Concurrent.STM  (TVar, newTVarIO)
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Text               (Text)
import           Data.Time.Clock         (UTCTime)

-- | Una sesión del calendario, con lo que el backend necesita de ella.
--
-- __Es un tipo de aquí y no el crudo de OpenF1__, que es lo que mantiene a este
-- módulo —infra— sin conocer los tipos de una fuente. Antes se guardaban solo
-- instantes por esa misma razón; dejó de bastar cuando hubo que poder decir __cuál__
-- es la sesión siguiente y no solo cuándo empieza.
--
-- __Las horas son las previstas, no las reales.__ La de arranque llega tarde y la de
-- fin llega pronto —cuatro minutos y trece en la carrera 11369—, así que quien
-- decide con ellas les pone un margen en vez de creérselas
-- ('Handler.Live.Helper.feedWindowOpen', 'Handler.Live.Helper.endMargin').
--
-- __El gran premio puede venir en blanco__: sale de una petición distinta a la del
-- calendario, y sin él la sesión sigue sabiendo cómo se llama y cuándo es.
data ScheduledSession = ScheduledSession
  { ssName      :: Text
    -- ^ @\"Practice 1\"@, @\"Race\"@, @\"Sprint\"@. __El nombre y no el tipo__: es
    -- lo único que distingue un Sprint de una carrera larga, que comparten tipo.
  , ssMeeting   :: Int     -- ^ Clave del gran premio, que es por donde se juntan.
  , ssGrandPrix :: Text    -- ^ @\"Azerbaijan Grand Prix\"@, o vacío si no se supo.
  , ssStart     :: UTCTime
  , ssEnd       :: UTCTime
  }
  deriving (Eq, Show)

-- | Lo que se sabe sobre cuándo hay sesión que mirar, y cuál es la siguiente.
--
-- __La lista vacía es «no se sabe» y hace preguntar__, no callar: no saber cuándo
-- empieza la siguiente sesión no es saber que no hay ninguna. Es el estado con el
-- que arranca el proceso y en el que se queda si OpenF1 no contesta — que es lo que
-- hace durante una sesión, justo cuando más falta haría saberlo.
data FeedWindow = FeedWindow
  { fwSessions    :: [ScheduledSession]
    -- ^ Las sesiones que aún no habían terminado cuando se pidió el calendario.
  , fwFinalisedAt :: Maybe UTCTime
    -- ^ Cuándo se vio por última vez que el feed daba una sesión por finalizada.
    -- Es lo que cierra la ventana, en vez de una hora de fin: una carrera alargada
    -- por bandera roja sigue cubierta sin inventar cuánto puede alargarse.
  }
  deriving (Eq, Show)

-- | Los sectores de cada vuelta que se vio en una foto del feed, de una sola sesión.
--
-- __Vive en memoria:__ un reinicio del backend la vacía, y las vueltas de antes salen
-- sin sectores. La llena y la lee 'Handler.Live.Helper.rememberSectors'.
data SectorMemory = SectorMemory
  { smSession :: Maybe (Text, Text)
    -- ^ El gran premio y la sesión a los que pertenece; 'Nothing' antes de la primera
    -- foto que nombre una.
  , smLaps    :: Map Text (Map Text [Text])
    -- ^ Por piloto, los tres sectores de cada tiempo de vuelta.
  }
  deriving (Eq, Show)

emptySectorMemory :: SectorMemory
emptySectorMemory = SectorMemory Nothing Map.empty

data Env = Env
  { envConfig          :: Config
  , envLiveCache       :: TVar (Maybe (UTCTime, Source, LiveTable))
    -- ^ Última respuesta buena de @/api/live@, __el instante en que llegó y de
    -- qué fuente salió__.
    --
    -- __Es lo que sirve el endpoint, no un respaldo__: desde que la refresca un reloj
    -- propio ('Handler.Live.Context.liveClock'), quien pregunta la lee y no baja, y
    -- por eso el gasto a OpenF1 dejó de depender de cuántas pantallas miren. Sale a
    -- la red solo con la caja vacía.
    --
    -- __Su edad decide el sello__ ('Handler.Live.Helper.servedFromBox'), y ahí es
    -- donde el reposo, un reloj muerto y un rechazo de la fuente se cuentan solos:
    -- los tres dejan la caja vieja, y vieja se sirve con el sello que dice que no se
    -- ha vuelto a saber.
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
  , envTyreCache       :: TVar (Maybe (UTCTime, [TyreStint]))
    -- ^ Última respuesta buena de @/api/tyre-strategy@ (respaldo si OpenF1 falla),
    -- con la hora en que llegó: la que sale en @X-Data-Fetched-At@ al servirla.
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
  , envComparisonCache :: TVar (Map (Text, Text, Int) LapComparison)
    -- ^ Última respuesta buena de @/api/comparison@ __por clave__ @(sesión,
    -- coches, muestras)@ ya resuelta (respaldo si el microservicio FastF1 no
    -- responde).
    --
    -- Nace con clave, sin pasar por la caja única de las tres primeras: el
    -- endpoint acepta parámetros desde el primer día, así que la decisión del
    -- 2026-08-01 se __aplica__, no se vuelve a discutir. Es también la única caja
    -- cuyo valor no es una lista — 'LapComparison' es un objeto, y de ahí que el
    -- criterio de fallo del 'Handler.Comparison.Context' sea «ningún coche con
    -- sectores» y no \"lista vacía\".
  , envFeedWindow      :: TVar FeedWindow
    -- ^ Lo que el backend sabe sobre __cuándo merece la pena pedirle la foto al
    -- feed__ —que cuesta 16-23 s y fuera de sesión no trae nada que servir— y
    -- __cuál es la sesión siguiente__, que sale del mismo calendario.
    --
    -- No es una cache: no guarda una respuesta para volver a servirla, sino lo que
    -- hace falta para decidir si preguntar. De ahí que no caduque ni tenga
    -- respaldo — su valor vacío significa «se pregunta», no «se sirve el dummy».
  , envMeetingNames    :: TVar (Map Int Text)
    -- ^ El nombre de cada gran premio __por su clave__, para no volver a
    -- preguntarlo.
    --
    -- __No es una cache de respaldo sino un ahorro de peticiones__, y esa es la
    -- diferencia con las seis de arriba: aquí no se guarda una respuesta para
    -- servirla cuando la fuente calle, sino un dato que __no cambia__ para no tener
    -- que pedirlo otra vez. Un gran premio no se renombra a mitad de fin de semana.
    --
    -- Lo justifica un presupuesto medido el 2026-09-17: OpenF1 acepta __30
    -- peticiones por minuto__ y las dice él mismo en su rechazo, mientras que un
    -- refresco de @\/api\/live@ costaba siete. Ésta era una de las siete, y se pagaba
    -- cada diez segundos para traducir una clave al mismo nombre.
    --
    -- __Nace llena y casi nunca falla__: el calendario ya pide los grandes premios
    -- del año entero de una sola vez ('Handler.Live.Context.fetchSchedule'), así que
    -- desde el primer calendario bueno están los 27. La preguntita de una clave
    -- suelta queda para la sesión que ya no está en el calendario — el calendario
    -- solo guarda lo que no ha terminado, y OpenF1 sirve como actual __la última__.
    --
    -- __Un nombre en blanco no entra__, o el fallo se volvería permanente: no
    -- saberlo hoy no es saber que no lo tiene.
  , envLiveAsked       :: TVar (Maybe UTCTime)
    -- ^ Cuándo preguntó alguien por última vez a @/api\/live@. @Nothing@ es «nunca»,
    -- y es el estado con el que arranca el proceso.
    --
    -- __No es una cache ni un freno sino la señal de que hay quien mira__, y de eso
    -- depende que el reloj del directo baje o se pare, y con sesión, que pida la foto
    -- del feed o se la salte porque la página ya la pidió
    -- ('Handler.Live.Helper.clockVerdict'). Sin ella, un backend levantado y sin
    -- nadie delante gastaría presupuesto todo el día.
    --
    -- Lo escribe cada petición y lo lee solo el reloj, así que no compite con nadie.
  , envLiveTried       :: TVar (Maybe UTCTime)
    -- ^ Cuándo se __intentó__ por última vez llenar la caja vacía, salga bien o mal.
    --
    -- __Va aparte de 'envLiveCache' porque son dos hechos distintos__, y confundirlos
    -- fue el defecto: aquélla guarda el último __acierto__, así que un rechazo de la
    -- fuente no la movía, el freno que la consultaba se soltaba, y cada petición
    -- volvía a salir a la red — justo cuando el presupuesto ya estaba agotado.
    --
    -- __Solo la mira la bajada en frío__ ('Handler.Live.Context.warmUp'): con la caja
    -- llena nadie baja desde el endpoint, y el reloj tiene su propio ritmo.
  , envLiveGate        :: MVar ()
    -- ^ El cerrojo de la bajada en frío: con la caja vacía, __solo una petición sale
    -- a la red__ y las demás esperan a que la llene.
    --
    -- Es lo que impide que dos peticiones que llegan a la vez paguen las dos, que era
    -- lo que quedaba vivo del defecto de las dos llamadas simultáneas. Quien espera
    -- vuelve a mirar la caja al entrar: si otro la llenó, la sirve en vez de bajar.
    --
    -- __Solo cubre el camino en frío.__ Con la caja llena nadie baja desde el
    -- endpoint, así que no hay nada que serializar.
  , envDriversCache    :: TVar (Map Text [DriverEntry])
    -- ^ Última parrilla buena de @/api/drivers@ __por sesión__ (respaldo si el
    -- microservicio FastF1 no responde).
    --
    -- Sexta caja, y la primera cuya clave tiene una sola componente: el endpoint
    -- no filtra por coche, así que @session_key@ la determina entera. Que la
    -- lleve es correctitud y no rendimiento — la parrilla es la de __esa__
    -- sesión, y un sustituto o un tercer coche en libres la cambian, así que una
    -- caja única serviría la de otra sesión presentada como la pedida.
  , envLapSectors      :: TVar SectorMemory
    -- ^ Los sectores de las vueltas de la sesión en curso, para dar los de la mejor:
    -- la foto del feed solo trae los de la última.
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
  meetingNames <- newTVarIO Map.empty
  driversCache <- newTVarIO Map.empty
  liveAsked <- newTVarIO Nothing
  liveTried <- newTVarIO Nothing
  liveGate <- newMVar ()
  lapSectors <- newTVarIO emptySectorMemory
  pure
    Env
      { envConfig          = cfg
      , envLiveCache       = liveCache
      , envTyreCache       = tyreCache
      , envHistoricalCache = historicalCache
      , envTelemetryCache  = telemetryCache
      , envComparisonCache = comparisonCache
      , envFeedWindow      = feedWindow
      , envMeetingNames    = meetingNames
      , envLiveAsked       = liveAsked
      , envLiveTried       = liveTried
      , envLiveGate        = liveGate
      , envDriversCache    = driversCache
      , envLapSectors      = lapSectors
      }
