-- | Rutas de la API como valores: fuente única de los paths que consume el
-- frontend (fetch) y que expone el backend ('Server.Api'). Se mantienen como
-- valores (no constructores homónimos) para no colisionar con los data
-- constructors de 'Common.Types' ('LiveTiming', 'LapComparison', …); de ahí el
-- sufijo @Api@ en 'ApiRoute'.
module Common.Route
  ( ApiRoute (..)
  , apiPath
  , livePath
  , comparisonPath
  , comparisonPathFor
  , driversParam
  , driversPath
  , driversPathFor
  , historicalPath
  , f1tvPath
  ) where

import           Data.Char  (isDigit)
import           Data.Maybe (catMaybes)
import           Data.Text  (Text)
import qualified Data.Text  as T

-- | Endpoints de la API de widgets (espejo de @Server.Api@).
data ApiRoute
  = LiveApi
  | HistoricalApi
  | ComparisonApi
  | DriversApi
  | TyreStrategyApi
  | F1TVApi
  deriving stock (Eq, Show)

-- | Path (relativo, misma-origen) de cada endpoint.
apiPath :: ApiRoute -> Text
apiPath = \case
  LiveApi         -> "/api/live"
  HistoricalApi   -> "/api/historical"
  ComparisonApi   -> "/api/comparison"
  DriversApi      -> "/api/drivers"
  TyreStrategyApi -> "/api/tyre-strategy"
  F1TVApi         -> "/api/f1tv"

-- | Atajo para el endpoint de live timing (primer consumidor).
livePath :: Text
livePath = apiPath LiveApi

-- | Atajo para el endpoint de comparación de vueltas.
comparisonPath :: Text
comparisonPath = apiPath ComparisonApi

-- | Path de comparación con sesión, coches y muestras en el query string, omitiendo
-- los ausentes y unas muestras que no sean positivas: sin nada devuelve
-- 'comparisonPath' tal cual. Espejo de los tres @QueryParam@ de @Server.Api@,
-- opcionales en los dos extremos.
--
-- Tres supuestos que conviene dejar escritos, porque son supuestos y no descuidos:
--
-- * __Sin escapado de query__, el de 'pathWith'.
--
-- * __@drivers@ son números de coche, no acrónimos.__ El valor viaja tal cual al
--   microservicio FastF1: un acrónimo que la sesión reconoce lo traduce a su
--   número, y cualquier otra cosa la pasa tal cual. Lo que el usuario teclea lo
--   filtra 'driversParam'.
--
-- * __@drivers@ son de 1 a 5__, separados por coma y con la referencia primero
--   (@\"16,1\"@). El microservicio responde 400 a cualquier otra cantidad.
comparisonPathFor :: Maybe Text -> Maybe Text -> Int -> Text
comparisonPathFor session drivers samples =
  pathWith comparisonPath
    [ ("session", session)
    , ("drivers", drivers)
    , ("samples", if samples > 0 then Just (T.pack (show samples)) else Nothing)
    ]

-- | El valor de @?drivers=@ a partir de dos entradas de usuario, en ese orden (la
-- primera es la referencia), o 'Nothing' si alguna no es un número de coche.
-- Pensada para alimentar directamente el segundo argumento de 'comparisonPathFor'.
--
-- __Es el guardián del desajuste de vocabularios__, no una comodidad de
-- formateo. El microservicio traduce a número un acrónimo que la sesión
-- reconoce, pero uno que no reconoce lo pasa tal cual y la comparación degrada
-- sin decirlo (riesgo anotado el 2026-08-01). Con esto, lo que no es un número
-- escrito en el widget __no llega a salir__ — no hay petición, en vez de una
-- petición que degrada en silencio.
--
-- Vive aquí y no en el widget por el criterio del 2026-08-04 (lo puro y sin
-- Reflex va a @common@): el paquete @frontend@ no tiene suite, así que esta es
-- la única forma de que la validación esté __probada__ y no solo revisada a ojo.
-- Y vive junto a 'comparisonPathFor' porque compone justo su argumento, con el
-- mismo supuesto de no escapar: la salida son dígitos y una coma.
--
-- Lo que __no__ hace, y conviene que esté escrito: no comprueba que los coches
-- existan en la sesión ni que sean distintos. @1,1@ es legal —una vuelta contra
-- sí misma, delta todo ceros, que 'Common.Chart' cubre— y un número inexistente
-- es cosa del microservicio.
driversParam :: Text -> Text -> Maybe Text
driversParam a b = do
  carA <- carNumber a
  carB <- carNumber b
  pure (carA <> "," <> carB)

-- | Una entrada de usuario como número de coche: recortada, no vacía y solo
-- dígitos. Recorta porque el espacio sobrante es un descuido de tecleo y no una
-- intención; rechaza todo lo demás porque el único vocabulario que la API acepta
-- es el numérico.
carNumber :: Text -> Maybe Text
carNumber raw
  | T.null trimmed          = Nothing
  | T.all isDigit trimmed   = Just trimmed
  | otherwise               = Nothing
  where
    trimmed = T.strip raw

-- | Atajo para el endpoint de la parrilla.
--
-- __No confundir con 'driversParam'__, que pese al nombre parecido pertenece a
-- otro endpoint: aquélla construye el valor de @?drivers=@ de __comparación__ (dos
-- números separados por coma), y esto es el path de la lista de coches de la
-- sesión. Los dos nombres conviven porque el vocabulario del dominio los llama
-- igual; el sufijo es lo que los distingue.
driversPath :: Text
driversPath = apiPath DriversApi

-- | Path de la parrilla con la sesión en el query string, u omitida.
--
-- Un solo parámetro, a diferencia de 'comparisonPathFor', y esa es exactamente la
-- forma del endpoint: la parrilla no admite filtro por coche —pedir la lista de un
-- coche que ya conoces no tiene sentido—, así que @?session=@ es todo lo que hay.
-- No escapa el query ('pathWith').
driversPathFor :: Maybe Text -> Text
driversPathFor session = pathWith driversPath [("session", session)]

-- | Un path con los parámetros presentes en el query string, en el orden dado, y
-- sin @?@ cuando no hay ninguno. Único sitio del módulo que compone query
-- strings: lo comparten 'comparisonPathFor' y 'driversPathFor'.
--
-- Aquí vive el supuesto de __no escapar__: correcto para los valores de hoy
-- (alfanuméricos, guiones y comas: @latest@, @2026-13-R@, @16,1@), y el día que uno
-- admita espacios o @&@ este es el único punto que hay que cambiar, con
-- @renderQuery@ de @http-types@ (dependencia nueva en @common@, que se mantiene
-- ligero a propósito para compilar bajo GHCJS).
pathWith :: Text -> [(Text, Maybe Text)] -> Text
pathWith path params =
  case catMaybes [fmap ((key <> "=") <>) value | (key, value) <- params] of
    []      -> path
    present -> path <> "?" <> T.intercalate "&" present

-- | Atajo para el endpoint de estadísticas históricas.
historicalPath :: Text
historicalPath = apiPath HistoricalApi

-- | Atajo para el endpoint del estado de la cuenta de F1TV.
f1tvPath :: Text
f1tvPath = apiPath F1TVApi
