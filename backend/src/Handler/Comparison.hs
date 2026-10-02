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
import           Outcome                    (serve)
import           Servant                    (Handler)

-- | Los tres 'Maybe' vienen de los @QueryParam@ opcionales de 'Server.Api' y bajan
-- sin interpretar: quien decide qué significa su ausencia es
-- 'Handler.Comparison.Helper.resolveParams'. Espejo de
-- 'Handler.Telemetry.telemetryHandler', que es el otro endpoint parametrizado del
-- repo.
--
-- __El tipo público no cambia__ y 'Server.Api' tampoco: el @Outcome@ que ahora
-- devuelve el @Context@ muere aquí, en 'Outcome.serve'. Es el primer handler del
-- repo que puede no responder @200@ —y el primer @throwError@—, pero la forma del
-- endpoint es la misma, así que las otras cinco áreas siguen cableadas igual
-- mientras les llega el turno.
--
-- Traducir es __todo__ lo que hace: no decide nada sobre el fallo, porque quien
-- conoce el contrato del microservicio es el @Context@ que lo llamó. Mismo reparto
-- que ya existía con @resolveParams@.
comparisonHandler
  :: Env -> Maybe Text -> Maybe Text -> Maybe Int -> Handler LapComparison
comparisonHandler env session drivers samples =
  liftIO (Context.getComparison env session drivers samples) >>= serve
