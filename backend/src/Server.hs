-- | Aplicación WAI de nivel superior (INFRA).
--
-- Define el tipo de la API Servant y ensambla el 'server': @GET \/home@ (JSON
-- de bienvenida) y los @GET \/api\/*@ de negocio (delegados en los
-- @Handler.<Área>@) se resuelven aquí; cualquier otra ruta cae en 'spaApp',
-- que sirve el bundle del frontend (SPA) desde 'cfgStaticDir'. Así el frontend
-- y la API comparten proceso y puerto (misma-origen; el widget hace fetch
-- relativo a @\/api\/*@).
module Server where

import           App                            (Env (..))
import           Common.Types                   (HistoricalStat, LapComparison,
                                                 LiveTimingRow, TelemetryPoint,
                                                 TyreStint)
import           Config                         (cfgStaticDir)
import           Data.Aeson                     (ToJSON)
import           Data.Text                      (Text)
import           GHC.Generics                   (Generic)
import qualified Handler.Comparison             as Comparison
import qualified Handler.Historical             as Historical
import qualified Handler.Live                   as Live
import qualified Handler.Telemetry              as Telemetry
import qualified Handler.TyreStrategy           as TyreStrategy
import           Network.HTTP.Types             (hContentType, status200)
import           Network.Wai                    (Application, responseFile)
import           Network.Wai.Application.Static (defaultWebAppSettings,
                                                 staticApp)
import           Servant
import           System.FilePath                ((</>))
import           WaiAppStatic.Types             (StaticSettings (..))

-- | Respuesta del endpoint de bienvenida.
newtype Home = Home {message :: Text}
  deriving (Eq, Show, Generic)

instance ToJSON Home

-- | API completa del backend. El @Raw@ final atrapa @/@ y toda ruta no-API,
-- delegando en 'spaApp' (bundle del frontend). Va al final: Servant prueba en
-- orden, así que @/home@ y @/api/*@ ganan y el resto cae en el SPA.
--
-- @/api/telemetry@ estrena los primeros 'QueryParam' del repo. Los dos son
-- __opcionales__ (sin @Required@, así que el handler recibe 'Maybe'): sin
-- parámetros el endpoint tiene que comportarse exactamente como antes de
-- existir ellos, y es 'Handler.Telemetry.Context.resolveParams' quien aplica los
-- defaults. El espejo del lado frontend es
-- 'Common.Route.telemetryPathFor'.
type Api =
       "home" :> Get '[JSON] Home
  :<|> "api" :> "live" :> Get '[JSON] [LiveTimingRow]
  :<|> "api" :> "historical" :> Get '[JSON] [HistoricalStat]
  :<|> "api" :> "telemetry"
         :> QueryParam "session" Text
         :> QueryParam "driver" Text
         :> Get '[JSON] [TelemetryPoint]
  :<|> "api" :> "comparison" :> Get '[JSON] LapComparison
  :<|> "api" :> "tyre-strategy" :> Get '[JSON] [TyreStint]
  :<|> Raw

api :: Proxy Api
api = Proxy

-- | 'Application' WAI del backend.
app :: Env -> Application
app env = serve api (server env)

-- | Cableado: @/home@ + delegación a los handlers de negocio + fallback SPA.
server :: Env -> Server Api
server env =
  homeH
    :<|> Live.liveHandler env
    :<|> Historical.historicalHandler env
    :<|> Telemetry.telemetryHandler env
    :<|> Comparison.comparisonHandler env
    :<|> TyreStrategy.tyreStrategyHandler env
    :<|> Tagged (spaApp env)
  where
    homeH :: Handler Home
    homeH = pure (Home "F1 Functional Dashboard")

-- | Sirve el bundle estático del frontend desde 'cfgStaticDir'. Un archivo
-- concreto gana; cualquier otra ruta cae en @index.html@ (fallback SPA), para
-- que los deep-links del enrutado client-side resuelvan en vez de dar 404.
spaApp :: Env -> Application
spaApp env = staticApp settings
  where
    dir = cfgStaticDir (envConfig env)
    settings = (defaultWebAppSettings dir) {ss404Handler = Just serveIndex}
    serveIndex _req send =
      send $
        responseFile
          status200
          [(hContentType, "text/html; charset=utf-8")]
          (dir </> "index.html")
          Nothing
