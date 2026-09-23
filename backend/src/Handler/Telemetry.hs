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
import           Outcome                   (serve)
import           Servant                   (Handler)

-- | Los dos 'Maybe' vienen de los @QueryParam@ opcionales de 'Server.Api' y
-- bajan sin interpretar: quien decide qué significa su ausencia es
-- 'Handler.Telemetry.Helper.resolveParams'. Esta capa sigue siendo una línea de
-- delegación, como las de las otras cinco áreas.
--
-- __El tipo público no cambia__ y 'Server.Api' tampoco: el @Outcome@ que devuelve
-- el @Context@ muere aquí, en 'Outcome.serve'. Traducir es __todo__ lo que hace,
-- porque quien conoce el contrato del microservicio es el @Context@ que lo llamó —
-- mismo reparto que ya existía con @resolveParams@.
telemetryHandler :: Env -> Maybe Text -> Maybe Text -> Handler [TelemetryPoint]
telemetryHandler env session driver =
  liftIO (Context.getTelemetry env session driver) >>= serve
