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
  ( FeedRow (..)
  , FeedSession (..)
  ) where

import           Data.Aeson (FromJSON (..), withObject, (.!=), (.:), (.:?))
import           Data.Text  (Text)

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
  , fsState          :: Text
  , fsCurrentLap     :: Maybe Int
  , fsTotalLaps      :: Maybe Int
  , fsClockUtc       :: Maybe Text  -- ^ Instante en que el feed publicó el reloj, ISO 8601.
  , fsClockRemaining :: Maybe Text  -- ^ Lo que quedaba entonces, @\"HH:MM:SS\"@.
  , fsClockRunning   :: Bool        -- ^ Si descontaba desde ese instante.
  }
  deriving (Eq, Show)

instance FromJSON FeedSession where
  parseJSON = withObject "FeedSession" $ \o ->
    FeedSession
      <$> o .:? "siType"           .!= ""
      <*> o .:? "siName"           .!= ""
      <*> o .:? "siMeeting"        .!= ""
      <*> o .:? "siState"          .!= ""
      <*> o .:? "siCurrentLap"
      <*> o .:? "siTotalLaps"
      <*> o .:? "siClockUtc"
      <*> o .:? "siClockRemaining"
      <*> o .:? "siClockRunning"   .!= False
