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
  , telemetryPathFor
  , historicalPath
  ) where

import           Data.Maybe (catMaybes)
import           Data.Text  (Text)
import qualified Data.Text  as T

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

-- | Path de telemetría con sesión y\/o piloto en el query string, omitiendo los
-- ausentes: sin ninguno devuelve 'telemetryPath' tal cual, que es exactamente el
-- comportamiento de hoy. Espejo del @QueryParam \"session\" :> QueryParam
-- \"driver\"@ de @Server.Api@ — ambos opcionales en los dos extremos.
--
-- Convive con 'telemetryPath' en vez de sustituirlo: 'Widgets.Telemetry' filtra
-- __en cliente__ y sigue pidiendo la lista completa una sola vez
-- (2026-08-01), así que esto es capacidad de la API —para
-- @curl@ y para el futuro widget de comparación—, no el mecanismo del widget.
--
-- Dos supuestos que conviene dejar escritos, porque son supuestos y no descuidos:
--
-- * __Sin escapado de query.__ Los valores admitidos hoy son alfanuméricos,
--   guiones y comas (@latest@, @2026-13-R@, @all@, @1,4@), así que concatenar es
--   correcto. El día que un parámetro admita espacios o @&@ hará falta
--   @renderQuery@ de @http-types@ (dependencia nueva en @common@, que se mantiene
--   ligero a propósito para compilar bajo GHCJS).
--
-- * __@driver@ son números de coche, no acrónimos.__ El valor viaja tal cual al
--   segmento @{driver}@ del microservicio FastF1, que acepta @all@ o @1,4,16@; un
--   @VER@ devuelve 400 y el endpoint degrada a cache\/dummy. El acrónimo es el
--   vocabulario del __widget__ (@tpDriver@), no el de la API.
telemetryPathFor :: Maybe Text -> Maybe Text -> Text
telemetryPathFor session driver =
  case catMaybes [param "session" session, param "driver" driver] of
    []     -> telemetryPath
    params -> telemetryPath <> "?" <> T.intercalate "&" params
  where
    param key = fmap (\value -> key <> "=" <> value)

-- | Atajo para el endpoint de estadísticas históricas.
historicalPath :: Text
historicalPath = apiPath HistoricalApi
