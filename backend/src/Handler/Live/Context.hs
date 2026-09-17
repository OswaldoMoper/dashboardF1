-- | Área Live timing — orquestación del caso de uso.
--
-- Coordina las dos fuentes —'Handler.Feed.Manager' y 'Handler.Live.Manager'— con
-- 'Handler.Live.Helper' (mapeo puro) para producir 'Common.Types.LiveTable', y la
-- cache STM del 'Env' como respaldo de las dos.
--
-- __Las dos fuentes dicen de qué sesión hablan, y no dicen lo mismo.__ El feed la
-- anuncia entera; OpenF1 da el tipo, el nombre y el gran premio, y __no publica
-- vuelta ni reloj__, así que esos dos salen vacíos. El estado sí lo sirve, pero
-- __deducido de sus horas previstas y marcado como tal__
-- ('Handler.Live.Helper.derivedState'): solo cuando la de fin quedó holgadamente
-- atrás, que es la única afirmación que esas horas sostienen. El único que sigue
-- sirviendo la tabla sin sesión es el respaldo estático, que no salió de ninguna —
-- y eso es «no se sabe», distinto de una sesión en blanco. La cache la conserva,
-- porque la guardó junto a sus filas.
--
-- __El feed va delante de OpenF1, y el orden lo decide qué contesta, no qué hora
-- es__ (2026-09-12): OpenF1 responde @401@ en todos sus endpoints mientras una
-- sesión rueda —incluidas las pasadas— y abre después. Son complementarias, así que
-- la escalera se alarga en vez de cambiar de fuente.
--
-- __Pero el feed sigue contestando con la sesión ya acabada__ (2026-09-13 (b)), al
-- contrario de lo que se creyó al montar esta escalera: durante horas devuelve la
-- clasificación final como si fuera de ahora, y solo más tarde se queda sin filas.
-- Por eso quién baja a OpenF1 lo decide el __estado de la sesión__
-- ('Handler.Live.Helper.sessionIsLive') y no que el feed conteste.
--
-- __Y antes de nada se mira si toca preguntarle__ ('Handler.Live.Helper.feedWindowOpen'):
-- la foto cuesta 16-23 s y fuera de sesión no trae nada que servir, así que el
-- calendario de OpenF1 dice cuándo abre la ventana y el propio feed, al dar la
-- sesión por finalizada, dice cuándo se cierra. Con la ventana cerrada la escalera
-- arranca directamente en OpenF1 y el refresco deja de pagar la foto.
--
-- Cada peldaño devuelve además __de dónde salió el dato__ —el peldaño y la fuente,
-- que son dos preguntas ('Common.Origin')— y, el de la cache, __cuándo llegó__.
module Handler.Live.Context where

import           App                    (Env (..), FeedWindow (..))
import           Common.Origin          (Origin (..), Source (..))
import           Common.Types           (DriverStatus (..), LiveTable (..),
                                         LiveTimingRow (..), SessionInfo)
import           Config                 (Config)
import           Control.Concurrent.STM (atomically, modifyTVar', readTVarIO,
                                         writeTVar)
import           Control.Exception      (SomeException, try)
import           Data.Maybe             (listToMaybe)
import           Data.Time.Clock        (UTCTime, getCurrentTime)
import           Handler.Feed.Helper    (FeedLive (..))
import qualified Handler.Feed.Manager   as Feed
import           Handler.Live.Helper    (FeedVerdict (..), Of1Interval,
                                         Of1Session (..), assembleRows,
                                         feedVerdict, feedWindowOpen,
                                         freezeClock, openf1Session)
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
  , lrTable     :: LiveTable
  }
  deriving (Eq, Show)

-- | Devuelve la tabla de live timing por la escalera de cuatro peldaños.
--
-- __Antes de la escalera se mira si la ventana está abierta__, y con ella cerrada el
-- feed no se toca: se arranca en OpenF1 y el refresco se ahorra los 16-23 s de la
-- foto. La ventana no puede dejar la pantalla sin directo — cerrada solo está
-- cuando hay calendario y dice que no hay sesión, o cuando el propio feed dio la
-- última por finalizada.
--
-- __El instante de la puerta y el de servir son dos y a propósito.__ Entre uno y
-- otro puede haber medio minuto de foto, y el reloj de la sesión hay que resolverlo
-- con el de responder, no con el de decidir.
--
-- __El fallo del feed y su lista vacía significan cosas distintas y se tratan
-- distinto__ (2026-09-12):
--
-- * __Filas de una sesión viva__ → son de la sesión en marcha, y es la única fuente
--   que las tiene.
-- * __Filas de una sesión finalizada__ → el dato ya no cambia y OpenF1 lo tiene
--   también, con la ventaja de que él sí sabe que es definitivo: se baja a él.
-- * __Tabla vacía__ → no hay sesión rodando, que es exactamente cuando OpenF1
--   contesta: se baja a él. La sesión que venga al lado no cambia esto: sin filas
--   no hay tabla que servir.
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
  now <- getCurrentTime
  window <- readTVarIO (envFeedWindow env)
  if feedWindowOpen now (fwStarts window) (fwFinalisedAt window)
    then do
      feed <-
        try (Feed.fetchFeedLive (envConfig env))
          :: IO (Either SomeException FeedLive)
      either (const (fromCache env)) (fromFeed env) feed
    else fromOpenF1 env

-- | Guarda cuándo se vio que el feed daba la sesión por finalizada, y vuelve a
-- pedir el calendario.
--
-- __Las dos cosas juntas y en este orden__, porque son el mismo suceso: la señal
-- cierra la ventana de la sesión que acaba, y el calendario nuevo es el que dice
-- cuándo abre la siguiente.
--
-- __Se ejecuta más de una vez sin daño__: el campo de estado repite @Finalised@
-- (2026-09-14 (k)), y tanto guardar el instante como releer el calendario dan lo
-- mismo aplicados dos veces. En la práctica ocurre una sola, porque lo que guarda
-- es justo lo que cierra la ventana.
noteFinalised :: Env -> UTCTime -> IO ()
noteFinalised env at = do
  atomically $
    modifyTVar' (envFeedWindow env) (\w -> w {fwFinalisedAt = Just at})
  refreshFeedWindow env

-- | Pide el calendario y guarda las horas de arranque.
--
-- __Un fallo no borra lo que había__, y la diferencia importa: OpenF1 devuelve
-- @401@ durante una sesión, así que el momento en que más se le pregunta es aquel
-- en que no contesta. Vaciar la lista por eso convertiría un calendario bueno en
-- «no se sabe», que hace pagar la foto en cada refresco.
--
-- Al arrancar el proceso la lista está vacía, así que hasta que esto salga bien una
-- vez se pregunta al feed siempre — el precio declarado de no perder el directo.
refreshFeedWindow :: Env -> IO ()
refreshFeedWindow env = do
  now <- getCurrentTime
  result <-
    try (Manager.fetchCalendar (envConfig env) now)
      :: IO (Either SomeException [Of1Session])
  either
    (const (pure ()))
    (\sessions ->
       atomically $
       modifyTVar'
         (envFeedWindow env)
         (\w -> w {fwStarts = map osStart sessions}))
    result

-- | El peldaño del feed: despacha sobre lo que 'feedVerdict' decidió.
--
-- __Aquí no hay ninguna regla, y es a propósito.__ Las tres ramas las decide una
-- función pura con suite; este módulo solo pone los efectos. Las dos que bajan a
-- OpenF1 se escriben por separado aunque hagan lo mismo, para que exponer el motivo
-- —lo que 2026-09-13 (f) quiere para el otro extremo de la escalera— no obligue a
-- volver a partirlas.
--
-- __El instante se toma una vez y sirve para las dos cosas:__ resolver el reloj de
-- la sesión y sellar la cache. Tomarlo dos veces dejaría guardado un reloj que dice
-- de un momento distinto al de su sello.
--
-- Bajar a OpenF1 __no refresca la cache con lo del feed__, y es lo que se quiere:
-- si OpenF1 tampoco contesta, lo guardado sigue siendo la última tabla buena con su
-- sesión, y es lo que 'fromCache' sirve.
fromFeed :: Env -> FeedLive -> IO LiveResult
fromFeed env live = do
  now <- getCurrentTime
  case feedVerdict now live of
    FeedServes table -> serveFresh env now Feed table
    FeedEmpty        -> fromOpenF1 env
    FeedFinalised    -> noteFinalised env now >> fromOpenF1 env

-- | El peldaño de OpenF1: los siete GET y el ensamblado, con la cache detrás.
--
-- La condición de éxito es __traer filas__ y no solo no fallar: una lista vacía es
-- una sesión sin parrilla publicada, y servirla dejaría la tabla en blanco teniendo
-- una anterior buena guardada.
--
-- __La sesión se pide solo si hay filas que nombrar__, y después de tenerlas: dos
-- peticiones por una tabla que se va a descartar no las paga nadie.
--
-- __La sesión que sale es la suya y no la del feed.__ Aunque el feed acabe de
-- anunciar una, no se hereda: OpenF1 pide siempre @session_key=latest@, y que su
-- «última» y la que el feed anuncia sean la misma no se puede comprobar desde aquí.
--
-- __El instante se toma una vez y sirve para las dos cosas__, igual que en
-- 'fromFeed': deducir el estado de la sesión y sellar la cache. Tomarlo dos veces
-- dejaría guardado un estado que habla de un momento distinto al de su sello.
fromOpenF1 :: Env -> IO LiveResult
fromOpenF1 env = do
  result <-
    try (fetchRows (envConfig env)) :: IO (Either SomeException [LiveTimingRow])
  case result of
    Right rows | not (null rows) -> do
      now <- getCurrentTime
      session <- fetchSessionOrNothing (envConfig env) now
      serveFresh env now OpenF1 (LiveTable session rows)
    _                            -> fromCache env

-- | Sirve lo que acaba de llegar y refresca la cache con su fuente.
--
-- __La cache guarda la tabla entera, sesión incluida__, para que lo guardado siga
-- diciendo de qué sesión era: filas de una sesión bajo el nombre de otra es peor
-- que filas sin nombre.
serveFresh :: Env -> UTCTime -> Source -> LiveTable -> IO LiveResult
serveFresh env now source table = do
  atomically (writeTVar (envLiveCache env) (Just (now, source, table)))
  pure (LiveResult Fresh (Just source) Nothing table)

-- | El respaldo: la última respuesta buena con su fuente y su instante, y si nunca
-- la hubo, el dummy — que no tiene fuente ni sesión porque no salió de ninguna.
--
-- __El reloj de lo guardado se congela__
-- ('Handler.Live.Helper.freezeClock'): el restante se resolvió al instante de
-- guardarlo, y seguir descontándolo afirmaría que el dato es de ahora. El nombre y
-- la vuelta sí se sirven tal cual — no caducan mientras la sesión sea la misma.
fromCache :: Env -> IO LiveResult
fromCache env = do
  cached <- readTVarIO (envLiveCache env)
  pure (maybe sample fromEntry cached)
  where
    fromEntry (fetchedAt, source, table) =
      LiveResult Cached (Just source) (Just fetchedAt) (frozen table)
    frozen table = table { liveSession = freezeClock <$> liveSession table }
    sample = LiveResult Sample Nothing Nothing (LiveTable Nothing dummy)

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

-- | Las dos peticiones que nombran la sesión, con su propio @try@: «no se sabe» si
-- no salen, en vez de propagar y tirar una tabla que ya está en la mano.
--
-- __Mismo criterio que 'fetchIntervalsOrEmpty'__ y por la misma razón: una tabla sin
-- nombre sigue siendo la tabla, y perderla por la celda de la cabecera es peor que
-- enseñarla sin ella.
--
-- __Pero las dos caen juntas, y ahí se aparta de él.__ La excepción de
-- @\/intervals@ existe porque su fallo es el __caso normal__ —el endpoint no existe
-- fuera de carrera—; que @\/sessions@ conteste y @\/meetings@ no, o al revés, no es
-- un régimen sino una avería. Partirlas serviría una sesión a medias sin que nadie
-- la hubiera pedido así.
fetchSessionOrNothing :: Config -> UTCTime -> IO (Maybe SessionInfo)
fetchSessionOrNothing cfg now = do
  result <-
    try (fetchSessionInfo cfg now)
      :: IO (Either SomeException (Maybe SessionInfo))
  pure (either (const Nothing) id result)

-- | @\/sessions@ y, con la clave que da, @\/meetings@.
--
-- __El arreglo vacío es «no se sabe» y no un fallo:__ OpenF1 responde con una lista,
-- y sin ninguna sesión dentro no hay nada que nombrar. Se lee la primera casando la
-- lista y no con 'Prelude.head', que sobre algo que llega de la red no se justifica.
--
-- El gran premio va aparte porque @\/sessions@ __no publica su nombre__: solo su
-- clave. Que su lista venga vacía deja la sesión sin gran premio, no sin sesión.
fetchSessionInfo :: Config -> UTCTime -> IO (Maybe SessionInfo)
fetchSessionInfo cfg now = do
  sessions <- Manager.fetchSession cfg
  case sessions of
    []      -> pure Nothing
    (s : _) -> do
      meetings <- Manager.fetchMeeting cfg (osMeeting s)
      pure (Just (openf1Session now s (listToMaybe meetings)))

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
