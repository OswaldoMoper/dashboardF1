-- | Área Live timing — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/live@ y delega en 'Handler.Live.Context', que orquesta el
-- fetch real a OpenF1 (vía 'Handler.Live.Manager'), el mapeo puro
-- ('Handler.Live.Helper') y la cache STM del 'Env'.
module Handler.Live where

import           App                    (Env)
import           Common.Types           (LiveTimingRow)
import           Control.Monad.IO.Class (liftIO)
import qualified Handler.Live.Context   as Context
import           Servant                (Handler)

liveHandler :: Env -> Handler [LiveTimingRow]
liveHandler env = liftIO (Context.getLiveTiming env)
