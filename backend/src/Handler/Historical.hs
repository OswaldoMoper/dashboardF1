-- | Área estadísticas históricas — capa de interfaz.
--
-- Expone @GET \/api\/historical@ y delega en 'Handler.Historical.Context', que
-- orquesta el fetch a Jolpica con cache STM y respaldo al dummy.
module Handler.Historical where

import           App                        (Env)
import           Common.Types               (HistoricalStat)
import           Control.Monad.IO.Class     (liftIO)
import qualified Handler.Historical.Context as Context
import           Servant                    (Handler)

historicalHandler :: Env -> Handler [HistoricalStat]
historicalHandler env = liftIO (Context.getHistorical env)
