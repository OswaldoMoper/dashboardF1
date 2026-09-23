-- | Tipos compartidos del dominio del F1 Functional Dashboard.

module Common.Types where

import           Common.Format (formatCountdown)
import           Data.Aeson    (FromJSON (..), ToJSON (..), withText)
import           Data.Maybe    (catMaybes, fromMaybe)
import           Data.Text     (Text)
import qualified Data.Text     as T
import           GHC.Generics  (Generic)

-- | Identificador de un widget dentro de un 'Layout'.
newtype WidgetId = WidgetId Text
  deriving stock (Eq, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Identificador de un 'Layout'.
newtype LayoutId = LayoutId Text
  deriving stock (Eq, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Estado de un piloto en la clasificación de una sesión.
--
-- Es __campo propio y no la ausencia de otro dato__, y eso lo decidió una
-- medición: en la sesión 11353, de los 6 pilotos con @dnf: true@ hay __uno__
-- (coche 23) que sí trae @position@. Estado y posición son hechos
-- independientes, así que un @'Maybe' Int@ en 'ltPosition' no podría
-- expresarlos —y además obligaría a decidir dónde ordenar los 'Nothing'—.
-- Decidido el 2026-08-27.
--
-- 'Running' es el estado por defecto: significa «no consta que abandonara», no
-- «se comprobó que sigue en pista». Es lo que se sirve cuando
-- @\/session_result@ no contesta o no menciona al piloto.
data DriverStatus
  = Running        -- ^ En carrera o clasificado sin incidencia.
  | Dnf            -- ^ Abandonó (/did not finish/).
  | Dns            -- ^ No tomó la salida (/did not start/).
  | Dsq            -- ^ Descalificado.
  deriving stock (Eq, Show, Generic)

-- Los cuatro constructores son nularios, así que el @allNullaryToStringTag@ de
-- aeson serializa esto como cadena (@\"Dnf\"@) y no como objeto etiquetado.
instance ToJSON DriverStatus
instance FromJSON DriverStatus

-- | Etiqueta de presentación de un 'DriverStatus'.
--
-- Vive aquí y no en el widget por el criterio de 'Common.Format'
-- (2026-08-26): la lógica pura del cliente se muda a
-- @common@ para ser __testeable__, porque el paquete @frontend@ no tiene suite.
-- No va en 'Common.Format', que es formateo
-- de cifras y aquella decisión se negó a convertirlo en cajón de sastre.
--
-- 'Running' da cadena vacía y no la raya de 'Common.Format.noData': la raya
-- significa «nadie dio esta cifra», y aquí sí se sabe el estado — es que no hay
-- nada que señalar. La celda queda en blanco a propósito, para que las tres
-- marcas destaquen.
statusLabel :: DriverStatus -> Text
statusLabel Running = ""
statusLabel Dnf     = "DNF"
statusLabel Dns     = "DNS"
statusLabel Dsq     = "DSQ"

-- | Fila del widget de live timing.
data LiveTimingRow = LiveTimingRow
  { ltPosition :: Int
  , ltDriver   :: Text
  , ltTeam     :: Text
  , ltGap      :: Text  -- ^ Gap al líder (p. ej. @"+1.234"@ o @"LEADER"@).
  , ltInterval :: Text  -- ^ Intervalo al coche de delante.
  , ltLastLap  :: Text  -- ^ Última vuelta (p. ej. @"1:23.456"@).
  , ltStatus   :: DriverStatus
    -- ^ Abandono, no-salida o descalificación; 'Running' si no consta ninguna.
    -- Sin él una fila de abandono es indistinguible de una normal, y sus
    -- 'ltGap' e 'ltInterval' son los de su última muestra: el coche 3 de la
    -- 11353 sale en P22 con @"+5.672"@ habiendo hecho 0 vueltas.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LiveTimingRow
instance FromJSON LiveTimingRow

-- | En qué punto de su vida está una sesión.
--
-- __Los tres primeros son los únicos observados__ en las dos sesiones grabadas
-- —una clasificación y una carrera—, y salen del campo de estado del tema de
-- información de sesión del feed, no del tema de estado, que es otro y cicla por
-- segmento. Medido: el campo __nunca__ pasa por «terminada»; va de «en marcha» a
-- «finalizada» directamente, también en una clasificación con tres cortes.
--
-- __'SessionUnknown' lleva el texto dentro, y eso lo aparta de
-- 'Common.Origin.originFrom'__, que ante un valor irreconocible devuelve 'Nothing'
-- y lo tira. La asimetría es del emisor: aquellos valores los pone nuestro propio
-- backend, y éstos los pone el feed, que es de terceros y puede estrenar un estado
-- sin avisar. Conservarlo es lo que permite ver __cuál__ llegó en vez de solo saber
-- que hubo uno.
data SessionState
  = SessionInactive       -- ^ Anunciada y todavía sin empezar.
  | SessionStarted        -- ^ En marcha.
  | SessionFinalised      -- ^ Terminada, y su resultado ya no cambia.
  | SessionUnknown Text   -- ^ Un valor que el feed emite y aquí no se reconoce.
  deriving stock (Eq, Show, Generic)

-- | El valor tal cual viaja, que para lo desconocido es lo que el feed dijo.
sessionStateLabel :: SessionState -> Text
sessionStateLabel SessionInactive    = "Inactive"
sessionStateLabel SessionStarted     = "Started"
sessionStateLabel SessionFinalised   = "Finalised"
sessionStateLabel (SessionUnknown t) = t

-- | El estado a partir del valor del feed. __No falla:__ lo que no reconoce se
-- conserva, que es el motivo de que 'SessionUnknown' exista.
--
-- Recorta y compara en minúsculas por el criterio de 'Common.Origin.originFrom'
-- —un valor de cable atraviesa cosas que no controlamos— pero __guarda el texto sin
-- normalizar__: lo que se enseña es lo que llegó, o el aviso mentiría sobre su
-- propia causa.
sessionStateFrom :: Text -> SessionState
sessionStateFrom raw =
  case T.toLower (T.strip raw) of
    "inactive"  -> SessionInactive
    "started"   -> SessionStarted
    "finalised" -> SessionFinalised
    _           -> SessionUnknown raw

-- __Instancias a mano, y no el derive genérico del resto del módulo.__ Con un
-- constructor que lleva carga, el genérico emitiría un objeto etiquetado para todos
-- —@{"tag":"SessionStarted"}@— y el cable dejaría de parecerse a
-- 'DriverStatus', que viaja como cadena. Así viaja siempre una cadena y __la del
-- estado desconocido es la que el feed mandó__, que es justo lo que hay que poder
-- leer al otro lado.
instance ToJSON SessionState where
  toJSON = toJSON . sessionStateLabel

instance FromJSON SessionState where
  parseJSON = withText "SessionState" (pure . sessionStateFrom)

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
-- __'SessionFinalised' es la única señal, y es única de verdad:__ sale exactamente
-- una vez en las dos sesiones grabadas, mientras que «terminada» cicla por segmento
-- —tres veces en una clasificación— y «empezada» con ella (2026-09-13 (c)).
--
-- __Lo que no se reconoce sigue dando directo:__ un estado nuevo del feed no es una
-- sesión acabada, y tratarlo como tal escondería la única fuente que publica durante
-- una carrera.
sessionIsLive :: SessionState -> Bool
sessionIsLive SessionFinalised = False
sessionIsLive _                = True

-- | Si consta que hay una sesión en curso ahora mismo.
--
-- __No es la negación de 'sessionIsLive', y la diferencia son los dos huecos.__
-- Aquél contesta «¿lo que el feed sirve sigue siendo el directo?» y ante la duda
-- dice que sí, porque callar escondería la única fuente que publica durante una
-- carrera. Éste contesta «¿hay carrera?» y ante la duda dice que no: __hace falta
-- que conste__, no basta con que no conste lo contrario.
--
-- De ahí que el 'Nothing' —ni sesión, ni estado dentro de ella— apague. Es el
-- criterio contrario al que aplica la escalera del feed sobre el mismo hueco, y son
-- dos preguntas distintas sobre el mismo dato.
--
-- __'SessionInactive' apaga aunque sea una sesión viva:__ el feed publica la
-- parrilla hasta cuarenta minutos antes de empezar, así que anunciada y en marcha
-- son cosas distintas y solo la segunda está pasando.
--
-- __Lo desconocido enciende__, compuesto de 'sessionIsLive' en vez de repetido: un
-- estado nuevo del feed llega durante una sesión, no después.
sessionInProgress :: Maybe SessionState -> Bool
sessionInProgress = maybe False inProgress
  where
    inProgress SessionInactive = False
    inProgress s               = sessionIsLive s

-- | De dónde salió un estado.
--
-- __'Derived' no es un estado peor, es un estado que nadie dijo.__ Quien lo lee
-- tiene que poder distinguirlo, porque el día que se repitan sesiones pasadas
-- todas saldrían por el mismo sitio y sin esto se perdería en silencio la
-- propiedad de que lo que viaja es lo que la fuente publicó.
--
-- Los dos constructores son nularios, así que viaja como cadena igual que
-- 'DriverStatus'.
data StateBasis
  = Heard    -- ^ La fuente publicó el estado: es literalmente lo que dijo.
  | Derived  -- ^ Nadie lo publicó; sale de la hora de fin del calendario.
  deriving stock (Eq, Show, Generic)

instance ToJSON StateBasis
instance FromJSON StateBasis

-- | El estado de una sesión y de dónde salió.
--
-- __Los dos juntos y no dos campos sueltos__, por el mismo criterio que
-- 'LapProgress': son un solo hecho. Separarlos dejaría representable
-- «procedencia sin estado», que nadie emite, y obligaría a cada lector a casar
-- cuatro combinaciones en vez de dos.
data StateReading = StateReading
  { srState :: SessionState
  , srBasis :: StateBasis
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON StateReading
instance FromJSON StateReading

-- | Lo que se lee en el sitio del estado: la palabra, si se sabe, con su marca.
--
-- __La marca se cuenta y no se suma__: un asterisco es un estado deducido y dos es
-- una sesión conservada, y cuando concurren manda la segunda. Lo que significa cada
-- una no cabe en un carácter: lo dice 'bandNote'.
--
-- __Sin palabra la marca sale sola__, para que el aviso siempre tenga dónde
-- colgarse: una sesión conservada puede no traer estado.
--
-- __Lo desconocido no lleva marca de deducido__ aunque sea una palabra rara: llegó
-- de la fuente, así que es tan oído como los otros tres.
bandStateLabel :: Bool -> Maybe StateReading -> Text
bandStateLabel kept reading = word <> mark
  where
    word = maybe "" (sessionStateWord . srState) reading
    mark
      | kept                = "**"
      | isDerived reading   = "*"
      | otherwise           = ""

-- | Qué aclara la marca. __Cadena vacía cuando no hay nada que aclarar__, y eso es
-- lo que deja el botón inerte.
--
-- Recibe la edad en segundos cuando lo que se enseña es conservado, y si el estado
-- salió del calendario. __Los dos hechos se componen__ porque con dos asteriscos el
-- de lo deducido deja de verse, y esto es el único sitio donde puede decirse.
bandNote :: Maybe Int -> Bool -> Text
bandNote age derived =
  T.intercalate ". " (catMaybes [keptPart, derivedPart])
  where
    keptPart = (\n -> "Sesión de hace " <> formatCountdown n) <$> age
    derivedPart
      | derived   = Just derivedNote
      | otherwise = Nothing

-- | Si un estado salió de la hora de fin del calendario y no de la fuente.
isDerived :: Maybe StateReading -> Bool
isDerived = maybe False ((== Derived) . srBasis)

-- | La palabra que se lee por cada estado.
--
-- __No es 'sessionStateLabel'__, que da el valor de cable y viaja tal cual. Ésta
-- es prosa y va en el idioma de la página; aquélla es el dato.
--
-- __Lo que no se reconoce sale crudo__, con el texto que la fuente mandó: es para
-- lo que 'SessionUnknown' lo guarda, y traducirlo sería inventar una palabra para
-- algo que aún no sabemos qué es.
sessionStateWord :: SessionState -> Text
sessionStateWord SessionInactive    = "Por empezar"
sessionStateWord SessionStarted     = "En marcha"
sessionStateWord SessionFinalised   = "Finalizada"
sessionStateWord (SessionUnknown t) = t

-- | Por qué vuelta va la sesión y de cuántas.
--
-- __Los dos juntos y no dos campos sueltos__, porque son un solo hecho: o la sesión
-- cuenta vueltas o no las cuenta. Separarlos dejaría representable «total sin
-- actual», que el feed no produce, y obligaría a cada lector a casar cuatro
-- combinaciones en vez de una.
data LapProgress = LapProgress
  { lpCurrent :: Int
  , lpTotal   :: Int
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LapProgress
instance FromJSON LapProgress

-- | Lo que queda de sesión, ya resuelto al instante en que se sirvió.
--
-- __'scRemaining' son segundos y no un texto formateado__ porque quien lo pinta
-- tiene que poder seguir descontando entre refrescos: de @\"01:23:45\"@ no se resta
-- nada. El formateo es de quien pinta.
--
-- __'scRunning' es la diferencia entre un reloj y una foto de un reloj.__ Con
-- 'False' el número está congelado —es lo que el feed emite al acabar un segmento—
-- y descontarle nada sería inventar.
data SessionClock = SessionClock
  { scRemaining :: Int
  , scRunning   :: Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SessionClock
instance FromJSON SessionClock

-- | Qué sesión es y por dónde va.
--
-- Es lo que la tabla del directo necesita para decir de qué está hablando, y sale
-- entero del feed sin calcular nada salvo el reloj (ver 'siClock').
--
-- __Las dos ausencias son casos normales y no fallos.__ Las vueltas solo las
-- publica la carrera —medido: 57 mensajes en una y ninguno en una clasificación—,
-- así que cuatro de las cinco sesiones de un fin de semana llegan sin ellas; y el
-- reloj falta si su tema no viene en la foto.
data SessionInfo = SessionInfo
  { siType    :: Text  -- ^ Tipo, tal cual lo nombra el feed (@\"Race\"@, @\"Qualifying\"@).
  , siName    :: Text  -- ^ Nombre de la sesión (@\"Race\"@, @\"Sprint Qualifying\"@).
  , siMeeting :: Text  -- ^ Gran premio (@\"Spanish Grand Prix\"@).
  , siCircuit :: Maybe Text
    -- ^ Circuito (@\"Madring\"@). 'Nothing' cuando quien publica la sesión no lo dice.
  , siState   :: Maybe StateReading
    -- ^ 'Nothing' cuando no se sabe: ni la fuente lo publicó ni el calendario da
    -- para deducirlo. __Es «no se sabe» y no «el emisor lo mandó vacío»__, por el
    -- mismo criterio que 'liveSession' un nivel más arriba.
    --
    -- __Deducirlo tiene un borde que no se cruza.__ Está medido que las horas
    -- previstas mienten justo ahí —una carrera arrancó cuatro minutos después de
    -- la suya y acabó trece antes de la de fin—, así que solo se deduce cuando la
    -- de fin quedó holgadamente atrás, y lo deducido viaja marcado
    -- ('StateBasis').
  , siLaps    :: Maybe LapProgress
    -- ^ 'Nothing' fuera de carrera, que es el caso de cuatro de las cinco sesiones.
  , siClock   :: Maybe SessionClock
    -- ^ Ya resuelto al instante de servir, no como el feed lo publicó: el feed lo
    -- emite dos veces en una carrera entera, así que su valor crudo envejece horas.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SessionInfo
instance FromJSON SessionInfo

-- | De qué sesión habla la página, para enseñárselo a alguien.
--
-- __'siType' no entra.__ Coincide con el nombre en la mitad de las sesiones
-- —medido sobre el calendario de 2026: «Race»\/«Race» y
-- «Qualifying»\/«Qualifying» son 50 de 131— y el nombre ya distingue por sí solo
-- las diez formas que se publican, «Sprint» y «Sprint Qualifying» incluidas.
--
-- __El circuito va entre el gran premio y el nombre__: @Spanish Grand Prix · Madring
-- · Race@.
--
-- __Un campo en blanco no deja separador suelto:__ el gran premio llega vacío
-- cuando quien publica la sesión no lo sabe, y entonces esto es el nombre a secas.
-- Un circuito ausente o vacío se salta igual.
sessionTitle :: SessionInfo -> Text
sessionTitle s =
  T.intercalate " · " $
    filter (not . T.null) [siMeeting s, fromMaybe "" (siCircuit s), siName s]

-- | Qué viene después de la sesión que se está enseñando.
--
-- __Los cuatro casos no son un estado y tres excusas:__ cada uno dice algo distinto
-- y la banda los pinta distinto. Fundirlos en un @Maybe@ juntaría «calla a
-- propósito» con «todavía no lo sé», que es la distinción que este repositorio paga
-- por conservar en 'LiveTable.liveSession' y en 'SessionInfo.siState'.
--
-- __Los segundos viajan resueltos al instante de responder__, no como una hora de
-- arranque, por el mismo criterio que 'SessionClock': el navegador nunca compara su
-- reloj con el del servidor, solo descuenta desde lo que recibió.
--
-- __La etiqueta viene armada y no en piezas.__ Elegir entre el gran premio y el
-- nombre de la sesión depende de con qué se compare —la sesión que se enseña al
-- lado—, y quien pinta no tiene por qué volver a decidirlo.
data UpNext
  = NextSilent
    -- ^ La sesión de la izquierda está rodando: la derecha calla y le deja el ancho.
  | NextUnknown
    -- ^ Todavía no se sabe. Es el estado con el que arranca el proceso, antes de que
    -- el calendario llegue.
  | NextStartsIn Int
    -- ^ La sesión de la izquierda aún no ha empezado, y lo que falta es para ella.
    -- Sin etiqueta: ya está nombrada al lado.
  | NextAfter Text Int
    -- ^ La siguiente, con su etiqueta y los segundos que faltan.
  deriving stock (Eq, Show, Generic)

instance ToJSON UpNext
instance FromJSON UpNext

-- | Lo que se lee a la derecha de la banda.
--
-- __'NextSilent' da cadena vacía y no una raya__, por el criterio de
-- 'statusLabel': la raya significa «nadie dio este dato», y aquí sí se sabe — es que
-- se calla a propósito para dejarle el ancho a la sesión que rueda.
--
-- __Lo que no se sabe todavía se dice con puntos suspensivos__ y no en blanco: sin
-- ellos, el arranque del proceso y una sesión rodando se verían igual.
--
-- __La sesión que aún no empieza no se nombra__: está escrita al lado, en la misma
-- banda, y repetirla gastaría el ancho en decir dos veces lo mismo.
upNextLabel :: UpNext -> Text
upNextLabel NextSilent       = ""
upNextLabel NextUnknown      = "Próxima: …"
upNextLabel (NextStartsIn n) = "empieza en " <> formatCountdown n
upNextLabel (NextAfter l n)  = l <> " · en " <> formatCountdown n

-- | La misma cuenta atrás un segundo después.
--
-- __Existe porque el refresco es de diez segundos y la cuenta es de uno.__ El
-- backend resuelve los segundos al responder, y quien pinta los descuenta entre
-- respuestas en vez de verlos saltar de diez en diez — el mismo reparto que
-- 'SessionClock' declara para el reloj de sesión.
--
-- __No baja de cero__ ni inventa un estado nuevo al llegar: lo que hay después de
-- que la cuenta se agote lo dice la respuesta siguiente, no esta función.
tickDown :: UpNext -> UpNext
tickDown (NextStartsIn n) = NextStartsIn (max 0 (n - 1))
tickDown (NextAfter l n)  = NextAfter l (max 0 (n - 1))
tickDown other            = other

-- | Qué significa un asterisco.
--
-- Vive aquí y no en el widget por el criterio de 'statusLabel', y __se enseña al
-- pulsar y al pasar por encima__: en un teléfono no hay hover, así que un aviso que
-- solo apareciera ahí no existiría en la mitad de las pantallas.
derivedNote :: Text
derivedNote = "Estado previsto por el calendario"

-- | Lo que sirve @GET \/api\/live@: la tabla y de qué sesión es.
--
-- __El dato de sesión envuelve las filas en vez de viajar en cabeceras__ porque es
-- contenido y no metadato, y porque no cabe en una fila. Decidido el 2026-09-13.
-- Las cabeceras de 'Common.Origin' siguen siendo lo que eran —de dónde salió el
-- dato—, que sí es metadato.
--
-- No se llama @LiveTiming@ porque ese nombre ya es el constructor de 'WidgetType'
-- que identifica al widget, y son cosas distintas: aquél dice __qué tarjeta es__ y
-- éste __qué se sirve__.
data LiveTable = LiveTable
  { liveSession :: Maybe SessionInfo
    -- ^ 'Nothing' cuando las filas no salieron de una sesión que se anuncie: el
    -- feed es la única fuente que la publica, y el dato de ejemplo no salió de
    -- ninguna. __Es «no se sabe» y no «sesión en blanco»__, que son distintos: una
    -- sesión con todos los campos vacíos afirmaría que el emisor los mandó así.
  , liveRows    :: [LiveTimingRow]
  , liveNext    :: UpNext
    -- ^ Qué viene después de 'liveSession', __ya resuelto al instante de
    -- responder__.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LiveTable
instance FromJSON LiveTable

-- | Punto de telemetría a lo largo de una vuelta.
--
-- La lista que sirve @\/api\/telemetry@ es __plana y multi-piloto__: trae la
-- vuelta rápida de varios coches concatenada, así que cada punto va etiquetado
-- con 'tpDriver' y el consumidor agrupa o filtra. Lista etiquetada en vez de
-- lista anidada por el mismo criterio que hizo heterogéneo a 'HistoricalStat'
-- (2026-07-29): el tipo de @Server.Api@ sigue siendo
-- @[TelemetryPoint]@ y ni el enrutado ni el widget cambian de forma.
--
-- La identidad aquí es __solo el acrónimo__, a diferencia de 'HistoricalStat'
-- (código + nombre + apellido, 2026-07-28): una fila de
-- telemetría no es una fila de identidad — el acrónimo es la etiqueta de serie,
-- y repetir tres campos de identidad en cada una de las ~60 muestras por piloto
-- es payload sin información nueva. Decidido el 2026-07-31.
data TelemetryPoint = TelemetryPoint
  { tpDriver      :: Text    -- ^ Acrónimo del piloto (p. ej. @"VER"@).
  , tpSessionTime :: Double  -- ^ Tiempo de sesión en segundos.
  , tpDistance    :: Double  -- ^ Distancia recorrida en metros.
  , tpSpeed       :: Double
  , tpThrottle    :: Double
  , tpBrake       :: Double
  , tpGear        :: Int
  , tpRpm         :: Int
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON TelemetryPoint
instance FromJSON TelemetryPoint

-- | Comparación de una vuelta entre dos drivers.
--
-- La identidad va __por partida doble__: el acrónimo (@lcDriverA@) y el número
-- de coche (@lcCarA@). No es redundancia. La API de FastF1 habla __números de
-- coche__ y los widgets hablan __acrónimos__ (2026-08-01 y
-- 2026-08-03), y el acrónimo no permite reconstruir el número: solo el
-- microservicio conoce esa traducción. Sin @lcCarA@\/@lcCarB@ el consumidor
-- puede leer la comparación pero no puede pedir __otra__ — que es exactamente lo
-- que le faltaba a 'Widgets.Comparison' (2026-08-05).
data LapComparison = MkLapComparison
  { lcDriverA :: Text
  , lcDriverB :: Text
  , lcCarA    :: Text        -- ^ Número de coche de A (p. ej. @"1"@), el que acepta el query.
  , lcCarB    :: Text        -- ^ Número de coche de B (p. ej. @"16"@).
  , lcLapA    :: Text        -- ^ Tiempo de vuelta del driver A.
  , lcLapB    :: Text        -- ^ Tiempo de vuelta del driver B.
  , lcDelta   :: [Double]    -- ^ Delta acumulado A-B a lo largo de la vuelta.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LapComparison
instance FromJSON LapComparison

-- | Un coche de la parrilla de una sesión: el par número↔acrónimo, con el equipo.
--
-- Es el __estado final__ del desajuste de vocabularios que 'LapComparison'
-- resolvió a medias (2026-08-05). Allí el número viaja
-- __dentro de lo mostrado__, así que el consumidor sabe de qué coches habla lo
-- que pinta pero no qué otros hay; aquí la traducción se publica entera, que es
-- lo que permite pedir datos de un coche que todavía no se ha visto.
--
-- __La lista es la de una sesión concreta__, no la del campeonato: un piloto
-- sustituto o un tercer coche en libres la cambian, y por eso el backend la
-- cachea por @session_key@.
--
-- 'deCode' puede __repetir__ el número cuando FastF1 no resuelve el acrónimo
-- (fallback de @_driver_label@ en @telemetry-service@): el coche está en la
-- sesión aunque no se sepa quién lo lleva, y esconderlo daría una parrilla
-- incompleta sin decirlo. 'deTeam' es lo único prescindible de los tres — es
-- decoración (agrupar, colorear), no identidad —, y llega vacío cuando el
-- servicio no lo publica.
data DriverEntry = MkDriverEntry
  { deNumber :: Text  -- ^ Número de coche (p. ej. @"1"@), el que acepta el query.
  , deCode   :: Text  -- ^ Acrónimo (p. ej. @"NOR"@), o el número si no resuelve.
  , deTeam   :: Text  -- ^ Equipo (p. ej. @"McLaren"@), o vacío.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON DriverEntry
instance FromJSON DriverEntry

-- | Stint de neumáticos (periodo con un mismo compuesto).
data TyreStint = TyreStint
  { tsDriver   :: Text
  , tsCompound :: Text  -- ^ SOFT/MEDIUM/HARD/INTER/WET.
  , tsStartLap :: Int
  , tsEndLap   :: Int
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON TyreStint
instance FromJSON TyreStint

-- | A qué entidad de la clasificación pertenece un 'HistoricalStat'.
--
-- La lista que sirve @\/api\/historical@ es __heterogénea__ (pilotos y
-- constructores) y una fila de constructor no tiene acrónimo ni nombre\/apellido,
-- así que el consumidor necesita saber qué proyección de etiqueta aplicar.
-- Decidido el 2026-07-29.
data StatEntity
  = DriverStat
  | ConstructorStat
  deriving stock (Eq, Show, Generic)

instance ToJSON StatEntity
instance FromJSON StatEntity

-- | Estadística histórica de un piloto o de un constructor: __una fila por
-- entidad__, con una columna por métrica.
--
-- La identidad va __estructurada__ (código + nombre + apellido) en vez de una sola
-- etiqueta: el consumidor elige qué mostrar sin poder reconstruir el código a partir
-- del nombre. Decidido el 2026-07-28.
--
-- 'hsEntity' marca de qué clasificación viene la fila
-- (2026-07-29). Para un constructor la convención es @hsCode@ = @constructorId@
-- (p. ej. @"red_bull"@), @hsFamilyName@ = @name@ (@"Red Bull"@) y @hsGivenName@
-- vacío. Sigue siendo la marca que permite __partir__ la lista heterogénea que
-- sirve @\/api\/historical@ en las dos tablas que el widget pinta.
--
-- __La métrica está en las columnas y no en los datos__, que es el cambio de
-- 2026-08-24: hasta entonces el tipo era @(entidad, identidad, valor, unidad)@ y
-- cada entidad producía __dos__ filas —una de puntos y otra de victorias—, así que
-- un piloto salía en dos renglones de la tabla.
--
-- 'hsWins' admite ausencia y 'hsPoints' no, y el reparto no es defensivo sino
-- estructural. Con una fila por métrica, un @wins@ que no parseaba se descartaba
-- __solo a sí mismo__ y la fila de puntos sobrevivía; con una fila por entidad esa
-- salida no existe, y la alternativa a @Maybe@ sería descartar __la entidad
-- entera__ o inventar un cero que Jolpica no publicó. Que @wins@ pueda faltar es
-- un caso previsto del decode desde el 2026-07-30, no una
-- observación: medido el 2026-08-24, Jolpica lo publica para las 34 entidades.
data HistoricalStat = HistoricalStat
  { hsEntity     :: StatEntity  -- ^ Piloto o constructor.
  , hsCode       :: Text    -- ^ Acrónimo del piloto (p. ej. @"VER"@).
  , hsGivenName  :: Text    -- ^ Nombre (p. ej. @"Max"@).
  , hsFamilyName :: Text    -- ^ Apellido (p. ej. @"Verstappen"@).
  , hsPoints     :: Double  -- ^ Puntos de la temporada en curso.
  , hsWins       :: Maybe Double  -- ^ Victorias, @Nothing@ si Jolpica no las publica.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON HistoricalStat
instance FromJSON HistoricalStat

-- | Tipo de widget del dashboard (ver ROADMAP §Fase 2).
--
-- 'HistoricalStats' es __solo la clasificación de pilotos__ desde 2026-08-26, y
-- 'ConstructorStats' es la de constructores. Antes un único 'HistoricalStats'
-- pintaba las dos tablas dentro de la misma tarjeta, así que compartían encabezado
-- y __sitio en la rejilla__: se distinguían pero no se podían colocar por separado.
--
-- __Son dos constructores y no un 'WidgetParams'__: el parámetro le daría a
-- 'WidgetParams' su primer consumidor, pero fijaría su forma antes de que la Fase 6
-- —que es la que va de layouts y de configurar widgets— hubiera decidido cuál es. Un
-- constructor por widget mantiene la invariante que esa fase necesita intacta: una
-- 'WidgetConfig' es __un__ widget. Decidido el 2026-08-26.
--
-- La forma de 'WidgetParams' quedó decidida el 2026-09-01 —sesión, piloto y
-- pilotos— y __no__ discrimina clasificaciones, así que la distinción sigue
-- siendo de constructor y no de parámetro.
data WidgetType
  = LiveTiming
  | Telemetry
  | LapComparison
  | TyreStrategy
  | HistoricalStats   -- ^ Clasificación de __pilotos__ (puntos y victorias).
  | ConstructorStats  -- ^ Clasificación de __constructores__ (puntos y victorias).
  | Custom
  deriving stock (Eq, Show, Generic)

instance ToJSON WidgetType
instance FromJSON WidgetType

-- | Con qué elección de sesión y de piloto(s) arranca un widget. 'Nothing' en un
-- campo significa __omitir el parámetro__, o sea el default del endpoint.
--
-- __Es espejo de 'Common.Route' y no una forma nueva__: @telemetryPathFor@ y
-- @comparisonPathFor@ son @'Maybe' 'Text' -> 'Maybe' 'Text' -> 'Text'@, con el
-- mismo tipo y el mismo significado del 'Nothing' desde el 2026-08-01. El por
-- qué está en la decisión del 2026-09-01 (b).
--
-- __Es la semilla del estado del widget, no su sustituto.__ El @driverSwitcher@
-- de 'Widgets.Telemetry' y los dos @\<select\>@ de 'Widgets.Comparison' siguen
-- sosteniendo la elección viva en un @Dynamic@; esto es con qué se monta. Con
-- 'noParams' el render es el de siempre.
--
-- __La forma es abierta a propósito, y eso es lo que hay que saber al leer un
-- campo:__ nada ata 'wpDriver' a 'Telemetry' ni 'wpDrivers' a 'LapComparison',
-- así que un widget puede leer un campo que no le corresponde. El tipo no lo
-- impide.
data WidgetParams = WidgetParams
  { wpSession :: Maybe Text
    -- ^ Valor de @?session=@: una clave de sesión (p. ej. @"2026-05-R"@).
  , wpDriver  :: Maybe Text
    -- ^ Valor de @?driver=@ de telemetría: __un número de coche__ (p. ej.
    -- @"1"@), no un acrónimo — el desajuste de vocabularios es el de
    -- 'LapComparison'.
  , wpDrivers :: Maybe Text
    -- ^ Valor de @?drivers=@ de comparación, __ya compuesto__: dos números de
    -- coche separados por coma (@"1,16"@). Que sean exactamente dos no lo
    -- impide el tipo; lo garantiza @Common.Route.driversParam@, que es quien
    -- compone este valor.
  }
  deriving stock (Eq, Show, Generic)

-- El récord tiene instancias genéricas, y con el pin de aeson (2.3.1.0) el
-- @omittedField@ de un campo 'Maybe' admite la clave ausente como 'Nothing': un
-- parámetro nuevo no costará migración del layout guardado.
instance ToJSON WidgetParams
instance FromJSON WidgetParams

-- | 'WidgetParams' sin ninguna elección: los tres campos en 'Nothing', o sea
-- «cada endpoint con su default». Es lo que monta una 'WidgetConfig' que no
-- configura nada, y el motivo de que añadir el récord no cambie el render.
noParams :: WidgetParams
noParams = WidgetParams
  { wpSession = Nothing
  , wpDriver  = Nothing
  , wpDrivers = Nothing
  }

-- | Configuración de un widget dentro de un 'Layout'.
--
-- 'widgetId' lo pone __quien construye el 'Layout'__ y es opaco: único dentro del
-- 'Layout' y estable frente a reordenar, ocultar y editar parámetros. Que sea
-- explícito es lo que hace referenciable a un widget — sin él la identidad era el
-- tipo y dos 'Telemetry' colisionaban. La unicidad es __convención y no tipo__:
-- @['WidgetConfig']@ admite ids repetidos. Decidido el 2026-09-01.
--
-- __Los cuatro últimos campos son el lienzo libre__
-- (2026-09-03): cada widget lleva posición y tamaño __propios, independientes de
-- los demás__, que es lo que descarta la lista plana y el árbol de particiones.
-- Los huecos vacíos son legales y el orden de la lista __ya no coloca nada__.
--
-- __La unidad es 1\/120 del contenedor, y no la centésima__
-- (2026-09-04). La rejilla del imán es de 24×24, y 120\/24 = 5 __exacto__ mientras
-- 100\/24 = 4.166… obligaba a pasos alternos de 4 y de 5. Con 120 caen en celda
-- la mitad (60), el tercio (40), el cuarto (30) y el sexto (20); el quinto es 24,
-- exacto como número aunque el imán no lo alcance.
--
-- La aritmética que gobierna estos cuatro campos —pegar a la rejilla, el ancho
-- mínimo, y si un widget cabe donde dice estar— vive en "Common.Layout", que es
-- pura y sí tiene suite. __Nada aquí la impone:__ el récord admite un
-- @wcX + wcW > 120@, igual que admite ids repetidos.
data WidgetConfig = WidgetConfig
  { widgetId      :: WidgetId
  , widgetType    :: WidgetType
  , params        :: WidgetParams
  , widgetVisible :: Bool
    -- ^ Si el widget se monta. El oculto __conserva sus parámetros y su sitio en
    -- el lienzo__, que es la razón de que sea un campo y no una lista aparte en
    -- 'Layout': el desplegable puede listar todas las opciones recorriendo una
    -- sola lista.
  , widgetGroup   :: Maybe Text
    -- ^ Etiqueta del grupo al que pertenece, o 'Nothing' si va suelto. La
    -- membresía es __arbitraria y la declara el autor__ —por piloto, por tipo, o
    -- por juntar una clasificación con una telemetría porque se miran a la vez—:
    -- ni se deriva del tipo de widget ni de la adyacencia. Dentro del grupo el
    -- tamaño de los miembros queda __acoplado__ (el borde entre dos es un
    -- separador arrastrable, y el grupo se mueve y escala como un bloque), que es
    -- justo lo que el lienzo niega fuera del grupo. Decidido el 2026-09-03 (b).
  , wcX           :: Int
    -- ^ Borde izquierdo, en 1\/120 del __ancho__ del contenedor.
  , wcY           :: Int
    -- ^ Borde superior, en 1\/120 del __alto__.
  , wcW           :: Int
    -- ^ Ancho, en 1\/120 del ancho del contenedor.
  , wcH           :: Int
    -- ^ Alto, en 1\/120 del alto del contenedor.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON WidgetConfig
instance FromJSON WidgetConfig

-- | Conjunto de widgets organizados en una pantalla.
data Layout = Layout
  { layoutId :: LayoutId
  , widgets  :: [WidgetConfig]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Layout
instance FromJSON Layout
