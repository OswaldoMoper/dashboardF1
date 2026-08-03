-- | Área comparación de vueltas — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/comparison@ y delega en 'Handler.Comparison.Context', que
-- orquesta el caso de uso: fetch al microservicio FastF1, cache STM con clave y
-- respaldo al dummy. El dummy que vivía aquí desde la Fase 1 se mudó al
-- 'Handler.Comparison.Context', como en las otras cuatro áreas.
module Handler.Comparison where

import           App                        (Env)
import           Common.Types               (LapComparison)
import           Control.Monad.IO.Class     (liftIO)
import           Data.Text                  (Text)
import qualified Handler.Comparison.Context as Context
import           Servant                    (Handler)

-- | Los dos 'Maybe' vienen de los @QueryParam@ opcionales de 'Server.Api' y bajan
-- sin interpretar: quien decide qué significa su ausencia es
-- 'Handler.Comparison.Context.resolveParams'. Espejo de
-- 'Handler.Telemetry.telemetryHandler', que es el otro endpoint parametrizado del
-- repo.
comparisonHandler :: Env -> Maybe Text -> Maybe Text -> Handler LapComparison
comparisonHandler env session drivers =
  liftIO (Context.getComparison env session drivers)
