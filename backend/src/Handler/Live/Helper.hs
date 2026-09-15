-- | Área Live timing — lógica pura.
--
-- Traduce a 'LiveTimingRow' lo que llega de las __dos fuentes__, y el trabajo que
-- hace con cada una no se parece:
--
-- * __OpenF1__ entrega series temporales por endpoint (@/position@, @/intervals@,
--   @/laps@), así que aquí se reducen a la última entrada por piloto y se ensambla
--   la tabla ('assembleRows'); y entrega en otros dos (@/sessions@, @/meetings@) de
--   qué sesión habla, que es un mapeo directo ('openf1Session'). Los tipos crudos de
--   esos endpoints viven en este módulo.
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
    -- * Transformaciones puras
  , assembleRows
  , feedRows
  , feedStatus
  , feedSession
  , openf1Session
  , sessionClock
  , sessionIsLive
  , freezeClock
  , lapProgress
  , parseRemaining
  , parseFeedInstant
  , statusOf
  , latestByDriver
  , formatLap
  , classificationTime
  , classificationGaps
  ) where

import           Common.Types          (DriverStatus (..), LapProgress (..),
                                        LiveTable (..), LiveTimingRow (..),
                                        SessionClock (..), SessionInfo (..),
                                        SessionState (..), sessionStateFrom)
import           Data.Aeson            (FromJSON (..), Value (..), withObject,
                                        (.!=), (.:), (.:?))
import           Data.Aeson.Types      (Parser)
import           Data.Foldable         (toList)
import           Data.Function         (on)
import           Data.List             (find, groupBy, maximumBy, sortOn)
import           Data.Maybe            (fromMaybe, mapMaybe)
import           Data.Ord              (comparing)
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Data.Text.Read        (decimal)
import           Data.Time.Clock       (UTCTime, diffUTCTime)
import           Data.Time.Format      (defaultTimeLocale, parseTimeM)
import           Handler.Feed.Helper   (FeedLive (..), FeedRow (..),
                                        FeedSession (..))
import           Handler.OpenF1.Helper (Of1Driver (..))
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
-- __Se modelan tres de los quince campos.__ Circuito, país, año y si está cancelada
-- no los pide nadie. @meeting_key@ entra porque es lo único que permite preguntar
-- por el nombre del gran premio, que esta respuesta __no trae__.
--
-- __Los tres van con @.:@__, al contrario que las banderas de 'Of1Result': allí el
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
  }
  deriving (Eq, Show)

instance FromJSON Of1Session where
  parseJSON = withObject "Of1Session" $ \o ->
    Of1Session
      <$> o .: "session_type"
      <*> o .: "session_name"
      <*> o .: "meeting_key"

-- | @/meetings@: el nombre del gran premio, que @\/sessions@ no publica.
--
-- Un solo campo y aun así un tipo, porque es el borde del decode: el día que haga
-- falta el nombre oficial o el circuito se gana aquí sin tocar a quien llama.
newtype Of1Meeting = Of1Meeting
  { omName :: Text  -- ^ @\"Spanish Grand Prix\"@.
  }
  deriving (Eq, Show)

instance FromJSON Of1Meeting where
  parseJSON = withObject "Of1Meeting" $ \o ->
    Of1Meeting <$> o .: "meeting_name"

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
  case [ realToFrac n :: Double | Number n <- toList xs ] of
    [] -> Nothing
    ns -> Just (last ns)
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
feedSession :: UTCTime -> FeedSession -> SessionInfo
feedSession now fs =
  SessionInfo
    { siType    = fsType fs
    , siName    = fsName fs
    , siMeeting = fsMeeting fs
    , siState   = Just (sessionStateFrom (fsState fs))
    , siLaps    = lapProgress fs
    , siClock   = sessionClock now fs
    }

-- | La sesión que OpenF1 describe, traducida a 'SessionInfo'.
--
-- __Los tres huecos son lo que OpenF1 no publica, y ninguno es un fallo:__ no tiene
-- estado —solo horas previstas—, no cuenta vueltas y no emite reloj. Deducir el
-- estado de las horas está descartado por medición: la carrera 11369 arrancó cuatro
-- minutos después de la suya y acabó trece antes de la de fin, así que la deducción
-- miente justo en los bordes, que es donde se la consultaría.
--
-- __No recibe el instante__, al contrario que 'feedSession': aquí no hay ningún
-- campo que dependa de «ahora», porque el único que dependía era el reloj.
--
-- __Sin gran premio la sesión se sirve igual, con el nombre en blanco__: el tipo y
-- el nombre siguen diciendo de qué se habla, y sale de otra petición.
openf1Session :: Of1Session -> Maybe Of1Meeting -> SessionInfo
openf1Session os meeting =
  SessionInfo
    { siType    = osType os
    , siName    = osName os
    , siMeeting = maybe "" omName meeting
    , siState   = Nothing
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

-- | Si una sesión en ese estado sigue dando directo.
--
-- __El feed no deja de contestar cuando la sesión acaba__, y eso está medido: tras
-- la bandera siguió publicando 9 min 20 s y después latió cada 15 s
-- indefinidamente, devolviendo la clasificación final como si fuera de ahora
-- (2026-09-13 (b)). O sea que «¿hay directo?» no se puede deducir de que el feed
-- conteste.
--
-- __Lo que sí deja de publicar, más tarde, son las filas__, y entonces la tabla
-- vacía basta para bajar a OpenF1 sin este predicado. Medido a los dos lados: el
-- feed servía la clasificación final el mismo día de la carrera y el siguiente, y a
-- los dos días ya no. O sea que la ventana que este predicado cubre es la de
-- __después de la bandera y antes de que el feed se vacíe__ — que es exactamente el
-- rato en que alguien está mirando la pantalla.
--
-- __'Common.Types.SessionFinalised' es la única señal, y es única de verdad:__ sale
-- exactamente una vez en las dos sesiones grabadas, mientras que «terminada» cicla
-- por segmento —tres veces en una clasificación— y «empezada» con ella
-- (2026-09-13 (c)).
--
-- __Lo que no se reconoce sigue dando directo__, igual que en 'feedStatus': un
-- estado nuevo del feed no es una sesión acabada, y tratarlo como tal escondería la
-- única fuente que publica durante una carrera.
sessionIsLive :: SessionState -> Bool
sessionIsLive SessionFinalised = False
sessionIsLive _                = True

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
feedVerdict :: UTCTime -> FeedLive -> FeedVerdict
feedVerdict now live
  | null (flRows live) = FeedEmpty
  | keepsGoing         = FeedServes (LiveTable session (feedRows (flRows live)))
  | otherwise          = FeedFinalised
  where
    session   = feedSession now <$> flSession live
    -- Sin sesión que lo desmienta se sirve, y sin estado dentro de ella también: la
    -- ausencia de la señal no es la señal contraria, que es el mismo criterio que
    -- 'sessionIsLive' aplica al desconocido. Los dos huecos se aplanan en uno
    -- porque se resuelven igual.
    keepsGoing = maybe True sessionIsLive (siState =<< session)

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
  | grp <- groupBy ((==) `on` drv) (sortOn drv xs)
  ]

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
    lapByDrv =
      latestByDriver olNumber olLapNum $
        filter (maybe False (> 0) . olDuration) laps

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
      pure
        LiveTimingRow
          { ltPosition = pos
          , ltDriver   = odAcronym d
          , ltTeam     = odTeam d
          , ltGap      = gap
          , ltInterval = intv
          , ltLastLap  = lastLap
          , ltStatus   = maybe Running statusOf mr
          }
