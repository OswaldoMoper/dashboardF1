-- | Aplicación WAI de nivel superior (INFRA).
--
-- Define el tipo de la API Servant y ensambla el 'server': los endpoints de
-- infra (@GET \/@ shell HTML, @GET \/home@ JSON de bienvenida) se resuelven
-- aquí; los @GET \/api\/*@ de negocio delegan en los @Handler.<Área>@. El
-- servido del bundle estático del SPA (@spaApp@) se añadirá cuando exista el
-- build del frontend.
module Server where

import App (Env)
import Common.Types
  ( HistoricalStat
  , LapComparison
  , LiveTimingRow
  , TelemetryPoint
  , TyreStint
  )
import Data.Aeson (ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import qualified Handler.Comparison as Comparison
import qualified Handler.Historical as Historical
import qualified Handler.Live as Live
import qualified Handler.Telemetry as Telemetry
import qualified Handler.TyreStrategy as TyreStrategy
import Html (page)
import Lucid (Html)
import Servant
import Servant.HTML.Lucid (HTML)

-- | Respuesta del endpoint de bienvenida.
newtype Home = Home {message :: Text}
  deriving (Eq, Show, Generic)

instance ToJSON Home

-- | API completa del backend.
type Api =
       Get '[HTML] (Html ())
  :<|> "home" :> Get '[JSON] Home
  :<|> "api" :> "live" :> Get '[JSON] [LiveTimingRow]
  :<|> "api" :> "historical" :> Get '[JSON] [HistoricalStat]
  :<|> "api" :> "telemetry" :> Get '[JSON] [TelemetryPoint]
  :<|> "api" :> "comparison" :> Get '[JSON] LapComparison
  :<|> "api" :> "tyre-strategy" :> Get '[JSON] [TyreStint]

api :: Proxy Api
api = Proxy

-- | 'Application' WAI del backend.
app :: Env -> Application
app env = serve api (server env)

-- | Cableado: infra (@/@, @/home@) + delegación a los handlers de negocio.
server :: Env -> Server Api
server env =
  rootH
    :<|> homeH
    :<|> Live.liveHandler env
    :<|> Historical.historicalHandler env
    :<|> Telemetry.telemetryHandler env
    :<|> Comparison.comparisonHandler env
    :<|> TyreStrategy.tyreStrategyHandler env
  where
    rootH :: Handler (Html ())
    rootH = pure page

    homeH :: Handler Home
    homeH = pure (Home "F1 Functional Dashboard")
