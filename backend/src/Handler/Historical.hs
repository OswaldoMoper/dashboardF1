-- | Área estadísticas históricas — capa de interfaz.
--
-- Expone @GET \/api\/historical@ y delega en 'Handler.Historical.Context', que
-- orquesta el fetch a Jolpica con cache STM y respaldo al dummy.
module Handler.Historical where

import           App                        (Env)
import           Common.Types               (HistoricalStat)
import           Control.Monad.IO.Class     (liftIO)
import           Data.Text                  (Text)
import qualified Handler.Historical.Context as Context
import           Outcome                    (serve)
import           Servant                    (Handler)

-- | El 'Maybe' es el @?session=@ opcional de 'Server.Api', sin interpretar: lo lee
-- 'Handler.Historical.Helper.resolveStandings'.
historicalHandler :: Env -> Maybe Text -> Handler [HistoricalStat]
historicalHandler env session = liftIO (Context.getHistorical env session) >>= serve
