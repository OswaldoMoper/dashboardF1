-- | Área temporada — capa de interfaz.
--
-- Expone @GET \/api\/season@ y @GET \/api\/circuit-seasons@, y delega en
-- 'Handler.Season.Context'.
module Handler.Season where

import           App                    (Env)
import           Common.Session         (CircuitRound, SeasonRace)
import           Control.Monad.IO.Class (liftIO)
import qualified Handler.Season.Context as Context
import           Data.Text              (Text)
import           Servant                (Handler)

seasonHandler :: Env -> Handler [SeasonRace]
seasonHandler env = liftIO (Context.getNamedSeason env)

circuitSeasonsHandler :: Env -> Maybe Text -> Handler [CircuitRound]
circuitSeasonsHandler env session = liftIO (Context.getCircuitSeasons env session)
