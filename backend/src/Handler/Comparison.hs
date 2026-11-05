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
import           Provenance                 (WithProvenance, withProvenance)
import           Servant                    (Handler)

-- | La respuesta de @\/api\/comparison@: la comparación, más las tres cabeceras.
type ComparisonResponse = WithProvenance LapComparison

-- | Los tres 'Maybe' vienen de los @QueryParam@ opcionales de 'Server.Api' y bajan
-- sin interpretar: quien decide qué significa su ausencia es
-- 'Handler.Comparison.Helper.resolveParams'.
--
-- El @Outcome@ que devuelve el @Context@ muere aquí, en 'Outcome.serve', y lo servido
-- sale con sus cabeceras ('Provenance'); el cuerpo JSON es el de siempre.
--
-- Traducir es __todo__ lo que hace: no decide nada sobre el fallo, porque quien
-- conoce el contrato del microservicio es el @Context@ que lo llamó. Mismo reparto
-- que ya existía con @resolveParams@.
comparisonHandler
  :: Env -> Maybe Text -> Maybe Text -> Maybe Int -> Handler ComparisonResponse
comparisonHandler env session drivers samples =
  withProvenance <$> (liftIO (Context.getComparison env session drivers samples) >>= serve)
