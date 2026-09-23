-- | Área telemetría — lógica pura.
--
-- Modela la respuesta del microservicio FastF1 (@telemetry-service@,
-- @GET \/fastf1\/telemetry\/{session_key}\/{driver}@): un arreglo __plano y
-- multi-piloto__ de muestras submuestreadas, cada una etiquetada con el acrónimo
-- del piloto y con las mismas claves que 'TelemetryPoint'. El tipo crudo existe
-- __aunque la forma coincida hoy__ para no atar el DTO de @common@ al contrato
-- de un servicio que es nuestro y va a moverse: 'assemblePoints' es el punto
-- donde se absorbe cualquier divergencia. Sin efectos: determinista y testeable.
--
-- El decode distingue campos __obligatorios__ (@tpDriver@, @tpSessionTime@,
-- @tpDistance@, @tpSpeed@: de quién es la muestra, cuándo, dónde en la vuelta y
-- a qué velocidad — sin ellos no se puede atribuir ni situar) de campos
-- __prescindibles__ (@tpThrottle@, @tpBrake@, @tpGear@, @tpRpm@: canales de
-- coche que FastF1 puede no publicar en una muestra concreta), que son @.:?@
-- para que su ausencia descarte __esa__ muestra en 'assemblePoints' en vez de
-- tumbar la vuelta de los veinte pilotos hacia cache\/dummy
-- (2026-07-30). No llevan defecto numérico a propósito: un
-- @tpBrake@ de @0@ afirmaría "no frenaba" y un @tpGear@ de @0@ punto muerto —
-- inventar un dato es peor que omitir una muestra, el mismo criterio que hizo
-- que el defecto de @wins@ en Jolpica sea @""@ y no @"0"@.
module Handler.Telemetry.Helper
  ( -- * Envoltura cruda del microservicio FastF1
    FastF1Point (..)
    -- * Transformación pura
  , assemblePoints
    -- * Parámetros de la petición
  , defaultSession
  , defaultDrivers
  , resolveParams
  ) where

import           Common.Types (TelemetryPoint (..))
import           Data.Aeson   (FromJSON (..), withObject, (.:), (.:?))
import           Data.Maybe   (fromMaybe, mapMaybe)
import           Data.Text    (Text)

-- | Una muestra tal como la emite el microservicio. Los cuatro canales de coche
-- son 'Maybe' porque el servicio los publica como @null@ cuando FastF1 no los
-- midió (ver el encabezado del módulo).
data FastF1Point = FastF1Point
  { ffDriver      :: Text
  , ffSessionTime :: Double
  , ffDistance    :: Double
  , ffSpeed       :: Double
  , ffThrottle    :: Maybe Double
  , ffBrake       :: Maybe Double
  , ffGear        :: Maybe Int
  , ffRpm         :: Maybe Int
  }
  deriving (Eq, Show)

instance FromJSON FastF1Point where
  parseJSON = withObject "FastF1Point" $ \o ->
    FastF1Point
      <$> o .:  "tpDriver"
      <*> o .:  "tpSessionTime"
      <*> o .:  "tpDistance"
      <*> o .:  "tpSpeed"
      <*> o .:? "tpThrottle"
      <*> o .:? "tpBrake"
      <*> o .:? "tpGear"
      <*> o .:? "tpRpm"

-- | Traduce las muestras crudas a 'TelemetryPoint' __preservando el orden__: la
-- vuelta de cada piloto es una serie temporal y los pilotos llegan en bloques
-- contiguos, así que reordenar destruiría las dos cosas. Descarta con 'mapMaybe'
-- la muestra a la que le falte cualquiera de los cuatro canales opcionales —
-- 'TelemetryPoint' los exige totales y rellenarlos con ceros publicaría un
-- frenazo o un punto muerto que FastF1 nunca midió. La vuelta pierde
-- resolución, no validez.
assemblePoints :: [FastF1Point] -> [TelemetryPoint]
assemblePoints = mapMaybe toPoint
  where
    toPoint p =
      TelemetryPoint (ffDriver p) (ffSessionTime p) (ffDistance p) (ffSpeed p)
        <$> ffThrottle p
        <*> ffBrake p
        <*> ffGear p
        <*> ffRpm p

-- | Sesión que se consulta cuando @\/api\/telemetry@ no recibe @?session=@.
-- @latest@ es la última carrera disputada, resuelta por el microservicio.
defaultSession :: Text
defaultSession = "latest"

-- | Pilotos que se consultan cuando @\/api\/telemetry@ no recibe @?driver=@.
-- @all@ trae la vuelta rápida de __todos__ los de la sesión en una sola llamada
-- HTTP; pedirlos uno a uno necesitaría @async@, que no es dependencia del
-- backend, y multiplicaría los puntos de fallo del @try@
-- (2026-07-31).
defaultDrivers :: Text
defaultDrivers = "all"

-- | Aplica los defaults a los @QueryParam@ opcionales de 'Server.Api'. El
-- invariante que fija —ausencia de parámetros ≡ comportamiento previo a que
-- existieran— es el criterio de aceptación de todo el cambio.
--
-- El par que devuelve es también la __clave de cache__, y por eso se resuelve
-- una sola vez: cachear bajo la clave sin resolver haría que
-- @?session=latest@ y la ausencia de parámetro ocuparan dos entradas distintas
-- con el mismo contenido.
resolveParams :: Maybe Text -> Maybe Text -> (Text, Text)
resolveParams session driver =
  (fromMaybe defaultSession session, fromMaybe defaultDrivers driver)
