-- | API del backend del F1 Functional Dashboard.
--
-- En Fase 0 solo se define el endpoint raíz @GET \/home@. Los endpoints de
-- widgets (@\/api\/live@, @\/api\/telemetry@, …) se agregan en Fase 1.
module Backend.API
  ( HomeAPI
  , Home (..)
  , homeAPI
  , server
  ) where

import Data.Aeson (ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Servant

-- | Respuesta del endpoint raíz.
newtype Home = Home {message :: Text}
  deriving (Eq, Show, Generic)

instance ToJSON Home

-- | @GET \/home@ → @{"message":"F1 Functional Dashboard"}@.
type HomeAPI = "home" :> Get '[JSON] Home

homeAPI :: Proxy HomeAPI
homeAPI = Proxy

server :: Server HomeAPI
server = pure (Home "F1 Functional Dashboard")
