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
  , comparisonPath
  , comparisonPathFor
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
  pathWith telemetryPath [("session", session), ("driver", driver)]

-- | Atajo para el endpoint de comparación de vueltas.
comparisonPath :: Text
comparisonPath = apiPath ComparisonApi

-- | Path de comparación con sesión y\/o coches en el query string, omitiendo los
-- ausentes: sin ninguno devuelve 'comparisonPath' tal cual. Espejo del
-- @QueryParam \"session\" :> QueryParam \"drivers\"@ de @Server.Api@ — ambos
-- opcionales en los dos extremos.
--
-- Hereda los dos supuestos de 'telemetryPathFor' (sin escapado de query; los
-- valores son números de coche, no acrónimos) y añade uno propio: __@drivers@ son
-- exactamente dos__, separados por coma (@\"1,16\"@). El microservicio responde
-- 400 a cualquier otra cantidad, así que no hay análogo del @all@ de telemetría —
-- 'Common.Types.LapComparison' tiene A y B, no una lista.
comparisonPathFor :: Maybe Text -> Maybe Text -> Text
comparisonPathFor session drivers =
  pathWith comparisonPath [("session", session), ("drivers", drivers)]

-- | Un path con los parámetros presentes en el query string, en el orden dado, y
-- sin @?@ cuando no hay ninguno. Único sitio del módulo que compone query
-- strings: lo comparten 'telemetryPathFor' y 'comparisonPathFor', y con el
-- segundo endpoint parametrizado la alternativa era el mismo @case@ duplicado dos
-- veces.
--
-- Aquí vive el supuesto de __no escapar__: correcto para los valores de hoy
-- (alfanuméricos, guiones y comas), y el día que uno admita espacios o @&@ este es
-- el único punto que hay que cambiar.
pathWith :: Text -> [(Text, Maybe Text)] -> Text
pathWith path params =
  case catMaybes [fmap ((key <> "=") <>) value | (key, value) <- params] of
    []      -> path
    present -> path <> "?" <> T.intercalate "&" present

-- | Atajo para el endpoint de estadísticas históricas.
historicalPath :: Text
historicalPath = apiPath HistoricalApi
