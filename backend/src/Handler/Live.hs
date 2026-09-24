-- | Área Live timing — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/live@ y delega en 'Handler.Live.Context', que orquesta las dos
-- fuentes (vía 'Handler.Feed.Manager' y 'Handler.Live.Manager'), el mapeo puro
-- ('Handler.Live.Helper') y la cache STM del 'Env'.
--
-- __Es el único handler que responde con cabeceras propias:__ de dónde salió el
-- dato ('Provenance'), que son dos preguntas —qué peldaño de la escalera y qué
-- fuente— y que el @Context@ conoce en cada una.
--
-- __Las cabeceras siguen siendo metadato y el cuerpo sigue siendo contenido__, y
-- por eso el dato de sesión no entró en ellas: viaja dentro de
-- 'Common.Types.LiveTable', envolviendo las filas (2026-09-13).
module Handler.Live where

import           App                    (Env)
import           Common.Types           (LiveTable)
import           Control.Monad.IO.Class (liftIO)
import           Handler.Live.Context   (LiveResult (..))
import qualified Handler.Live.Context   as Context
import           Provenance             (WithProvenance, withProvenance)
import           Servant                (Handler)

-- | La respuesta de @\/api\/live@: la tabla con su sesión, más las tres cabeceras.
type LiveResponse = WithProvenance LiveTable

liveHandler :: Env -> Handler LiveResponse
liveHandler env = withOrigin <$> liftIO (Context.getLiveTiming env)

-- | Pone la procedencia del resultado en cabeceras ('withProvenance').
withOrigin :: LiveResult -> LiveResponse
withOrigin result =
  withProvenance
    (lrOrigin result) (lrSource result) (lrFetchedAt result) (lrTable result)
