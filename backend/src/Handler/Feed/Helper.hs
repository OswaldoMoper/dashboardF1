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
