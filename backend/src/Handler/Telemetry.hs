-- | Área telemetría — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/telemetry@ y delega en 'Handler.Telemetry.Context', que
-- orquesta el caso de uso: fetch al microservicio FastF1, cache STM con clave y
-- respaldo al dummy. Responde con la procedencia en cabeceras ('Provenance'), como
-- 'Handler.Live'; el cuerpo JSON es el de siempre.
module Handler.Telemetry where

import           App                       (Env)
import           Common.Types              (TelemetryPoint)
import           Control.Monad.IO.Class    (liftIO)
import           Data.Text                 (Text)
import qualified Handler.Telemetry.Context as Context
import           Outcome                   (serve)
import           Provenance                (WithProvenance, withProvenance)
import           Servant                   (Handler)

-- | La respuesta de @\/api\/telemetry@: los puntos, más las tres cabeceras.
type TelemetryResponse = WithProvenance [TelemetryPoint]

-- | Los dos 'Maybe' vienen de los @QueryParam@ opcionales de 'Server.Api' y
-- bajan sin interpretar: quien decide qué significa su ausencia es
-- 'Handler.Telemetry.Helper.resolveParams'.
--
-- El @Outcome@ que devuelve el @Context@ muere aquí, en 'Outcome.serve', y lo servido
-- sale con sus cabeceras. Traducir es __todo__ lo que hace, porque quien conoce el
-- contrato del microservicio es el @Context@ que lo llamó.
telemetryHandler :: Env -> Maybe Text -> Maybe Text -> Handler TelemetryResponse
telemetryHandler env session driver =
  withProvenance <$> (liftIO (Context.getTelemetry env session driver) >>= serve)
