-- | Área comparación de vueltas — lógica pura.
--
-- Modela la respuesta del microservicio FastF1 (@telemetry-service@,
-- @GET \/fastf1\/comparison\/{session_key}?drivers=1,16@): __un objeto__, no una
-- lista, con las mismas claves que 'LapComparison'. Es la primera área del repo
-- cuyo DTO no es una colección, y eso cambia el criterio de fallo del @Context@
-- (ver 'Handler.Comparison.Context.getComparison'). El tipo crudo existe
-- __aunque la forma coincida hoy__, por la misma razón que en
-- 'Handler.Telemetry.Helper': no atar el DTO de @common@ al contrato de un
-- servicio que es nuestro y va a moverse. Sin efectos: determinista y testeable.
--
-- El decode no distingue obligatorios de prescindibles como sí hacen Telemetry y
-- Historical: aquí __los cuatro textos son obligatorios__ (@.:@). No son canales
-- de medida que FastF1 pueda no publicar en una muestra concreta, son la
-- identidad de la comparación —quién contra quién, y en qué tiempos—, y una
-- comparación a la que le falte cualquiera de ellos no es una comparación
-- degradada: es otra cosa.
--
-- La excepción es @lcDelta@, que va con @.:? … .!= []@ __a propósito__: una
-- sesión sin vueltas comparables devuelve la serie vacía (o podría dejar de
-- emitir la clave), y esa respuesta tiene que __decodificar__ para que sea el
-- @Context@ quien la trate como fallo y degrade a cache\/dummy. Con @.:@ el
-- mismo caso llegaría como excepción de parseo: acabaría en el mismo dummy, pero
-- por el camino equivocado y sin que el criterio quedara escrito en ningún sitio.
module Handler.Comparison.Helper
  ( -- * Envoltura cruda del microservicio FastF1
    RawComparison (..)
    -- * Transformación pura
  , assembleComparison
  ) where

import           Common.Types (LapComparison (..))
import           Data.Aeson   (FromJSON (..), withObject, (.!=), (.:), (.:?))
import           Data.Text    (Text)

-- | La comparación tal como la emite el microservicio. Los tiempos llegan ya
-- formateados (@\"1:29.345\"@) porque formatear es trabajo del servicio Python y
-- no de este módulo (2026-07-31).
data RawComparison = RawComparison
  { rcDriverA :: Text
  , rcDriverB :: Text
  , rcLapA    :: Text
  , rcLapB    :: Text
  , rcDelta   :: [Double]
    -- ^ Delta acumulado A−B sobre la rejilla de distancias de A. Vacío cuando la
    -- sesión no tiene vueltas comparables.
  }
  deriving (Eq, Show)

instance FromJSON RawComparison where
  parseJSON = withObject "RawComparison" $ \o ->
    RawComparison
      <$> o .:  "lcDriverA"
      <*> o .:  "lcDriverB"
      <*> o .:  "lcLapA"
      <*> o .:  "lcLapB"
      <*> o .:? "lcDelta" .!= []

-- | Traduce la comparación cruda a 'LapComparison' __preservando el orden de la
-- serie__: @lcDelta@ es el delta a lo largo de la vuelta, así que reordenarlo la
-- destruiría. No filtra nada: a diferencia de 'Handler.Telemetry.Helper.assemblePoints',
-- aquí no hay muestras que descartar una a una — el objeto se sirve entero o el
-- 'Handler.Comparison.Context' lo trata como fallo entero.
assembleComparison :: RawComparison -> LapComparison
assembleComparison raw =
  MkLapComparison
    { lcDriverA = rcDriverA raw
    , lcDriverB = rcDriverB raw
    , lcLapA    = rcLapA raw
    , lcLapB    = rcLapB raw
    , lcDelta   = rcDelta raw
    }
