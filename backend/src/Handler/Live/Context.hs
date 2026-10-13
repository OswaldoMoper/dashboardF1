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
-- ('Common.Types.sessionIsLive') y no que el feed conteste.
--
-- __Y antes de nada se mira si toca preguntarle__ ('Handler.Live.Helper.feedWindowOpen'):
-- la foto cuesta 16-23 s y fuera de sesión no trae nada que servir, así que el
-- calendario de OpenF1 dice cuándo abre la ventana y el propio feed, al dar la
-- sesión por finalizada, dice cuándo se cierra. Con la ventana cerrada la escalera
-- arranca directamente en OpenF1 y el refresco deja de pagar la foto.
--
-- __Y a OpenF1 no baja quien pregunta, sino un reloj propio__ ('liveClock'): acepta
-- 30 peticiones por minuto, y con el endpoint bajando el gasto crecía con cada
-- pantalla. El endpoint solo lee la caja, y únicamente sale a la red cuando está
-- vacía. El feed no tiene presupuesto, así que la página pide su foto a su ritmo; el
-- mismo reloj la pide solo cuando nadie lo ha hecho en su periodo, también sin nadie
-- mirando.
--
-- Cada peldaño devuelve además __de dónde salió el dato__ —el peldaño y la fuente,
-- que son dos preguntas ('Common.Origin')— y, lo que sale de lo guardado, __cuándo
-- llegó__.
module Handler.Live.Context where

import           App                     (Env (..), FeedWindow (..),
                                          ScheduledSession (..))
import           Common.Origin           (Origin (..), Source (..))
import           Common.Types            (DriverStatus (..), LiveTable (..),
                                          LiveTimingRow (..), SessionInfo,
                                          UpNext (..), emptyLiveRow)
import           Config                  (Config)
import           Control.Concurrent      (threadDelay)
import           Control.Concurrent.MVar (withMVar)
import           Control.Concurrent.STM  (atomically, modifyTVar', readTVar,
                                          readTVarIO, writeTVar)
import           Control.Exception       (SomeException, displayException, try)
import           Control.Monad           (forever, void, when)
import           Data.List               (nub)
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Maybe              (listToMaybe)
import           Data.Text               (Text)
import qualified Data.Text               as T
import qualified Data.Text.IO            as TIO
import           Data.Time.Calendar      (toGregorian)
import           Data.Time.Clock         (UTCTime, getCurrentTime, utctDay)
import           Handler.Feed.Helper     (FeedLive (..))
import qualified Handler.Feed.Manager    as Feed
import           Handler.Live.Helper     (ClockVerdict (..), FeedVerdict (..),
                                          Of1Interval, Of1Meeting (..),
                                          Of1Session (..), assembleRows,
                                          clockVerdict, closesFeedWindow,
                                          feedVerdict, feedWindowOpen,
                                          fetchFailure, finaliseBox,
                                          freezeClock, inheritFinalised,
                                          meetingNames, openf1ClockPeriod,
                                          openf1Session, rememberSectors,
                                          schedule, servedFromBox, stillRecent,
                                          upNext, withLapSectors)
import qualified Handler.Live.Manager    as Manager
import qualified Handler.OpenF1.Manager  as OpenF1
import           Outcome                 (httpStatusOf)
import           Provenance              (Provenanced (..))
import           System.IO               (stderr)

-- | La tabla de live timing con su procedencia.
type LiveResult = Provenanced LiveTable

-- | La tabla de live timing, por la escalera de cuatro peldaños.
--
-- Antes de la escalera se mira la ventana del feed; cerrada, se arranca en OpenF1
-- sin pagar la foto. Solo está cerrada cuando el calendario dice que no hay sesión
-- o cuando el feed dio la última por finalizada (2026-09-15 (c) y (d)).
--
-- Con la ventana abierta decide lo que devuelve el feed (2026-09-12 (u) y
-- 2026-09-14 (i)):
--
-- * __filas de una sesión viva__ → se sirven: es la única fuente que las tiene;
-- * __filas de una sesión finalizada__ → se baja a OpenF1;
-- * __tabla vacía__ → se baja a OpenF1, aunque el feed nombre una sesión;
-- * __excepción__ (microservicio apagado, @503@ del feed o techo vencido) → la
--   cache, __sin__ intentar OpenF1. Con el microservicio apagado y OpenF1 abierto,
--   la tabla sale de la cache aunque haya dato real.
--
-- El instante de la puerta no es el de servir: entre uno y otro puede haber medio
-- minuto de foto, y el reloj de la sesión se resuelve al responder.
getLiveTiming :: Env -> IO LiveResult
getLiveTiming env = do
  now <- getCurrentTime
  atomically $ writeTVar (envLiveAsked env) (Just now)
  window <- readTVarIO (envFeedWindow env)
  result <-
    if feedWindowOpen now (map ssStart (fwSessions window)) (fwFinalisedAt window)
      then do
        feed <-
          try (Feed.fetchFeedLive (envConfig env))
            :: IO (Either SomeException FeedLive)
        either (const (fromCache env)) (fromFeed env) feed
      else fromOpenF1 env
  withUpNext env result

-- | Deja dicho en el log por qué no salió un fetch.
--
-- __Existe porque un @try@ que devuelve el respaldo convierte cuatro causas en una
-- sola cara.__ Conexión rechazada, techo vencido, respuesta con otra forma y
-- rechazo por ritmo salen todas como «sirvo lo guardado», y desde fuera no hay
-- forma de saber cuál fue: hasta el 2026-09-17 la del ritmo hubo que deducirla
-- midiendo la API por separado.
--
-- __Es el único efecto de esto__; qué dice la línea lo decide
-- 'Handler.Live.Helper.fetchFailure', que es pura. Va a @stderr@ y no a @stdout@
-- porque es un aviso y no la salida del programa — 'Main' imprime ahí su única
-- línea, la del arranque.
--
-- __No atrapa nada ni cambia el desenlace:__ quien llama sigue decidiendo qué se
-- sirve, y esto solo lo cuenta.
--
-- __El reloj se lee aquí y no lo recibe el llamador__, que es la excepción al «el
-- instante se toma una vez»: en el camino del fallo no hay nada más que fechar —no
-- se sella cache ni se resuelve reloj de sesión—, así que una segunda lectura no
-- puede contradecir a ninguna.
noteFailure :: Text -> SomeException -> IO ()
noteFailure what e = do
  now <- getCurrentTime
  TIO.hPutStrLn stderr $
    fetchFailure now what (fst <$> httpStatusOf e) (T.pack (displayException e))

-- | Resuelve qué viene después, __lo último antes de servir__.
--
-- __Va aquí y no en cada peldaño__ por dos razones. La primera es que así lo tienen
-- los cuatro, incluidos la cache y el dato de ejemplo: lo que viene después no
-- depende de qué fuente trajo las filas. La segunda es que __depende de «ahora»__, y
-- calcularlo antes de la foto del feed —que cuesta 16-23 s— serviría una cuenta
-- atrás con esos segundos de retraso.
--
-- __Por eso el instante es propio y no el de la puerta.__ Es el mismo motivo por el
-- que 'freezeClock' existe: un número que depende del reloj y se guarda, envejece.
-- Aquí ni siquiera se guarda — se recalcula en cada respuesta.
--
-- __El calendario se relee__, y no se hereda el de la puerta: entre una cosa y otra
-- puede haber pasado un 'noteFinalised' que lo haya refrescado.
withUpNext :: Env -> LiveResult -> IO LiveResult
withUpNext env result = do
  now <- getCurrentTime
  window <- readTVarIO (envFeedWindow env)
  let table = pvBody result
      next = upNext now (liveSession table) (fwSessions window)
  pure result {pvBody = table {liveNext = next}}

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

-- | Pide el calendario, le pone el nombre de cada gran premio y lo guarda.
--
-- Un fallo conserva lo que había (2026-09-15 (d)), y las dos peticiones caen
-- juntas: nunca se guarda un calendario sin sus nombres (2026-09-17 (d)).
--
-- Al arrancar el proceso la lista está vacía, así que hasta que esto salga bien una
-- vez se pregunta al feed siempre (2026-09-15 (d)).
--
-- Los nombres de gran premio de la misma respuesta se guardan también para
-- 'grandPrixName', en la misma transacción que el calendario (2026-09-18 (b)).
refreshFeedWindow :: Env -> IO ()
refreshFeedWindow env = do
  now <- getCurrentTime
  result <-
    try (fetchSchedule (envConfig env) now)
      :: IO (Either SomeException ([ScheduledSession], Map Int Text))
  either
    (noteFailure "el calendario")
    (\(sessions, names) ->
       atomically $ do
         modifyTVar' (envFeedWindow env) (\w -> w {fwSessions = sessions})
         modifyTVar' (envMeetingNames env) (Map.union names))
    result

-- | El calendario con sus nombres de gran premio, en las dos peticiones que hacen
-- falta. Sin @try@: lo pone quien llama, que es quien sabe qué hacer con el fallo.
--
-- __Devuelve los nombres aparte y no solo dentro del calendario__, porque las
-- sesiones que trae son las que aún no han terminado y los nombres valen para
-- cualquiera — incluida la que OpenF1 sirve como actual, que fuera de fin de semana
-- ya no está en esa lista.
fetchSchedule :: Config -> UTCTime -> IO ([ScheduledSession], Map Int Text)
fetchSchedule cfg now = do
  sessions <- Manager.fetchCalendar cfg now
  meetings <- concat <$> mapM (Manager.fetchMeetings cfg) (years sessions)
  pure (schedule sessions meetings, meetingNames meetings)
  where
    -- Normalmente uno; dos solo en las semanas que cruzan el cambio de año.
    years = nub . map (yearOf . osStart)
    yearOf = (\(y, _, _) -> y) . toGregorian . utctDay

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
-- sesión, y es lo que 'fromCache' sirve. Con la sesión finalizada, esa tabla pasa a
-- decirlo ('finaliseBox').
--
-- __Toda foto guarda los sectores de sus vueltas__, también la que pide el reloj sin
-- nadie mirando, y la tabla que se sirve lleva los de la mejor, y los de la última
-- si la foto no los trae ('withLapSectors').
fromFeed :: Env -> FeedLive -> IO LiveResult
fromFeed env live = do
  now <- getCurrentTime
  memory <- atomically $ do
    modifyTVar' (envLapSectors env) (rememberSectors live)
    readTVar (envLapSectors env)
  case feedVerdict now live of
    FeedServes table      -> serveFresh env now Feed (withLapSectors memory table)
    FeedEmpty             -> fromOpenF1 env
    FeedFinalised reading -> do
      atomically $ modifyTVar' (envLiveCache env) (fmap (finaliseBox reading))
      when (closesFeedWindow reading) (noteFinalised env now)
      fromOpenF1 env

-- | El peldaño de OpenF1: __lee la caja y no baja__, salvo que esté vacía.
--
-- __Quien baja es el reloj__ ('liveClock'), y ahí está el motivo de todo esto: OpenF1
-- acepta 30 peticiones por minuto —lo dice en su propio rechazo— y con el endpoint
-- bajando el gasto crecía con cada pantalla, hasta 11,55 intentos por minuto con
-- tres (medido el 2026-09-22). Con el reloj, el gasto lo fija
-- 'Handler.Live.Helper.openf1ClockPeriod' y nadie más lo mueve.
--
-- __Toca solo a OpenF1, y no a toda la escalera__: el feed es nuestro microservicio y
-- no tiene presupuesto, así que el directo sigue refrescándose al ritmo de la página.
-- A OpenF1 solo se baja sin sesión rodando.
--
-- __El sello lo pone la edad de lo guardado__, no este peldaño
-- ('Handler.Live.Helper.servedFromBox'): 'Common.Origin.Recent' mientras el reloj lo
-- mantenga al día, 'Common.Origin.Cached' cuando se pasa de
-- 'Handler.Live.Helper.openf1BoxStale', que es lo que deja al reposo, al reloj muerto
-- y al rechazo de la fuente contarse solos en pantalla.
--
-- __Vale lo guardado venga de la fuente que venga__: si lo último bueno fue del feed,
-- es mejor dato que el que traería OpenF1, y la fuente viaja con él.
fromOpenF1 :: Env -> IO LiveResult
fromOpenF1 env = do
  cached <- readTVarIO (envLiveCache env)
  maybe (warmUp env) serveBox cached

-- | Lo guardado, con el sello y el reloj que le toquen por su edad.
--
-- Qué sello y qué reloj no se decide aquí: lo decide
-- 'Handler.Live.Helper.servedFromBox', que es pura y tiene sus casos. Esto solo lee
-- el reloj del sistema y arma la respuesta.
serveBox :: (UTCTime, Source, LiveTable) -> IO LiveResult
serveBox (fetchedAt, source, table) = do
  now <- getCurrentTime
  let (origin, served) = servedFromBox now fetchedAt table
  pure (Provenanced origin (Just source) (Just fetchedAt) served)

-- | La única bajada que sigue saliendo del endpoint: la de la caja vacía.
--
-- __Se entra de uno en uno__ ('App.envLiveGate'). Dos peticiones que lleguen a la vez
-- con la caja vacía salían las dos y la segunda caía al respaldo; ahora la segunda
-- espera y, al entrar, vuelve a mirar: si la primera la llenó, la sirve sin pagar.
--
-- __Volver a mirar dentro del cerrojo no es defensa de más, es el punto__: sin esa
-- segunda mirada el cerrojo solo ordenaría las bajadas en vez de evitarlas.
--
-- __Y el freno cuenta desde el intento, no desde el acierto__
-- ('App.envLiveTried'). Un rechazo de la fuente no llena la caja, así que un freno
-- anclado a lo guardado se suelta justo cuando el presupuesto ya está agotado y cada
-- petición vuelve a salir: medido el 2026-09-22, de 6 a 30 peticiones por minuto con
-- una sola página. Con el instante del intento, una bajada fallida frena igual que
-- una buena, y de reintentar se encarga el reloj en su siguiente tic.
--
-- __No cambia lo que se ve__: un intento fallido ya servía el dato de ejemplo, y
-- frenado se sirve el mismo. Lo que cambia es cuántas veces se paga por él.
warmUp :: Env -> IO LiveResult
warmUp env = withMVar (envLiveGate env) $ \_ -> do
  cached <- readTVarIO (envLiveCache env)
  case cached of
    Just entry -> serveBox entry
    Nothing    -> do
      now <- getCurrentTime
      tried <- readTVarIO (envLiveTried env)
      if maybe False (stillRecent now) tried
        then fromCache env
        else do
          atomically $ writeTVar (envLiveTried env) (Just now)
          askOpenF1 env

-- | El reloj del directo: refresca la caja por su cuenta, para que el gasto a OpenF1
-- deje de depender de cuántas pantallas miren.
--
-- __Es lo que convierte un gasto proporcional a los clientes en uno constante.__
-- Medido el 2026-09-22 con el endpoint bajando: 3,10 intentos por minuto con una
-- pantalla, 7,01 con dos y 11,55 con tres, contra un presupuesto de 30 peticiones
-- por minuto que OpenF1 publica en su propio rechazo. Con el reloj, el número es el
-- del periodo y ya no lo mueve nadie más.
--
-- __Qué hacer en cada tic no se decide aquí__: lo decide
-- 'Handler.Live.Helper.clockVerdict', que es pura y tiene sus casos. Esto pone los
-- efectos — el respiro, leer las dos cajas y bajar.
--
-- __El respiro va antes del primer tic y fuera del @try@__, y las dos cosas a
-- propósito. Antes, porque al arrancar la caja está vacía y llenarla es del endpoint
-- (la primera petición, con su cerrojo); fuera, porque un tic que revienta tiene que
-- esperar igual que uno que sale bien, o un fallo permanente daría vueltas sin freno.
--
-- __Un tic que sale bien no deja línea__: serían tres por minuto para siempre. Del
-- fallo de la bajada ya se encarga 'askOpenF1' vía 'noteFailure'; lo que esto añade
-- es la línea del tic que revienta entero, que sin ella mataría el hilo en silencio y
-- dejaría la caja congelada sin que nada lo dijera.
liveClock :: Env -> IO ()
liveClock env = forever $ do
  threadDelay tickDelay
  outcome <- try (tick env) :: IO (Either SomeException ())
  either (noteFailure "el reloj del directo") pure outcome
  where
    tickDelay = round (realToFrac openf1ClockPeriod * 1e6 :: Double)

-- | Un tic: mirar qué toca —bajar a OpenF1 o pedir la foto del feed— y hacerlo.
--
-- El resultado se tira porque lo que importa es su efecto — dejar la caja al día y,
-- con la foto, ver el «finalizada» que cierra la ventana—, y de servirla se encarga
-- quien pregunte después. __La foto no anota lector__ ('envLiveAsked'): el reloj no
-- es nadie mirando.
tick :: Env -> IO ()
tick env = do
  now <- getCurrentTime
  window <- readTVarIO (envFeedWindow env)
  asked <- readTVarIO (envLiveAsked env)
  let feedOpen =
        feedWindowOpen now (map ssStart (fwSessions window)) (fwFinalisedAt window)
  case clockVerdict now feedOpen asked of
    ClockAsks      -> void (askOpenF1 env)
    ClockFeedPhoto -> Feed.fetchFeedLive (envConfig env) >>= void . fromFeed env
    ClockFeedAsked -> pure ()
    ClockIdle      -> pure ()

-- | La bajada a OpenF1: los seis GET y el ensamblado, con la cache detrás.
--
-- __Seis y no siete desde el 2026-09-18__: el nombre del gran premio sale de la caja
-- del 'Env' ('grandPrixName') y solo cuesta una petición la primera vez que se ve esa
-- clave. Fueron siete hasta que el presupuesto de OpenF1 se midió.
--
-- La condición de éxito es __traer filas__ y no solo no fallar: una lista vacía es
-- una sesión sin parrilla publicada, y servirla dejaría la tabla en blanco teniendo
-- una anterior buena guardada.
--
-- __La sesión se pide solo si hay filas que nombrar__, y después de tenerlas: una
-- petición por una tabla que se va a descartar no la paga nadie.
--
-- __La sesión que sale es la suya y no la del feed.__ Aunque el feed acabe de
-- anunciar una, no se hereda: OpenF1 pide siempre @session_key=latest@, y que su
-- «última» y la que el feed anuncia sean la misma no se puede comprobar desde aquí.
-- Lo único que pasa de lo guardado es el «finalizada» que el feed dijo de la misma
-- sesión ('inheritFinalised').
--
-- __El instante se toma una vez y sirve para las dos cosas__, igual que en
-- 'fromFeed': deducir el estado de la sesión y sellar la cache. Tomarlo dos veces
-- dejaría guardado un estado que habla de un momento distinto al de su sello.
askOpenF1 :: Env -> IO LiveResult
askOpenF1 env = do
  result <-
    try (fetchRows (envConfig env)) :: IO (Either SomeException [LiveTimingRow])
  case result of
    Right rows | not (null rows) -> do
      now <- getCurrentTime
      session <- fetchSessionOrNothing env now
      kept <- readTVarIO (envLiveCache env)
      let keptSession = (\(_, _, table) -> liveSession table) =<< kept
          heard = inheritFinalised keptSession <$> session
      serveFresh env now OpenF1 (LiveTable heard rows NextUnknown)
    Right _                      -> fromCache env
    Left e                       -> noteFailure "las filas" e >> fromCache env

-- | Sirve lo que acaba de llegar y refresca la cache con su fuente.
--
-- __La cache guarda la tabla entera, sesión incluida__, para que lo guardado siga
-- diciendo de qué sesión era: filas de una sesión bajo el nombre de otra es peor
-- que filas sin nombre.
serveFresh :: Env -> UTCTime -> Source -> LiveTable -> IO LiveResult
serveFresh env now source table = do
  atomically (writeTVar (envLiveCache env) (Just (now, source, table)))
  pure (Provenanced Fresh (Just source) Nothing table)

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
      Provenanced Cached (Just source) (Just fetchedAt) (frozen table)
    frozen table = table { liveSession = freezeClock <$> liveSession table }
    sample = Provenanced Sample Nothing Nothing (LiveTable Nothing dummy NextUnknown)

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

-- | Lo que nombra la sesión, con su propio @try@: «no se sabe» si no sale, en vez de
-- propagar y tirar una tabla que ya está en la mano.
--
-- __Mismo criterio que 'fetchIntervalsOrEmpty'__ y por la misma razón: una tabla sin
-- nombre sigue siendo la tabla, y perderla por la celda de la cabecera es peor que
-- enseñarla sin ella.
--
-- __Pero aquí un fallo es una avería y allí es el régimen, y ahí se aparta de él.__
-- La excepción de @\/intervals@ existe porque su fallo es el __caso normal__ —el
-- endpoint no existe fuera de carrera—; que @\/sessions@ no conteste, o que no
-- conteste la petición del gran premio que a veces la acompaña, no es un régimen.
-- Por eso el 'try' es uno solo y cubre las dos: una sesión a medias no la ha pedido
-- nadie.
--
-- __Y por eso mismo la avería se cuenta__ ('noteFailure'): «no se sabe» es la
-- respuesta correcta, pero callar por qué no lo es. Hasta el 2026-09-17 este
-- 'Nothing' era la cara única de cuatro causas distintas, y averiguar cuál obligó a
-- medir la API por fuera.
fetchSessionOrNothing :: Env -> UTCTime -> IO (Maybe SessionInfo)
fetchSessionOrNothing env now = do
  result <-
    try (fetchSessionInfo env now)
      :: IO (Either SomeException (Maybe SessionInfo))
  either (\e -> Nothing <$ noteFailure "el nombre de la sesión" e) pure result

-- | @\/sessions@ y, si hace falta, el nombre del gran premio que su clave designa.
--
-- __El arreglo vacío es «no se sabe» y no un fallo:__ OpenF1 responde con una lista,
-- y sin ninguna sesión dentro no hay nada que nombrar. Se lee la primera casando la
-- lista y no con 'Prelude.head', que sobre algo que llega de la red no se justifica.
--
-- El gran premio va aparte porque @\/sessions@ __no publica su nombre__: solo su
-- clave. Que no se sepa deja la sesión sin gran premio, no sin sesión.
--
-- __Deja de ser fija en dos peticiones__ (2026-09-18): la segunda solo sale si el
-- nombre no se sabía ya, y en régimen normal nunca sale.
fetchSessionInfo :: Env -> UTCTime -> IO (Maybe SessionInfo)
fetchSessionInfo env now = do
  sessions <- Manager.fetchSession (envConfig env)
  case sessions of
    []      -> pure Nothing
    (s : _) -> do
      grandPrix <- grandPrixName env (osMeeting s)
      pure (Just (openf1Session now s grandPrix))

-- | El nombre de un gran premio, preguntándolo __solo si no se sabía__.
--
-- __Es el ahorro que baja el refresco de siete peticiones a seis__, y lo justifica
-- que el dato no caduca: un gran premio no se renombra a mitad de fin de semana, así
-- que pedirlo cada diez segundos era pagar por la misma respuesta. El presupuesto de
-- OpenF1 —30 peticiones por minuto, medido el 2026-09-17— es lo que convierte ese
-- desperdicio en un defecto y no en una ineficiencia.
--
-- __Lo que se pregunta no se guarda si vino en blanco.__ @\/meetings@ puede devolver
-- el arreglo vacío, y guardar esa cadena convertiría un fallo de un momento en uno
-- permanente: no saberlo hoy no es saber que no lo tiene.
--
-- __Un fallo de la petición no se atrapa aquí__ sino en 'fetchSessionOrNothing', que
-- es quien decide que una sesión sin nombre sigue siendo una sesión.
grandPrixName :: Env -> Int -> IO Text
grandPrixName env key = do
  known <- readTVarIO (envMeetingNames env)
  case Map.lookup key known of
    Just name -> pure name
    Nothing   -> do
      meetings <- Manager.fetchMeeting (envConfig env) key
      let name = maybe "" omName (listToMaybe meetings)
      if T.null name
        then pure name
        else do
          atomically $
            modifyTVar' (envMeetingNames env) (Map.insert key name)
          pure name

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
--
-- __Es el único @try@ de este módulo que calla__, y por lo mismo que no es un fallo:
-- hablaría en cada refresco de cuatro sesiones de cada cinco para contar lo previsto,
-- y un log que avisa siempre deja de leerse.
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
  [ row 1 "3" "VER" "Red Bull" "LEADER" "-" "1:29.345"
  , row 2 "16" "LEC" "Ferrari" "+1.234" "+1.234" "1:29.512"
  , row 3 "1" "NOR" "McLaren" "+3.877" "+2.643" "1:29.701"
  ]
  where
    row pos car driver team gap interval lap =
      emptyLiveRow
        { ltPosition = pos
        , ltCar      = car
        , ltDriver   = driver
        , ltTeam     = team
        , ltGap      = gap
        , ltInterval = interval
        , ltLastLap  = lap
        , ltStatus   = Running
        , ltBestLap  = lap
        }
