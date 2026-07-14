-- | API del backend del F1 Functional Dashboard.
--
-- Fase 1: además del endpoint raíz @GET \/home@, expone los endpoints stub de
-- widgets bajo @\/api@ con datos dummy estáticos. Se añaden @\/api\/live@ y @\/api\/historical@.
module Backend.API where

import Common.Types
  ( HistoricalStat (..)
  , LapComparison (..)
  , LiveTimingRow (..)
  , TelemetryPoint (..)
  , TyreStint (..)
  )
import Data.Aeson (ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Servant

-- | Respuesta del endpoint raíz.
newtype Home = Home {message :: Text}
  deriving (Eq, Show, Generic)

instance ToJSON Home

-- | API completa del backend.
--
-- @GET \/home@ → JSON de bienvenida; @GET \/api\/live@ y @GET \/api\/historical@
-- → datos dummy tipados desde @Common.Types@.
type API =
       "home" :> Get '[JSON] Home
  :<|> "api" :> "live" :> Get '[JSON] [LiveTimingRow]
  :<|> "api" :> "historical" :> Get '[JSON] [HistoricalStat]
  :<|> "api" :> "telemetry" :> Get '[JSON] [TelemetryPoint]
  :<|> "api" :> "comparison" :> Get '[JSON] LapComparison
  :<|> "api" :> "tyre-strategy" :> Get '[JSON] [TyreStint]

api :: Proxy API
api = Proxy

server :: Server API
server =
  homeH
    :<|> liveH
    :<|> historicalH
    :<|> telemetryH
    :<|> comparisonH
    :<|> tyreStrategyH
  where
    homeH :: Handler Home
    homeH = pure (Home "F1 Functional Dashboard")

    liveH :: Handler [LiveTimingRow]
    liveH = pure liveDummy

    historicalH :: Handler [HistoricalStat]
    historicalH = pure historicalDummy

    telemetryH :: Handler [TelemetryPoint]
    telemetryH = pure telemetryDummy

    comparisonH :: Handler LapComparison
    comparisonH = pure comparisonDummy

    tyreStrategyH :: Handler [TyreStint]
    tyreStrategyH = pure tyreStrategyDummy

-- | Datos dummy de live timing (top 3 estático).
liveDummy :: [LiveTimingRow]
liveDummy =
  [ LiveTimingRow 1 "VER" "Red Bull" "LEADER" "-" "1:29.345"
  , LiveTimingRow 2 "LEC" "Ferrari" "+1.234" "+1.234" "1:29.512"
  , LiveTimingRow 3 "NOR" "McLaren" "+3.877" "+2.643" "1:29.701"
  ]

-- | Datos dummy de estadísticas históricas.
historicalDummy :: [HistoricalStat]
historicalDummy =
  [ HistoricalStat "Wins" 63 "races"
  , HistoricalStat "Pole positions" 44 "quali"
  , HistoricalStat "Fastest laps" 34 "laps"
  ]

-- | Datos dummy de telemetría (muestreo a lo largo de una vuelta).
telemetryDummy :: [TelemetryPoint]
telemetryDummy =
  [ TelemetryPoint 0.0 0 312.5 1.0 0.0 8 11800
  , TelemetryPoint 0.5 42 298.1 0.0 0.6 7 10500
  , TelemetryPoint 1.0 78 265.3 0.0 1.0 5 9200
  , TelemetryPoint 1.5 110 289.7 0.8 0.0 6 10100
  , TelemetryPoint 2.0 156 320.4 1.0 0.0 8 12000
  ]

-- | Datos dummy de comparación de vuelta entre dos drivers.
comparisonDummy :: LapComparison
comparisonDummy =
  MkLapComparison
    { lcDriverA = "VER"
    , lcDriverB = "LEC"
    , lcLapA = "1:29.345"
    , lcLapB = "1:29.512"
    , lcDelta = [0.0, -0.05, 0.08, 0.12, 0.167]
    }

-- | Datos dummy de estrategia de neumáticos (stints por driver).
tyreStrategyDummy :: [TyreStint]
tyreStrategyDummy =
  [ TyreStint "VER" "MEDIUM" 1 18
  , TyreStint "VER" "HARD" 19 44
  , TyreStint "LEC" "SOFT" 1 14
  , TyreStint "LEC" "HARD" 15 44
  ]
