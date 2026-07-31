-- | Área telemetría — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/telemetry@ y delega en 'Handler.Telemetry.Context', que
-- orquesta el caso de uso (hoy: el dummy; en el commit siguiente, el fetch al
-- microservicio FastF1 con cache STM y respaldo al dummy).
module Handler.Telemetry where

import           App                       (Env)
import           Common.Types              (TelemetryPoint)
import           Control.Monad.IO.Class    (liftIO)
import qualified Handler.Telemetry.Context as Context
import           Servant                   (Handler)

telemetryHandler :: Env -> Handler [TelemetryPoint]
telemetryHandler env = liftIO (Context.getTelemetry env)
