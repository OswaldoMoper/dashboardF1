-- | Rutas de la API como valores: fuente única de los paths que consume el
-- frontend (fetch) y que expone el backend ('Server.Api'). Se mantienen como
-- valores (no constructores homónimos) para no colisionar con los data
-- constructors de 'Common.Types' ('LiveTiming', 'Telemetry', …); de ahí el
-- sufijo @Api@ en 'ApiRoute'.
module Common.Route
  ( ApiRoute (..)
  , apiPath
  , livePath
  , telemetryPath
  , historicalPath
  ) where

import           Data.Text (Text)

-- | Endpoints de la API de widgets (espejo de @Server.Api@).
data ApiRoute
  = LiveApi
  | HistoricalApi
  | TelemetryApi
  | ComparisonApi
  | TyreStrategyApi
  deriving stock (Eq, Show)

-- | Path (relativo, misma-origen) de cada endpoint.
apiPath :: ApiRoute -> Text
apiPath = \case
  LiveApi         -> "/api/live"
  HistoricalApi   -> "/api/historical"
  TelemetryApi    -> "/api/telemetry"
  ComparisonApi   -> "/api/comparison"
  TyreStrategyApi -> "/api/tyre-strategy"

-- | Atajo para el endpoint de live timing (primer consumidor).
livePath :: Text
livePath = apiPath LiveApi

-- | Atajo para el endpoint de telemetría.
telemetryPath :: Text
telemetryPath = apiPath TelemetryApi

-- | Atajo para el endpoint de estadísticas históricas.
historicalPath :: Text
historicalPath = apiPath HistoricalApi
