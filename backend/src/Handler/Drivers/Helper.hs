-- | Área parrilla — lógica pura.
--
-- Modela la respuesta del microservicio FastF1 (@telemetry-service@,
-- @GET \/fastf1\/drivers\/{session_key}@): una __lista__ de objetos con las
-- mismas claves que 'DriverEntry'. El tipo crudo existe __aunque la forma
-- coincida hoy__, por la misma razón que en 'Handler.Telemetry.Helper' y
-- 'Handler.Comparison.Helper': no atar el DTO de @common@ al contrato de un
-- servicio que es nuestro y va a moverse. Sin efectos: determinista y testeable.
--
-- __El reparto entre obligatorio y prescindible sigue la identidad__, como en
-- Comparison. 'rdNumber' va con @.:@ porque es la identidad del coche y además
-- lo único que el consumidor puede mandar de vuelta en un query: una entrada sin
-- número no es una entrada degradada, es una fila que no sirve para nada.
-- 'rdCode' también, porque una parrilla es precisamente la tabla de traducción y
-- una entrada sin acrónimo no traduce — el microservicio ya garantiza que
-- siempre hay uno, cayendo al número si FastF1 no lo resuelve (fallback de
-- @_driver_label@).
--
-- 'rdTeam' es la excepción, con @.:? … .!= \"\"@, y por el mismo motivo que los
-- números de coche en Comparison (2026-08-05): el
-- microservicio __no se despliega con el backend__ (@venv@ + @uvicorn@ a mano,
-- 2026-07-31), así que un servicio anterior al equipo
-- seguiría en pie emitiendo solo los dos campos. Con @.:@ eso convertiría
-- __toda__ la parrilla en dummy, en silencio. El equipo es decoración —agrupar,
-- colorear— y no identidad, así que su ausencia degrada la presentación y no el
-- dato.
module Handler.Drivers.Helper
  ( -- * Envoltura cruda del microservicio FastF1
    RawDriver (..)
    -- * Transformación pura
  , assembleDrivers
    -- * Parámetros de la petición
  , defaultSession
  , resolveParams
  ) where

import           Common.Types          (DriverEntry (..))
import           Data.Aeson            (FromJSON (..), withObject, (.!=), (.:),
                                        (.:?))
import           Data.Text             (Text)
import           Handler.FastF1.Helper (sessionParam)
import           Outcome               (Rejection)

-- | Un coche de la parrilla tal como lo emite el microservicio.
data RawDriver = RawDriver
  { rdNumber :: Text
  , rdCode   :: Text
    -- ^ Acrónimo, o el número repetido cuando FastF1 no lo resuelve.
  , rdTeam   :: Text
    -- ^ Vacío si el servicio no emite la clave (ver el encabezado del módulo).
  }
  deriving (Eq, Show)

instance FromJSON RawDriver where
  parseJSON = withObject "RawDriver" $ \o ->
    RawDriver
      <$> o .:  "deNumber"
      <*> o .:  "deCode"
      <*> o .:? "deTeam" .!= ""

-- | Traduce la parrilla cruda a 'DriverEntry' __preservando el orden__, que es
-- el que le da FastF1 (en una carrera cargada, el de clasificación). Reordenar
-- aquí destruiría información que el consumidor no puede reconstruir; ordenar
-- para presentar es trabajo del widget.
--
-- __No filtra nada__, y eso es una decisión y no un olvido: las entradas cuyo
-- acrónimo no resolvió llegan con 'rdCode' repitiendo el número, y se dejan
-- pasar. El coche está en la sesión aunque no se sepa quién lo lleva, así que
-- esconderlo daría una parrilla incompleta sin decirlo — y el consumidor la
-- creería completa. A diferencia de 'Handler.Telemetry.Helper.assemblePoints',
-- aquí no hay canales de medida que puedan faltar: los tres campos están
-- siempre, con valor o vacíos.
assembleDrivers :: [RawDriver] -> [DriverEntry]
assembleDrivers = map entry
  where
    entry raw =
      MkDriverEntry
        { deNumber = rdNumber raw
        , deCode   = rdCode raw
        , deTeam   = rdTeam raw
        }

-- | Sesión que se consulta cuando @\/api\/drivers@ no recibe @?session=@.
-- @latest@ es la última carrera disputada, resuelta por el microservicio.
defaultSession :: Text
defaultSession = "latest"

-- | Aplica el default al @QueryParam@ opcional de 'Server.Api'. Espejo de los
-- @resolveParams@ de Telemetry y Comparison, y por la misma razón: lo que
-- devuelve es también la __clave de cache__, resuelta una sola vez para que
-- @?session=latest@ y la ausencia del parámetro no ocupen dos entradas con el
-- mismo contenido.
--
-- Resuelve una sola clave y no un par, que es la diferencia de forma con las otras
-- dos áreas parametrizadas: aquí solo hay un parámetro que resolver.
--
-- Un parámetro escrito pero vacío se rechaza ('Handler.FastF1.Helper.queryParam').
resolveParams :: Maybe Text -> Either Rejection Text
resolveParams = sessionParam defaultSession
