-- | Cliente del feed oficial — forma del dato en el cable (lógica pura).
--
-- El feed publica deltas por topic y acumularlos es trabajo del microservicio, que
-- entrega la tabla ya armada: el mapeo de negocio —el líder con @\"LEADER\"@, el
-- abandono, el coche sin posición que se omite— vive allí y es el mismo que hace
-- 'Handler.Live.Helper.assembleRows', para que la tabla no diga dos cosas distintas
-- según de dónde venga.
--
-- __Por eso este tipo se parece a 'Common.Types.LiveTimingRow' y aun así no es
-- él.__ Decodificar directamente al DTO lo convertiría en contrato de cable: darle
-- un campo nuevo rompería el decode entero mientras el otro extremo no lo emitiera,
-- y un decode roto es un fallo del feed — o sea, la tabla servida desde la cache
-- justo cuando hay sesión en marcha. Con un tipo propio, quién puede faltar lo
-- decide esta instancia.
module Handler.Feed.Helper
  ( FeedLive (..)
  , FeedRow (..)
  , FeedSession (..)
  , FeedFlag (..)
  , FeedNotice (..)
  , FeedTrack (..)
  ) where

import           Data.Aeson (FromJSON (..), withObject, (.!=), (.:), (.:?))
import           Data.Text  (Text)

-- | Lo que @GET \/fastf1\/live@ entrega: la tabla y de qué sesión es.
--
-- __Las filas son obligatorias y la sesión no__, y la asimetría no es un descuido.
-- Una respuesta sin filas es una respuesta legítima —significa que no hay sesión
-- rodando, y es lo que manda a 'Handler.Live.Context' a probar OpenF1—, mientras
-- que una respuesta sin el campo entero es un contrato roto, y un contrato roto
-- tiene que llegar como fallo para que la escalera sirva desde la cache en vez de
-- confundirlo con «no hay sesión».
--
-- __'flSession' 'Nothing' es «el feed no anunció sesión»__, que no es lo mismo que
-- anunciarla con los campos vacíos: aquello lo representa un 'FeedSession' con sus
-- defaults. Las dos mitades salen de la misma foto del feed, así que hablan del
-- mismo instante.
data FeedLive = FeedLive
  { flSession :: Maybe FeedSession
  , flRows    :: [FeedRow]
  }
  deriving (Eq, Show)

instance FromJSON FeedLive where
  parseJSON = withObject "FeedLive" $ \o ->
    FeedLive
      <$> o .:? "session"
      <*> o .:  "rows"

-- | Una fila de la tabla que sirve el microservicio.
--
-- __Solo la posición y el piloto son obligatorios.__ Sin posición no hay fila que
-- ordenar, que es el criterio que ya aplican 'Handler.Live.Helper.assembleRows' y el
-- propio microservicio; sin piloto la fila no identifica a nadie. Lo demás degrada a
-- vacío y el estado a @\"Running\"@, con el mismo argumento que el default de
-- 'Handler.Live.Helper.Of1Result': una tabla sin marcas sigue siendo la tabla, y
-- perderla entera por una celda es peor que enseñarla incompleta.
--
-- 'frStatus' viaja como texto y no como 'Common.Types.DriverStatus' por lo mismo: un
-- valor que no se reconozca tiene que poder degradar, y eso lo decide el mapeo
-- ('Handler.Live.Helper.feedRows'), no el decode.
data FeedRow = FeedRow
  { frPosition :: Int
  , frDriver   :: Text
  , frTeam     :: Text
  , frGap      :: Text
  , frInterval :: Text
  , frLastLap  :: Text
  , frStatus   :: Text
  , frBestLap  :: Text
  , frPartBestLap :: Text
  , frPartBests :: [Text]
    -- ^ La mejor de cada parte de una clasificación, en orden, @\"-\"@ en la que no
    -- tiene vuelta. Vacía fuera de clasificación.
  , frKnockedOut :: Bool  -- ^ Eliminado en una parte anterior de la clasificación.
  , frCutoff     :: Bool
    -- ^ Sin tiempo dentro del 107 %. __No es la zona de eliminación__ (medido el
    -- 2026-10-03): al empezar la Q1 lo llevan los veintidós.
  }
  deriving (Eq, Show)

instance FromJSON FeedRow where
  parseJSON = withObject "FeedRow" $ \o ->
    FeedRow
      <$> o .:  "ltPosition"
      <*> o .:  "ltDriver"
      <*> o .:? "ltTeam"     .!= ""
      <*> o .:? "ltGap"      .!= ""
      <*> o .:? "ltInterval" .!= ""
      <*> o .:? "ltLastLap"  .!= ""
      <*> o .:? "ltStatus"   .!= "Running"
      <*> o .:? "ltBestLap"  .!= ""
      <*> o .:? "ltPartBestLap" .!= ""
      <*> o .:? "ltPartBests"   .!= []
      <*> o .:? "ltKnockedOut"  .!= False
      <*> o .:? "ltCutoff"      .!= False

-- | Qué sesión anuncia el feed, tal como el microservicio la entrega.
--
-- __Nada es obligatorio__, al contrario que en 'FeedRow'. Allí la posición y el
-- piloto lo son porque sin ellos la fila no ordena ni identifica; aquí no hay un
-- campo del que dependan los demás, y una sesión a medias sigue diciendo algo. El
-- criterio es el mismo de siempre: perder la tabla entera por una celda es peor que
-- enseñarla incompleta.
--
-- __El reloj viaja crudo y en tres campos, no resuelto__, porque quien lo resuelve
-- necesita saber cuándo se está sirviendo, y eso no lo sabe el microservicio ni el
-- decode: lo hace 'Handler.Live.Helper.sessionClock' con el instante en la mano.
--
-- __'fsClockRunning' ausente es 'False'__, o sea «no corre» (decidido el
-- 2026-09-14). Es el valor que el feed emitió en los dos únicos mensajes medidos
-- que llegaron sin él, los dos al arrancar un segmento con el reloj todavía parado;
-- y su modo de fallo —un reloj que no se mueve— se ve antes que el contrario, que
-- sería un número descontando de un valor congelado.
data FeedSession = FeedSession
  { fsType           :: Text
  , fsName           :: Text
  , fsMeeting        :: Text
  , fsCircuit        :: Maybe Text
  , fsState          :: Text
  , fsCurrentLap     :: Maybe Int
  , fsTotalLaps      :: Maybe Int
  , fsClockUtc       :: Maybe Text  -- ^ Instante en que el feed publicó el reloj, ISO 8601.
  , fsClockRemaining :: Maybe Text  -- ^ Lo que quedaba entonces, @\"HH:MM:SS\"@.
  , fsClockRunning   :: Bool        -- ^ Si descontaba desde ese instante.
  , fsStartDate      :: Maybe Text  -- ^ Inicio previsto, en hora local del circuito y sin zona.
  , fsGmtOffset      :: Maybe Text  -- ^ Desfase del circuito: @\"08:00:00\"@, @\"-04:00:00\"@.
  , fsFlags          :: [FeedFlag]  -- ^ Los avisos de bandera de control de carrera.
  , fsNotices        :: [FeedNotice]  -- ^ Los demás avisos de control de carrera.
  , fsPart           :: Maybe Int
    -- ^ La parte de una clasificación: @0@ antes de empezar, después @1@ a @3@.
    -- 'Nothing' fuera de clasificación.
  , fsEntries        :: [Int]
    -- ^ Cuántos entran en cada parte, en orden (@[22, 16, 10]@). Vacía fuera de
    -- clasificación.
  , fsCutOffTime     :: Maybe Text
    -- ^ El tiempo del 107 % (@\"1:45.800\"@), desde que alguien marca vuelta en la
    -- primera parte. __En las siguientes sigue llegando el último__ (medido en
    -- Malasia): quien lo enseñe mira 'fsPart'.
  , fsTrack          :: Maybe FeedTrack  -- ^ El estado de la pista; 'Nothing' sin el tema.
  }
  deriving (Eq, Show)

instance FromJSON FeedSession where
  parseJSON = withObject "FeedSession" $ \o ->
    FeedSession
      <$> o .:? "siType"           .!= ""
      <*> o .:? "siName"           .!= ""
      <*> o .:? "siMeeting"        .!= ""
      <*> o .:? "siCircuit"
      <*> o .:? "siState"          .!= ""
      <*> o .:? "siCurrentLap"
      <*> o .:? "siTotalLaps"
      <*> o .:? "siClockUtc"
      <*> o .:? "siClockRemaining"
      <*> o .:? "siClockRunning"   .!= False
      <*> o .:? "siStartDate"
      <*> o .:? "siGmtOffset"
      <*> o .:? "siFlags"          .!= []
      <*> o .:? "siNotices"        .!= []
      <*> o .:? "siPart"
      <*> o .:? "siEntries"        .!= []
      <*> o .:? "siCutOffTime"
      <*> o .:? "siTrack"

-- | Un aviso de bandera de control de carrera, tal como llega.
--
-- __Trae los de toda la foto, también los de la sesión anterior__: el feed no vacía
-- la lista hasta el primer aviso de la sesión nueva. Quién cuenta lo decide
-- 'Handler.Live.Helper.feedSession'.
data FeedFlag = FeedFlag
  { ffUtc   :: Text  -- ^ En UTC y sin zona: @\"2026-10-03T09:00:00\"@.
  , ffFlag  :: Text  -- ^ @\"CHEQUERED\"@, @\"GREEN\"@, @\"RED\"@, @\"YELLOW\"@…
  , ffScope :: Text  -- ^ @\"Track\"@ para toda la pista; @\"Sector\"@ para uno.
  }
  deriving (Eq, Show)

instance FromJSON FeedFlag where
  parseJSON = withObject "FeedFlag" $ \o ->
    FeedFlag
      <$> o .:? "utc"   .!= ""
      <*> o .:? "flag"  .!= ""
      <*> o .:? "scope" .!= ""

-- | Un aviso de control de carrera que no es de bandera, tal como llega.
--
-- __Trae también los de la sesión anterior__, como 'FeedFlag'. Los que anuncian una
-- hora la escriben en hora local del circuito: @\"RACE WILL START AT 16:33\"@.
data FeedNotice = FeedNotice
  { fnUtc      :: Text  -- ^ En UTC y sin zona, como 'ffUtc'.
  , fnCategory :: Text  -- ^ @\"Other\"@ o @\"SafetyCar\"@ en lo grabado.
  , fnMessage  :: Text
  }
  deriving (Eq, Show)

instance FromJSON FeedNotice where
  parseJSON = withObject "FeedNotice" $ \o ->
    FeedNotice
      <$> o .:? "utc"      .!= ""
      <*> o .:? "category" .!= ""
      <*> o .:? "message"  .!= ""

-- | El estado de la pista, tal como llega. __Puede volver a @AllClear@ con la sesión
-- todavía parada por una roja__ (medido en la P3 de Malasia).
data FeedTrack = FeedTrack
  { ftStatus  :: Text  -- ^ El código: @\"1\"@ a @\"7\"@.
  , ftMessage :: Text  -- ^ @\"AllClear\"@, @\"Yellow\"@, @\"SCDeployed\"@, @\"Red\"@…
  }
  deriving (Eq, Show)

instance FromJSON FeedTrack where
  parseJSON = withObject "FeedTrack" $ \o ->
    FeedTrack
      <$> o .:? "status"  .!= ""
      <*> o .:? "message" .!= ""
