-- | Área telemetría — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/telemetry@ y delega en 'Handler.Telemetry.Context', que
-- orquesta el caso de uso: fetch al microservicio FastF1, cache STM con clave y
-- respaldo al dummy.
module Handler.Telemetry where

import           App                       (Env)
import           Common.Types              (TelemetryPoint)
import           Control.Monad.IO.Class    (liftIO)
import           Data.Text                 (Text)
import qualified Handler.Telemetry.Context as Context
import           Servant                   (Handler)

-- | Los dos 'Maybe' vienen de los @QueryParam@ opcionales de 'Server.Api' y
-- bajan sin interpretar: quien decide qué significa su ausencia es
-- 'Handler.Telemetry.Context.resolveParams'. Esta capa sigue siendo una línea de
-- delegación, como las de las otras cuatro áreas.
telemetryHandler :: Env -> Maybe Text -> Maybe Text -> Handler [TelemetryPoint]
telemetryHandler env session driver =
  liftIO (Context.getTelemetry env session driver)
