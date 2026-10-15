-- | Área Live timing — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/live@ y @GET \/api\/calendar@, y delega en
-- 'Handler.Live.Context', que orquesta las dos fuentes (vía 'Handler.Feed.Manager' y
-- 'Handler.Live.Manager'), el mapeo puro ('Handler.Live.Helper') y la cache STM del
-- 'Env'.
--
-- __Responde con cabeceras propias__, como 'Handler.TyreStrategy': de dónde salió el
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
import qualified Handler.Live.Context   as Context
import           Handler.Live.Helper    (CalendarEntry)
import           Provenance             (WithProvenance, withProvenance)
import           Servant                (Handler)

-- | La respuesta de @\/api\/live@: la tabla con su sesión, más las tres cabeceras.
type LiveResponse = WithProvenance LiveTable

liveHandler :: Env -> Handler LiveResponse
liveHandler env = withProvenance <$> liftIO (Context.getLiveTiming env)

calendarHandler :: Env -> Handler [CalendarEntry]
calendarHandler env = liftIO (Context.getCalendar env)
