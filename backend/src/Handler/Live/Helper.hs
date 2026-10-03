-- | Área Live timing — lógica pura.
--
-- Traduce a 'LiveTimingRow' lo que llega de las __dos fuentes__, y el trabajo que
-- hace con cada una no se parece:
--
-- * __OpenF1__ entrega series temporales por endpoint (@/position@, @/intervals@,
--   @/laps@), así que aquí se reducen a la última entrada por piloto y se ensambla
--   la tabla ('assembleRows'); y entrega en otros dos (@/sessions@, @/meetings@) de
--   qué sesión habla, que es un mapeo directo salvo el estado, que no publica y se
--   deduce de sus horas ('openf1Session', 'derivedState'). Los tipos crudos de esos
--   endpoints viven en este módulo.
-- * __El feed__ entrega la tabla ya armada por el microservicio, así que el mapeo es
--   el estado y el orden ('feedRows'). Su tipo crudo es de la fuente y vive en
--   'Handler.Feed.Helper'.
--
-- Sin efectos: todo es determinista y testeable.
module Handler.Live.Helper
  ( -- * Tipos crudos OpenF1 específicos de Live
    Of1Position (..)
  , Of1Interval (..)
  , Of1Lap (..)
  , Of1Result (..)
  , Of1Session (..)
  , Of1Meeting (..)
    -- * La decisión de la escalera sobre el feed
  , FeedVerdict (..)
  , feedVerdict
    -- * Cuándo merece la pena mirar el feed
  , feedWindowLead
  , feedWindowOpen
  , endMargin
  , derivedState
  , meetingNames
  , schedule
  , upNext
    -- * Lo que se deja dicho cuando un fetch no sale
  , fetchFailure
    -- * Transformaciones puras
  , assembleRows
  , feedRows
  , feedStatus
  , feedSession
  , openf1Session
  , sessionClock
  , freezeClock
  , finaliseBox
  , inheritFinalised
  , openf1MinGap
  , stillRecent
  , ClockVerdict (..)
  , openf1ClockPeriod
  , openf1ClockIdle
  , openf1BoxStale
  , clockVerdict
  , servedFromBox
  , advanceClock
  , lapProgress
  , parseRemaining
  , parseFeedInstant
  , statusOf
  , latestByDriver
  , formatLap
  , classificationTime
  , classificationGaps
  ) where

import           App                   (ScheduledSession (..))
import           Common.Origin         (Origin (..), Source (..))
import           Common.Types          (DriverStatus (..), LapProgress (..),
                                        LiveTable (..), LiveTimingRow (..),
                                        SessionClock (..), SessionInfo (..),
                                        SessionState (..), StateBasis (..),
                                        StateReading (..), UpNext (..),
                                        sessionInProgress, sessionIsLive,
                                        sessionStateFrom)
import           Data.Aeson            (FromJSON (..), Value (..), withObject,
                                        (.!=), (.:), (.:?))
import           Data.Aeson.Types      (Parser)
import           Data.Foldable         (toList)
import           Data.Function         (on)
import           Data.List             (find, maximumBy, sortOn)
import           Data.List.NonEmpty    (nonEmpty)
import qualified Data.List.NonEmpty    as NE
import qualified Data.Map.Strict       as Map
import           Data.Maybe            (fromMaybe, listToMaybe, mapMaybe)
import           Data.Ord              (Down (..), comparing)
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Data.Text.Read        (decimal)
import           Data.Time.Clock       (NominalDiffTime, UTCTime, addUTCTime,
                                        diffUTCTime)
import           Data.Time.Format      (defaultTimeLocale, parseTimeM)
import           Handler.Feed.Helper   (FeedLive (..), FeedRow (..),
                                        FeedSession (..))
import           Handler.OpenF1.Helper (Of1Driver (..))
import           Provenance            (isoInstant)
import           Text.Printf           (printf)

-- | @/position@: posición del piloto en un instante (@date@).
data Of1Position = Of1Position
  { opNumber   :: Int
  , opPosition :: Int
  , opDate     :: Text  -- ^ ISO8601; orden lexicográfico = orden temporal.
  }
  deriving (Eq, Show)

instance FromJSON Of1Position where
  parseJSON = withObject "Of1Position" $ \o ->
    Of1Position
      <$> o .: "driver_number"
      <*> o .: "position"
      <*> o .: "date"

-- | @/intervals@: gap al líder e intervalo al de delante en un instante.
-- Ambos campos pueden ser número, cadena (p. ej. @"+1 LAP"@) o @null@; se
-- normalizan a 'Text' de presentación en el decode.
data Of1Interval = Of1Interval
  { oiNumber   :: Int
  , oiGap      :: Text
  , oiInterval :: Text
  , oiDate     :: Text
  }
  deriving (Eq, Show)

-- Los dos campos de gap van con @.:?@ y no con @.:@: el nulo ya lo absorbía
-- 'gapText', pero la __clave ausente__ tumbaba el decode del arreglo entero y con
-- él @\/api\/live@, que degradaba al dummy de tres filas con la red viva. Es el
-- mismo modo de fallo que @compound@ en 'Handler.TyreStrategy.Helper'
-- (2026-08-25) y entra por la misma puerta: @.!= Null@ hace
-- que la clave ausente y el nulo compartan rama.
instance FromJSON Of1Interval where
  parseJSON = withObject "Of1Interval" $ \o ->
    Of1Interval
      <$> o .: "driver_number"
      <*> (o .:? "gap_to_leader" .!= Null >>= gapText)
      <*> (o .:? "interval" .!= Null >>= gapText)
      <*> o .: "date"

-- | Normaliza un valor de gap/intervalo (número | cadena | null) a 'Text'.
gapText :: Value -> Parser Text
gapText Null       = pure "-"
gapText (String s) = pure s
gapText (Number n) = pure (diffText (realToFrac n))
gapText _          = pure "-"

-- | Una diferencia en segundos, con signo y tres decimales (@0.166 → \"+0.166\"@).
--
-- La comparten el gap que publica OpenF1 y el que se deriva de la clasificación
-- ('classificationGaps'), para que las dos procedencias de la misma columna no se
-- distingan al leerlas.
diffText :: Double -> Text
diffText d = T.pack (printf "%+.3f" d)

-- | @/laps@: duración de una vuelta concreta (@null@ en out/in laps).
data Of1Lap = Of1Lap
  { olNumber   :: Int
  , olLapNum   :: Int
  , olDuration :: Maybe Double  -- ^ Segundos; 'Nothing' si no cronometrada.
  }
  deriving (Eq, Show)

instance FromJSON Of1Lap where
  parseJSON = withObject "Of1Lap" $ \o ->
    Of1Lap
      <$> o .: "driver_number"
      <*> o .: "lap_number"
      <*> o .:? "lap_duration"

-- | @/sessions@: de qué sesión habla OpenF1.
--
-- __Se modelan cinco de los quince campos.__ Circuito, país, año y si está
-- cancelada no los pide nadie todavía. @meeting_key@ entra porque es lo único que
-- permite preguntar por el nombre del gran premio, que esta respuesta __no trae__;
-- y las dos horas, porque de ellas cuelgan la ventana del feed y el estado deducido.
--
-- __Los cinco van con @.:@__, al contrario que las banderas de 'Of1Result': allí el
-- default es semánticamente correcto —una bandera ausente es «no consta que
-- abandonara»— y aquí no hay ninguno que lo sea. Una sesión sin tipo no es una
-- sesión de tipo vacío. El fallo del decode degrada a «no se sabe» sin tocar la
-- tabla, así que puede permitirse ser estricto.
--
-- Vive aquí y no en 'Handler.OpenF1.Helper' por el mismo criterio que 'Of1Result':
-- hoy lo consume solo Live.
data Of1Session = Of1Session
  { osType    :: Text  -- ^ @\"Race\"@, @\"Qualifying\"@, @\"Practice\"@.
  , osName    :: Text  -- ^ @\"Race\"@, @\"Practice 1\"@.
  , osMeeting :: Int   -- ^ Clave del gran premio, para poder preguntar su nombre.
  , osStart   :: UTCTime
    -- ^ Hora de arranque __prevista__, que no es la real: medido sobre la carrera
    -- 11369, el feed dio la sesión por empezada cuatro minutos después de ésta. Es
    -- lo que 'feedWindowOpen' usa para saber cuándo empezar a mirar, y por eso le
    -- resta un margen en vez de creérsela.
  , osEnd     :: UTCTime
    -- ^ Hora de fin __prevista__, y tampoco es la real: la misma carrera acabó
    -- trece minutos antes. Es de lo que 'derivedState' deduce que una sesión ya
    -- terminó, y por eso le suma un margen ('endMargin') en vez de creérsela.
  , osCircuit :: Maybe Text
    -- ^ @circuit_short_name@ (@\"Madring\"@). Sin él la sesión entra igual.
  }
  deriving (Eq, Show)

instance FromJSON Of1Session where
  parseJSON = withObject "Of1Session" $ \o ->
    Of1Session
      <$> o .: "session_type"
      <*> o .: "session_name"
      <*> o .: "meeting_key"
      <*> o .: "date_start"
      <*> o .: "date_end"
      <*> o .:? "circuit_short_name"

-- | @/meetings@: el nombre del gran premio, que @\/sessions@ no publica.
--
-- __Lleva su clave desde que se piden todos los del año de una vez__: pedido por
-- clave, quien llamaba ya sabía de cuál era; pedida la lista entera, la clave es lo
-- único que permite juntar cada gran premio con sus sesiones.
data Of1Meeting = Of1Meeting
  { omKey  :: Int   -- ^ La misma clave que 'osMeeting', que es por donde se juntan.
  , omName :: Text  -- ^ @\"Spanish Grand Prix\"@.
  }
  deriving (Eq, Show)

instance FromJSON Of1Meeting where
  parseJSON = withObject "Of1Meeting" $ \o ->
    Of1Meeting
      <$> o .: "meeting_key"
      <*> o .: "meeting_name"

-- | @/session_result@: clasificación de la sesión, una fila por piloto.
--
-- __Se modelan cinco de los diez campos.__ @position@ y @gap_to_leader@ siguen
-- fuera: la posición de la tabla sale de @\/position@, y la diferencia se deriva de
-- 'orDuration' en vez de leerse, porque la que publica OpenF1 en una Qualy es
-- contra el líder de __cada segmento__ y no contra la pole.
--
-- Vive aquí y no en 'Handler.OpenF1.Helper' porque hoy lo consume solo Live; el
-- criterio de reparto está en la cabecera de ese módulo y asciende cuando lo
-- comparta una segunda área.
data Of1Result = Of1Result
  { orNumber   :: Int
  , orDnf      :: Bool
  , orDns      :: Bool
  , orDsq      :: Bool
  , orDuration :: Maybe Double
    -- ^ El tiempo que la clasificación ordena, en segundos; 'Nothing' si el piloto
    -- no tiene ninguno. Ver 'classificationTime': __no siempre es una vuelta__.
  }
  deriving (Eq, Show)

-- Las tres banderas van con @.:? … .!= False@ aunque OpenF1 no emita un solo nulo
-- en ellas (22 de 22 en la 11353). No es defensa contra un dato visto sino contra
-- un cambio de contrato: con @.:@, una clave que desaparezca tumbaría el decode
-- del arreglo y con él @\/api\/live@ entera. Y el default es __semánticamente__
-- correcto, que es lo que lo hace aceptable: una bandera ausente significa «no
-- consta que abandonara», que es exactamente 'Running'.
--
-- @duration@ entra por la misma puerta y por el mismo motivo que los dos gaps de
-- 'Of1Interval': con @.:? … .!= Null@, la clave ausente y el nulo comparten rama.
instance FromJSON Of1Result where
  parseJSON = withObject "Of1Result" $ \o ->
    Of1Result
      <$> o .: "driver_number"
      <*> o .:? "dnf" .!= False
      <*> o .:? "dns" .!= False
      <*> o .:? "dsq" .!= False
      <*> (classificationTime <$> (o .:? "duration" .!= Null))

-- | El tiempo por el que la clasificación ordena, a partir del valor crudo de
-- @duration@.
--
-- __La misma clave llega con tres formas, y las tres son legítimas:__ un número en
-- prácticas (la mejor vuelta), un __arreglo de tres__ en Qualy (Q1, Q2 y Q3, con
-- nulos en los segmentos que el piloto no disputó) y un número en carrera (el
-- tiempo total, no una vuelta). De ahí que el consumidor no pueda pintar este valor
-- tal cual: 'classificationGaps' solo lo resta.
--
-- Del arreglo vale __el último no nulo__, que es el mejor tiempo de la última Q que
-- el piloto corrió y el que enseña la clasificación oficial. Cualquier otra forma
-- —cadena, booleano, nulo o clave ausente— da 'Nothing'.
classificationTime :: Value -> Maybe Double
classificationTime (Number n) = Just (realToFrac n)
classificationTime (Array xs) =
  NE.last <$> nonEmpty [ realToFrac n :: Double | Number n <- toList xs ]
classificationTime _ = Nothing

-- | Estado de un piloto a partir de las tres banderas de @/session_result@.
--
-- __El orden es una decisión, no un detalle:__ las tres banderas son
-- independientes en el contrato y nada impide que lleguen dos a la vez, así que
-- hay que elegir cuál gana. Se ordena de más específico a menos: una
-- descalificación explica por sí sola el resultado y una no-salida hace del
-- abandono una consecuencia, no una causa. Decidido el 2026-08-27.
statusOf :: Of1Result -> DriverStatus
statusOf r
  | orDsq r   = Dsq
  | orDns r   = Dns
  | orDnf r   = Dnf
  | otherwise = Running

-- | La tabla del feed, ya armada por el microservicio, traducida a
-- 'LiveTimingRow'.
--
-- Es el mapeo de la otra fuente, y aquí no hay nada que ensamblar: las columnas
-- llegan resueltas porque el microservicio aplica las mismas reglas que
-- 'assembleRows'. Lo que queda es el estado, que viaja como texto, y el orden.
--
-- __Ordena por posición aunque el emisor ya ordene.__ La tabla es de esta función y
-- no del cable: hacerla depender de que la otra punta ordene convertiría un cambio
-- allí en una tabla desordenada aquí, sin error que lo delate.
feedRows :: [FeedRow] -> [LiveTimingRow]
feedRows = map toRow . sortOn frPosition
  where
    toRow r =
      LiveTimingRow
        { ltPosition = frPosition r
        , ltDriver   = frDriver r
        , ltTeam     = frTeam r
        , ltGap      = frGap r
        , ltInterval = frInterval r
        , ltLastLap  = frLastLap r
        , ltStatus   = feedStatus (frStatus r)
        , ltBestLap  = frBestLap r
        , ltPartBestLap = frPartBestLap r
        }

-- | El estado del feed, que viaja como el nombre del constructor.
--
-- __Lo que no se reconoce entra como 'Running'__, con el mismo significado que en
-- 'statusOf': «no consta que abandonara», no «se comprobó que sigue en pista».
-- Inventar un abandono haría creer en un incidente que nadie reportó, y tirar la
-- fila perdería un coche que sí está en pista.
feedStatus :: Text -> DriverStatus
feedStatus raw =
  case T.toLower (T.strip raw) of
    "dnf" -> Dnf
    "dns" -> Dns
    "dsq" -> Dsq
    _     -> Running

-- | La sesión que el feed anuncia, traducida a 'SessionInfo'.
--
-- __Recibe el instante por argumento__ y no lo pide al reloj: esta capa es pura, y
-- el único campo que depende de «ahora» es el restante ('sessionClock'). Quien
-- llama pasa el mismo instante que va a servir, de modo que la sesión y las filas
-- hablan del mismo momento.
--
-- __El estado sale siempre en 'Just'__, aunque 'Common.Types.siState' admita su
-- ausencia: el feed siempre dice algo, y lo que no se reconozca —la cadena vacía
-- incluida— entra como desconocido con su texto dentro. El hueco del tipo es para
-- quien no publica estado ninguno.
--
-- __Y siempre sale como 'Common.Types.Heard'__: por definición es lo que el feed
-- dijo. Aquí no se deduce nada, ni cuando lo que dijo no se reconoce.
feedSession :: UTCTime -> FeedSession -> SessionInfo
feedSession now fs =
  SessionInfo
    { siType    = fsType fs
    , siName    = fsName fs
    , siMeeting = fsMeeting fs
    , siCircuit = fsCircuit fs
    , siState   = Just (StateReading (sessionStateFrom (fsState fs)) Heard)
    , siLaps    = lapProgress fs
    , siClock   = sessionClock now fs
    }

-- | La sesión que OpenF1 describe, traducida a 'SessionInfo'.
--
-- __Las vueltas y el reloj siguen vacíos, y no es un fallo:__ OpenF1 no los publica.
--
-- __El estado ya no.__ OpenF1 tampoco lo publica, pero sus horas previstas dan para
-- afirmar una cosa sin cruzar ningún borde —que una sesión cuyo fin quedó
-- holgadamente atrás ya terminó—, y eso es lo que 'derivedState' decide. Sigue sin
-- deducirse nada en el borde, que es lo que la medición de la 11369 descartó: allí
-- el hueco se mantiene.
--
-- __Y sale marcado como 'Common.Types.Derived'__, que es lo único que lo distingue
-- del mismo estado oído del feed. Sin la marca, el día que se repitan sesiones
-- pasadas todas serían deducidas sin que nadie pudiera notarlo.
--
-- __Recibe el instante__, al contrario que antes: desde que deduce, «en qué punto
-- está» depende de cuándo se pregunte. Quien llama pasa el mismo que va a servir,
-- para que la sesión y las filas hablen del mismo momento.
--
-- __Sin gran premio la sesión se sirve igual, con el nombre en blanco__: el tipo y
-- el nombre siguen diciendo de qué se habla, y sale de otra petición.
--
-- __Recibe el nombre y no el 'Of1Meeting' del que salía__, porque desde el
-- 2026-09-18 quien lo trae puede ser la caja del 'App.Env' y no una respuesta: ahí
-- no hay ningún 'Of1Meeting' que enseñar, y fabricar uno para pasarlo sería inventar
-- una respuesta que nadie dio. La ausencia se dice con la cadena vacía, que es como
-- ya la dicen 'App.ScheduledSession' y 'Common.Types.siMeeting'.
openf1Session :: UTCTime -> Of1Session -> Text -> SessionInfo
openf1Session now os grandPrix =
  SessionInfo
    { siType    = osType os
    , siName    = osName os
    , siMeeting = grandPrix
    , siCircuit = osCircuit os
    , siState   = flip StateReading Derived <$> derivedState now os
    , siLaps    = Nothing
    , siClock   = Nothing
    }

-- | Por qué vuelta va y de cuántas, si la sesión las cuenta.
--
-- __Hacen falta las dos.__ La vuelta sola no dice por dónde va la sesión, así que
-- una sin la otra es lo mismo que ninguna: el tema del feed que las publica manda
-- ambas en la foto, y sus deltas posteriores —que sí traen una sola— no llegan
-- hasta aquí.
lapProgress :: FeedSession -> Maybe LapProgress
lapProgress fs = LapProgress <$> fsCurrentLap fs <*> fsTotalLaps fs

-- | Lo que queda de sesión __en el instante dado__, no cuando el feed lo publicó.
--
-- __Corregirlo no es un adorno, y está medido:__ en una carrera entera el feed
-- publicó su reloj __dos veces__, la última a los seis minutos de empezar. Servido
-- crudo, el valor diría «quedan 1 h 59 min» durante las dos horas siguientes.
--
-- Con el reloj parado ('fsClockRunning' 'False') el valor no se toca: es lo que el
-- feed emite entre segmentos y al acabar, y descontarle nada sería inventar.
--
-- __Sin el instante de publicación no hay reloj__, aunque venga el restante y la
-- marca diga que corre: servir el número sin corregir afirmaría que quedan
-- exactamente esos segundos, y es la afirmación que no se puede sostener. 'Nothing'
-- dice lo único cierto, que es que no se sabe.
--
-- El restante __no baja de cero__: una foto tomada mucho después de acabar daría un
-- negativo, y un reloj en negativo no es un dato sino una resta que se fue.
--
-- Lo transcurrido se trunca, no se redondea, así que el instante del feed lleva su
-- fracción a la cuenta: entre @13:04:05.01@ y @13:34:05@ han pasado 1799 segundos
-- enteros y no 1800. El sesgo es de un segundo como mucho y va a favor del
-- restante, que es el lado que no adelanta un reloj de cuenta atrás.
sessionClock :: UTCTime -> FeedSession -> Maybe SessionClock
sessionClock now fs = do
  remaining <- parseRemaining =<< fsClockRemaining fs
  if fsClockRunning fs
    then do
      published <- parseFeedInstant =<< fsClockUtc fs
      let elapsed = floor (diffUTCTime now published) :: Int
      pure (SessionClock (max 0 (remaining - elapsed)) True)
    else pure (SessionClock remaining False)

-- | Cuánto antes de la hora prevista se empieza a mirar el feed.
--
-- __Es el momento desde el que se enseña la sesión nueva__ (2026-09-24 (d)), no una
-- cota de cuándo publica el feed: antes no se le pregunta aunque ya tenga algo, y
-- lo que publique por delante —la parrilla— se ve desde OpenF1 o su caché.
feedWindowLead :: NominalDiffTime
feedWindowLead = 15 * 60

-- | Si merece la pena pedirle la foto al feed en este instante.
--
-- Recibe las horas de arranque __previstas__ de las sesiones que el calendario
-- publica, y el instante en que se vio por última vez que el feed daba una sesión
-- por finalizada.
--
-- __Sin calendario se pregunta__ (la lista vacía), y es deliberado: no saber cuándo
-- empieza la siguiente no es saber que no hay ninguna. El precio es el de hoy —una
-- foto de 16-23 s por refresco— y el beneficio es que un reinicio en pleno fin de
-- semana no deja la pantalla sin directo, que es para lo que existe el dashboard.
--
-- __La ventana abre por reloj y cierra por señal.__ Abre 'feedWindowLead' antes de
-- la hora prevista; no cierra a una hora sino cuando el feed dice que la sesión
-- acabó, así que __una carrera alargada por bandera roja sigue cubierta__ sin que
-- nadie haya tenido que inventar cuánto puede alargarse.
--
-- __La señal se compara contra la hora prevista de arranque de la sesión vigente__,
-- y no contra su apertura: ninguna sesión acaba antes de empezar, así que una
-- finalización vista antes de esa hora es de la sesión anterior, que el feed sigue
-- enseñando hasta anunciar la nueva, y no cierra nada.
--
-- __Y no se consume__, que es lo que hace que la repetición no muerda: el campo de
-- estado emite @Finalised@ más de una vez (2026-09-14 (k)), y aplicar esto dos veces
-- da lo mismo que aplicarlo una. Un «avanza a la siguiente» se habría saltado una
-- sesión.
--
-- __Y se reabre sola:__ cuando la sesión siguiente cruza su apertura, su hora de
-- arranque es posterior a la finalización vista, así que vuelve a dar abierto sin
-- necesidad de olvidar nada.
feedWindowOpen :: UTCTime -> [UTCTime] -> Maybe UTCTime -> Bool
feedWindowOpen now starts finalisedAt
  | null starts = True
  | otherwise   = maybe False stillLive current
  where
    current =
      listToMaybe (sortOn Down (filter ((<= now) . opensAt) starts))
    opensAt = addUTCTime (negate feedWindowLead)
    stillLive start = maybe True (< start) finalisedAt

-- | Cuánto se espera __tras la hora de fin prevista__ antes de dar una sesión por
-- acabada.
--
-- __Es el margen de la hora de fin, el simétrico de 'feedWindowLead'__, que lo es
-- de la de arranque. Y hace falta por lo mismo: las horas del calendario son
-- previstas y la carrera 11369 acabó trece minutos antes de la suya. Esperar cubre
-- el otro lado —una sesión que se alarga— sin tener que adivinar cuánto.
--
-- __Sale de la duración prevista y no de una lista de constantes__, y eso es lo que
-- lo hace resistir un calendario que estrene formatos: multiplicando la duración,
-- los dos números que ya estaban decididos salen solos —una carrera de 120 min da
-- las 3 h, unas prácticas de 60 dan los 45—, así que no hay que escribirlos ni
-- mantenerlos sincronizados con nada.
--
-- __El factor lo elige el NOMBRE y no el tipo, y eso está medido:__ el Sprint tiene
-- @session_type@ @\"Race\"@ igual que la carrera larga, así que por tipo se llevaría
-- las 3 h siendo una sesión de 60 min — y en Singapur acaba a las 10:00 con la
-- clasificación siguiente a las 13:00, o sea que la banda se pasaría las tres horas
-- sin poder decir que acabó y al poder decirlo ya habría empezado otra.
--
-- __El suelo y el techo son cotas de cordura__, no reglas de dominio: acotan lo que
-- pasaría con una duración absurda o negativa en el calendario. Hoy no muerde
-- ninguno de los dos — las 45 sesiones publicadas van de 44 a 120 min—, y están
-- para afinarse conforme avance la temporada.
endMargin :: Text -> NominalDiffTime -> NominalDiffTime
endMargin name planned =
    min marginCeiling (max marginFloor (factor * planned))
  where
    factor
      | T.toLower (T.strip name) == "race" = 1.5
      | otherwise                          = 0.75

-- | Lo menos que se espera, pase lo que pase con la duración publicada.
marginFloor :: NominalDiffTime
marginFloor = 30 * 60

-- | Lo más que se espera. Por encima de esto, callar deja de informar.
marginCeiling :: NominalDiffTime
marginCeiling = 4 * 60 * 60

-- | El estado que el calendario permite deducir en ese instante, si permite alguno.
--
-- __Solo deduce que una sesión ACABÓ, nunca que empezó ni que está rodando.__ Las
-- horas previstas mienten justo en los dos bordes que harían falta para eso —la
-- carrera 11369 arrancó cuatro minutos tarde y acabó trece pronto—, así que ahí no
-- se dice nada. Lo que sí se puede afirmar sin cruzar ningún borde es que una sesión
-- cuyo fin previsto quedó holgadamente atrás ya no está en marcha.
--
-- El 'Nothing' es «el calendario no da para decirlo», y quien llama lo junta con el
-- «nadie lo publicó» en un solo hueco: los dos son «no se sabe».
--
-- Quien sirva esto tiene que marcarlo como 'Common.Types.Derived'; el tipo no lo
-- hace por su cuenta porque el mismo 'SessionState' llega también oído del feed.
derivedState :: UTCTime -> Of1Session -> Maybe SessionState
derivedState now os
  | now > addUTCTime margin (osEnd os) = Just SessionFinalised
  | otherwise                          = Nothing
  where
    margin = endMargin (osName os) (diffUTCTime (osEnd os) (osStart os))

-- | El calendario tal como el backend lo guarda: cada sesión con su gran premio.
--
-- __Junta por clave y no por orden__, porque las dos listas vienen de peticiones
-- distintas: el calendario trae 45 sesiones de 9 grandes premios y @\/meetings@ trae
-- los 27 del año, así que ni coinciden en largo ni en orden.
--
-- __Un gran premio que no esté en la lista deja el nombre en blanco, no tira la
-- sesión__: sin él la sesión sigue sabiendo cómo se llama y cuándo es, que es lo que
-- decide la ventana del feed. Es el mismo criterio con el que 'openf1Session' sirve
-- la sesión sin gran premio.
--
-- __El orden de entrada se conserva__: quien busque «la siguiente» ordena por hora, y
-- hacerlo aquí escondería esa decisión en una función que solo junta.
schedule :: [Of1Session] -> [Of1Meeting] -> [ScheduledSession]
schedule sessions meetings = map toScheduled sessions
  where
    names = meetingNames meetings
    toScheduled os =
      ScheduledSession
        { ssName      = osName os
        , ssMeeting   = osMeeting os
        , ssGrandPrix = Map.findWithDefault "" (osMeeting os) names
        , ssStart     = osStart os
        , ssEnd       = osEnd os
        }

-- | El nombre de cada gran premio indexado por su clave, que es como llega de
-- @\/meetings@ y como se busca en todas partes.
--
-- __Vive aparte de 'schedule' porque tiene dos consumidores y no uno__: aquél junta
-- el calendario, y la caja del 'App.Env' que evita volver a preguntar guarda
-- exactamente esta forma. Escribir el @fromList@ en los dos sitios dejaría que uno
-- decidiera algo distinto del otro ante claves repetidas.
--
-- __Una clave repetida se queda con el último__, que es lo que hace 'Map.fromList'.
-- No se ha visto en el dato real —OpenF1 publica un objeto por gran premio— y lo que
-- importa es que los dos consumidores resuelvan igual, no cuál de los dos gane.
meetingNames :: [Of1Meeting] -> Map.Map Int Text
meetingNames meetings = Map.fromList [(omKey m, omName m) | m <- meetings]

-- | Qué viene después de la sesión que se está enseñando, en ese instante.
--
-- __Los cuatro casos salen de cuatro decisiones distintas y por eso no se
-- simplifican:__
--
-- * __Rodando, la derecha calla__ ('Common.Types.NextSilent'): en carrera el ancho
--   hace falta para lo que está pasando, y la siguiente sería el gran premio de
--   dentro de quince días. Qué cuenta como rodando lo decide
--   'Common.Types.sessionInProgress', que es el mismo criterio que enciende la
--   etiqueta del directo en la página.
-- * __Sin calendario, no se sabe__ ('Common.Types.NextUnknown'): es el estado con el
--   que arranca el proceso, y dura lo que tarde la primera petición.
-- * __Sin empezar, se cuenta a ELLA__ ('Common.Types.NextStartsIn'): con la parrilla
--   ya publicada —el feed lo hace hasta cuarenta minutos antes—, lo que hace falta
--   saber es cuándo arranca lo que se está mirando, no lo de después.
-- * __Acabada o sin estado, se cuenta a la siguiente__ ('Common.Types.NextAfter').
--
-- __La siguiente es la de arranque más próximo entre las que aún no han arrancado__,
-- y no la primera de la lista: el calendario llega ordenado, pero depender de ese
-- orden ataría esto a una promesa de OpenF1 que nadie ha comprobado.
--
-- __La etiqueta es el gran premio, salvo dentro de su propio fin de semana__, donde
-- repetirlo no diría nada nuevo —la sesión de la izquierda ya lo lleva— y el nombre
-- de la sesión sí. Sin nombre de gran premio se cae al de la sesión, que siempre hay.
upNext :: UTCTime -> Maybe SessionInfo -> [ScheduledSession] -> UpNext
upNext now shown sessions
  | null sessions            = NextUnknown
  | sessionInProgress state  = NextSilent
  | otherwise                = maybe NextUnknown answer soonest
  where
    state = srState <$> (siState =<< shown)

    soonest = listToMaybe (sortOn ssStart (filter ((> now) . ssStart) sessions))

    answer next
      | state == Just SessionInactive = NextStartsIn (secondsTo next)
      | otherwise                     = NextAfter (label next) (secondsTo next)

    secondsTo next = max 0 (floor (diffUTCTime (ssStart next) now))

    label next
      | T.null (ssGrandPrix next)                = ssName next
      | Just (ssGrandPrix next) == shownMeeting  = ssName next
      | otherwise                                = ssGrandPrix next

    shownMeeting = siMeeting <$> shown

-- | Qué se puede hacer con lo que el feed acaba de entregar.
--
-- __Los dos motivos de no servirlo van separados y no fundidos en un 'Nothing'__,
-- aunque el llamador haga lo mismo con los dos. Fundirlos repetiría el defecto que
-- 2026-09-13 (f) dejó abierto en el otro extremo de esta escalera: caer a la cache
-- por cuatro causas distintas y no poder decir cuál fue. Aquí el «por qué» existe
-- desde el principio, y cuando alguien quiera exponerlo no habrá que reabrir esto.
data FeedVerdict
  = FeedServes LiveTable  -- ^ Sesión en marcha y con filas: esto es el directo.
  | FeedEmpty             -- ^ Contestó sin filas, o sea que no hay sesión rodando.
  | FeedFinalised         -- ^ Trae filas, pero de una sesión que ya terminó.
  deriving (Eq, Show)

-- | La decisión de la escalera sobre el feed, sin efectos.
--
-- Vive aquí y no dentro de 'Handler.Live.Context' para que las tres ramas tengan
-- suite: el @Context@ solo sabe despachar sobre esto. Es el tercer modo de la
-- disciplina de código ciego —colocarlo donde nace con cobertura— y no una
-- verificación añadida después.
--
-- __El instante entra por argumento__ por lo mismo que en 'feedSession': el único
-- campo que depende de «ahora» es el restante del reloj, y quien llama pasa el
-- mismo instante que va a servir.
--
-- __Sin filas no hay tabla, se anuncie lo que se anuncie.__ La sesión que venga al
-- lado no cambia el desenlace, así que ese caso se mira primero.
--
-- __Lo que viene después sale en 'Common.Types.NextUnknown' y no es un degradado:__
-- depende del calendario, que este verdicto no tiene, y de «ahora», así que lo
-- resuelve 'Handler.Live.Context.getLiveTiming' justo antes de servir. Ponerlo aquí
-- lo dejaría envejecer dentro de la cache, que es el defecto que 'freezeClock'
-- existe para tapar en el otro campo que depende del instante.
feedVerdict :: UTCTime -> FeedLive -> FeedVerdict
feedVerdict now live
  | null (flRows live) = FeedEmpty
  | keepsGoing         =
      FeedServes (LiveTable session (feedRows (flRows live)) NextUnknown)
  | otherwise          = FeedFinalised
  where
    session   = feedSession now <$> flSession live
    -- Sin sesión que lo desmienta se sirve, y sin estado dentro de ella también: la
    -- ausencia de la señal no es la señal contraria, que es el mismo criterio que
    -- 'Common.Types.sessionIsLive' aplica al desconocido. Los dos huecos se aplanan
    -- en uno porque se resuelven igual.
    keepsGoing = maybe True (sessionIsLive . srState) (siState =<< session)

-- | La misma sesión con su reloj parado, para servirla desde la cache.
--
-- __Lo que caduca de una sesión guardada es el reloj y solo el reloj.__ El
-- restante lo resolvió 'sessionClock' al instante de guardarla, así que seguir
-- descontándolo afirmaría que el dato es de ahora; el nombre, el tipo, el gran
-- premio, el estado y la vuelta siguen siendo ciertos mientras la sesión sea la
-- misma. Parado es exactamente lo que 'Common.Types.SessionClock' distingue con
-- 'Common.Types.scRunning': un reloj frente a la foto de un reloj.
--
-- No borra el reloj: el número que se guardó sigue diciendo algo —cuánto quedaba
-- cuando se tomó el dato—, y el instante de esa toma viaja en cabecera propia.
freezeClock :: SessionInfo -> SessionInfo
freezeClock info = info { siClock = stop <$> siClock info }
  where
    stop clock = clock { scRunning = False }

-- | Lo guardado, con la sesión dada por finalizada tal como acaba de decirlo el feed.
--
-- __Solo toca lo que salió del feed__: es la sesión de la que el feed habla. El
-- instante y las filas no cambian, así que lo servido sigue diciendo de cuándo es
-- la tabla. Sin sesión no hay a quién ponérselo.
finaliseBox :: (UTCTime, Source, LiveTable) -> (UTCTime, Source, LiveTable)
finaliseBox (fetchedAt, Feed, table) =
  (fetchedAt, Feed, table { liveSession = finalised <$> liveSession table })
  where
    finalised s = s { siState = Just finalisedHeard }
finaliseBox entry = entry

-- | La sesión que trae OpenF1, con el «finalizada» que el feed ya dijo de ella.
--
-- Recibe la sesión de lo guardado. Hereda si esa sesión está finalizada __de oídas__
-- y es la misma: el mismo nombre y el mismo gran premio, salvo que uno de los dos
-- venga en blanco. __Gana al estado deducido__ ('derivedState'), porque alguien lo
-- dijo; un estado oído de la propia sesión no se toca.
inheritFinalised :: Maybe SessionInfo -> SessionInfo -> SessionInfo
inheritFinalised kept fresh
  | maybe False carries kept && not heard = fresh { siState = Just finalisedHeard }
  | otherwise                             = fresh
  where
    carries k = siState k == Just finalisedHeard && sameSession k
    sameSession k =
      siName k == siName fresh && meetingsAgree (siMeeting k) (siMeeting fresh)
    meetingsAgree a b = T.null a || T.null b || a == b
    heard = maybe False ((== Heard) . srBasis) (siState fresh)

-- | Finalizada, y dicho por la fuente.
finalisedHeard :: StateReading
finalisedHeard = StateReading SessionFinalised Heard

-- | Cuánto tiene que haber pasado desde el último __intento__ de llenar la caja
-- vacía para volver a intentarlo.
--
-- __Lo decide el presupuesto de OpenF1, que lo publica él mismo__: su rechazo dice
-- «Max 30 requests/minute» (medido el 2026-09-17). Con la caja vacía y la fuente
-- rechazando, una página pidiendo cada 'Common.Shown.liveRefreshSeconds' —diez—
-- reintenta seis veces por minuto, y cada intento fallido cuesta entre una y cinco
-- peticiones, porque 'Handler.Live.Context.fetchRows' aborta en el primer GET que
-- revienta. Son de 6 a 30 por minuto (medido el 2026-09-22): el presupuesto entero
-- en el peor caso, con una sola pantalla.
--
-- __Frena solo la bajada en frío__ ('Handler.Live.Context.warmUp'), que es la única
-- que sale del endpoint: con la caja llena se sirve lo guardado, y de refrescarla se
-- encarga el reloj a su propio ritmo ('openf1ClockPeriod'). De reintentar tras un
-- rechazo se encarga también él, en su siguiente tic.
--
-- Cualquier valor entre 11 y 20 da lo mismo frente a una página de diez segundos; por
-- debajo de 10 no frena nada.
openf1MinGap :: NominalDiffTime
openf1MinGap = 15

-- | Si un intento hecho en un instante es aún lo bastante reciente en otro como para
-- no repetirlo.
--
-- __Un instante del futuro no vale__, aunque la resta dé menos que el hueco: solo
-- puede salir de un reloj del sistema que ha retrocedido, y darlo por reciente dejaría
-- de intentarlo durante todo lo que retrocedió. Ante la duda se intenta, que es lo que
-- deja a la pantalla una oportunidad de tener dato.
stillRecent :: UTCTime -> UTCTime -> Bool
stillRecent now fetchedAt = elapsed >= 0 && elapsed < openf1MinGap
  where
    elapsed = diffUTCTime now fetchedAt

-- | Cada cuánto baja a OpenF1 el reloj que refresca el directo.
--
-- __No es 'openf1MinGap' aunque cubra el mismo hueco__, y confundirlos gastaría de
-- más: aquél es un mínimo que filtra las preguntas de la página —que llegan cada
-- 'Common.Shown.liveRefreshSeconds'—, así que con 15 la bajada cae cada 20. Éste es
-- el intervalo en sí, así que 15 darían 15. Medido el 2026-09-22: a 20 s el gasto
-- son 18 peticiones por minuto, que es exactamente el de hoy con una pantalla,
-- contra un presupuesto de 30 que OpenF1 publica en su propio rechazo.
openf1ClockPeriod :: NominalDiffTime
openf1ClockPeriod = 20

-- | Cuánto aguanta el reloj sin que nadie pregunte antes de pararse.
--
-- __Son dos periodos y no un número propio__: significa «la página dejó de
-- preguntar», y la página pregunta más a menudo que el periodo, así que dos vueltas
-- enteras en blanco no se explican por el ritmo de nadie que siga mirando.
openf1ClockIdle :: NominalDiffTime
openf1ClockIdle = 2 * openf1ClockPeriod

-- | Por qué el reloj no baja en este tic, o que sí.
--
-- __Los motivos van separados y no fundidos en un 'Bool'__, por lo mismo que
-- 'FeedVerdict': el hilo hace lo mismo con los tres —no bajar—, pero el que no baja
-- por reposo y el que no baja por haber sesión son sucesos distintos, y un día habrá
-- que poder contarlos por separado sin reabrir esto.
data ClockVerdict
  = ClockAsks      -- ^ Toca bajar: hay quien mira y OpenF1 es quien sirve.
  | ClockFeedOpen  -- ^ Hay sesión: manda el feed y OpenF1 contestaría @401@.
  | ClockIdle      -- ^ Nadie ha preguntado en 'openf1ClockIdle'.
  deriving (Eq, Show)

-- | Si el reloj baja a OpenF1 en este tic, y si no, por qué.
--
-- Recibe si la ventana del feed está abierta ('feedWindowOpen') y cuándo preguntó
-- alguien por última vez a @\/api\/live@; @Nothing@ es «nunca», que es el estado con
-- el que arranca el proceso.
--
-- __La ventana del feed gana al reposo__, y el orden no es arbitrario: con sesión
-- rodando no se baja ni habiendo quien mire, así que preguntarse por los lectores
-- ahí sería contestar una pregunta que no decide nada.
--
-- __Un instante del futuro cuenta como lector.__ Solo puede salir de un reloj del
-- sistema que ha retrocedido, y darlo por viejo pararía el reloj con la página
-- abierta delante — que es el fallo caro. 'stillRecent' resuelve su duda al otro
-- lado por el mismo criterio: ante la duda, no dejar de servir dato de ahora.
clockVerdict :: UTCTime -> Bool -> Maybe UTCTime -> ClockVerdict
clockVerdict now feedOpen lastAsked
  | feedOpen                  = ClockFeedOpen
  | maybe True idle lastAsked = ClockIdle
  | otherwise                 = ClockAsks
  where
    idle at = diffUTCTime now at >= openf1ClockIdle

-- | Cuánto puede tener lo guardado antes de que la respuesta deje de llamarlo
-- reciente.
--
-- __Son dos periodos por margen, no por significado__: con el reloj vivo la caja no
-- pasa de uno, así que un umbral de un periodo saltaría en el borde de lo normal y el
-- sello parpadearía sin que pasara nada malo. A los dos, lo que salta es que algo va
-- mal de verdad — el reloj parado por reposo, muerto, o bajando contra un rechazo.
--
-- Coincide en número con 'openf1ClockIdle' y no en sentido: aquél cuenta periodos sin
-- __lector__ y éste periodos sin __refresco__.
openf1BoxStale :: NominalDiffTime
openf1BoxStale = 2 * openf1ClockPeriod

-- | Lo guardado listo para servir: qué sello le toca por su edad, y la tabla con el
-- reloj de la sesión acorde con ese sello.
--
-- __El sello y el reloj son la misma decisión y por eso salen juntos.__ 'Recent'
-- significa que nadie ha tenido que preguntar, así que el restante se puede
-- __calcular__ ('advanceClock'); 'Cached' significa que la fuente no está
-- contestando, y entonces el número es de antes y el reloj se para ('freezeClock').
-- Separarlos dejaría escribir la combinación imposible: un sello que dice «de ahora»
-- sobre un reloj parado.
--
-- __Un instante del futuro cae en 'Cached'__. Solo sale de un reloj del sistema que
-- ha retrocedido, y ahí no se puede afirmar que el dato sea reciente: lo honesto es
-- el sello que dice que no se ha vuelto a saber.
--
-- __Nunca devuelve 'Fresh'__, y no es un olvido: 'Fresh' afirma una bajada hecha en
-- esta misma petición, y aquí no ha salido nadie a la red.
servedFromBox :: UTCTime -> UTCTime -> LiveTable -> (Origin, LiveTable)
servedFromBox now fetchedAt table
  | age >= 0 && age < openf1BoxStale = (Recent, withSession (advanceClock age))
  | otherwise                        = (Cached, withSession freezeClock)
  where
    age = diffUTCTime now fetchedAt
    withSession f = table { liveSession = f <$> liveSession table }

-- | La misma sesión con su reloj puesto al día, para servirla desde lo guardado
-- __cuando aún vale__.
--
-- __Es la simétrica de 'freezeClock'__ y la diferencia es el motivo: aquél sirve lo
-- guardado porque la fuente no contestó, y parar el reloj dice la verdad —ese número
-- es de antes—; éste lo sirve porque no hacía falta preguntar, y el número se puede
-- __calcular__: si quedaban 15:00 y han pasado 12 s, quedan 14:48.
--
-- __Solo descuenta si el reloj andaba.__ Con la sesión detenida —bandera roja— el
-- feed publica el reloj parado, y descontarle tiempo inventaría que corre. Y nunca
-- baja de cero, que no significa nada.
advanceClock :: NominalDiffTime -> SessionInfo -> SessionInfo
advanceClock elapsed info = info { siClock = advance <$> siClock info }
  where
    advance clock
      | scRunning clock =
          clock { scRemaining = max 0 (scRemaining clock - floor (max 0 elapsed)) }
      | otherwise = clock

-- | Segundos de un @\"HH:MM:SS\"@ del feed, o @\"MM:SS\"@.
--
-- Admite las dos longitudes porque lo que el feed publica es una duración y no una
-- hora; y 'Nothing' ante cualquier otra cosa, incluidas las partes no numéricas, en
-- vez de quedarse con lo que entienda. Un reloj a medio leer es peor que ninguno.
parseRemaining :: Text -> Maybe Int
parseRemaining raw =
  case traverse numeric (T.splitOn ":" (T.strip raw)) of
    Just [h, m, s] -> Just (h * 3600 + m * 60 + s)
    Just [m, s]    -> Just (m * 60 + s)
    _              -> Nothing
  where
    numeric part = case decimal part of
      Right (n, rest) | T.null rest -> Just n
      _                             -> Nothing

-- | El instante que el feed pone en su reloj, en ISO 8601 y con zona @Z@.
--
-- La fracción de segundo llega con un número de dígitos que varía —siete en la foto
-- inicial, dos en un delta—, así que se lee con @%Q@, que acepta cualquiera y
-- también su ausencia.
parseFeedInstant :: Text -> Maybe UTCTime
parseFeedInstant =
  parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" . T.unpack . T.strip

-- | Diferencia al mejor y al de delante por piloto, derivadas de la clasificación.
--
-- Es lo que alimenta las columnas @Gap@ e @Interval@ en las sesiones donde
-- @\/intervals@ no publica nada, que son todas menos la carrera. El piloto sin
-- tiempo no aparece en la lista, y el más rápido lleva las dos a @\"-\"@: no tiene
-- a nadie delante ni diferencia consigo mismo.
--
-- __Lo que devuelve es siempre una resta, nunca el tiempo crudo__, y por eso vale
-- igual para las cinco sesiones: en prácticas resta vueltas, en Qualy resta el
-- tiempo de cada uno contra la pole, y en carrera —donde solo se llega si
-- @\/intervals@ falló— resta tiempos totales, que da el mismo gap de carrera.
classificationGaps :: [Of1Result] -> [(Int, (Text, Text))]
classificationGaps results =
  case sortOn snd [ (orNumber r, t) | r <- results, Just t <- [orDuration r] ] of
    []                       -> []
    ordered@((n0, best) : _) ->
      (n0, ("-", "-"))
        : [ (n, (diffText (t - best), diffText (t - ahead)))
          | ((n, t), (_, ahead)) <- zip (drop 1 ordered) ordered
          ]

-- | Reduce una serie temporal a la última entrada por piloto: agrupa por
-- @driver_number@ y se queda con el máximo según la clave de orden dada.
latestByDriver :: Ord o => (a -> Int) -> (a -> o) -> [a] -> [a]
latestByDriver drv ordf xs =
  [ maximumBy (comparing ordf) grp
  | grp <- NE.groupBy ((==) `on` drv) (sortOn drv xs)
  ]

-- | La línea que deja un fetch que no salió: cuándo fue, qué se pedía y qué
-- contestó.
--
-- __El instante abre la línea y va en la forma de 'isoInstant'__, la misma que emite
-- la cabecera @X-Data-Fetched-At@: log y respuesta se cruzan sin convertir.
--
-- __Recibe el instante, el status ya pelado y el texto de la excepción, no la
-- excepción__, y eso es lo que la deja al alcance de la suite: fabricar un no-2xx
-- de @req@ exige armar una respuesta de @http-client@ entera. Pelarlo es de
-- 'Outcome.httpStatusOf', que es donde vive la medición de su forma.
--
-- __Sin status se sirve el texto de la excepción tal cual.__ Ahí caben la conexión
-- rechazada, el techo vencido y un @200@ con otra forma, y ninguna de las tres tiene
-- un número que las nombre; el texto de la excepción sí las distingue.
--
-- __El @429@ es el único que se nombra__, porque su número no dice qué hacer: no es
-- la red ni el servicio caído, es que se preguntó de más. Los demás se sirven a
-- secas, que para eso son códigos conocidos.
fetchFailure :: UTCTime -> Text -> Maybe Int -> Text -> Text
fetchFailure at what status detail =
  isoInstant at <> " [live] " <> what <> ": " <> maybe detail describe status
  where
    describe 429  = "HTTP 429, límite de peticiones de la fuente"
    describe code = "HTTP " <> T.pack (show code)

-- | Formatea segundos de vuelta a @"M:SS.mmm"@ (p. ej. @89.345 → "1:29.345"@).
formatLap :: Double -> Text
formatLap secs =
  let m = floor (secs / 60) :: Int
      s = secs - fromIntegral (m * 60)
   in T.pack (printf "%d:%06.3f" m s)

-- | Ensambla la tabla de live timing uniendo por @driver_number@ y ordenando
-- por posición. Un piloto sin posición conocida se omite. El líder muestra
-- @"LEADER"@ como gap y @"-"@ como intervalo.
--
-- Cruza __cinco__ respuestas, y es la función que más cruza del repo. La unidad
-- de la fila es el piloto de @\/drivers@: se itera sobre la parrilla y se busca
-- en las otras cuatro, así que una muestra de un coche que no está en la
-- parrilla no aparece.
--
-- __La omisión por falta de posición no la alcanza el dato de hoy.__ Medido el
-- 2026-08-27 sobre la sesión 11353: @\/position@ publica los 22 coches de la
-- parrilla, los 6 abandonos incluidos y con posición (el coche 3, con 0 vueltas,
-- sale en P22). O sea que esta rama solo la ejercita el fixture, igual que la del
-- @compound@ nulo de 'Handler.TyreStrategy.Helper'. Vive para la sesión __en
-- curso__, donde un coche puede no tener posición publicada todavía.
--
-- @\/session_result@ es la única de las cinco cuya ausencia __no__ pierde filas:
-- un piloto que no aparezca en ella entra como 'Running'. Es degradado parcial a
-- propósito —la tabla sin marcas sigue siendo la tabla—, y no lo elige esta
-- función sino el default de 'Of1Result'.
--
-- __@\/intervals@ vacía no vacía las columnas:__ cuando no trae nada, el gap y el
-- intervalo salen de 'classificationGaps' en vez de perderse. La condición es la
-- lista y no el tipo de sesión, así que no hace falta averiguarlo.
assembleRows
  :: [Of1Driver]
  -> [Of1Position]
  -> [Of1Interval]
  -> [Of1Lap]
  -> [Of1Result]
  -> [LiveTimingRow]
assembleRows drivers positions intervals laps results =
  sortOn ltPosition (mapMaybe row drivers)
  where
    posByDrv = latestByDriver opNumber opDate positions
    intByDrv = latestByDriver oiNumber oiDate intervals
    timedLaps = filter (maybe False (> 0) . olDuration) laps
    lapByDrv  = latestByDriver olNumber olLapNum timedLaps

    derived = classificationGaps results

    -- El gap y el intervalo de un piloto, de la fuente que haya. Se elige una sola
    -- vez para toda la tabla, para que dos filas no puedan salir de fuentes
    -- distintas.
    gapsFor n
      | null intervals = lookup n derived
      | otherwise =
          (\i -> (oiGap i, oiInterval i)) <$> find ((== n) . oiNumber) intByDrv

    row d = do
      p <- find ((== odNumber d) . opNumber) posByDrv
      let mg  = gapsFor (odNumber d)
          ml  = find ((== odNumber d) . olNumber) lapByDrv
          mr  = find ((== odNumber d) . orNumber) results
          pos = opPosition p
          gap
            | pos == 1  = "LEADER"
            | otherwise = maybe "-" fst mg
          intv
            | pos == 1  = "-"
            | otherwise = maybe "-" snd mg
          lastLap = maybe "-" (formatLap . fromMaybe 0 . olDuration) ml
          bestLap = case mapMaybe olDuration (filter ((== odNumber d) . olNumber) timedLaps) of
            [] -> "-"
            ds -> formatLap (minimum ds)
      pure
        LiveTimingRow
          { ltPosition = pos
          , ltDriver   = odAcronym d
          , ltTeam     = odTeam d
          , ltGap      = gap
          , ltInterval = intv
          , ltLastLap  = lastLap
          , ltStatus   = maybe Running statusOf mr
          , ltBestLap  = bestLap
          , ltPartBestLap = ""
          }
