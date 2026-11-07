-- | Área comparación de vueltas — lógica pura.
--
-- Modela la respuesta del microservicio FastF1 (@telemetry-service@,
-- @GET \/fastf1\/comparison\/{session_key}?drivers=16,1&samples=0@): __un objeto__
-- con la lista de coches en el orden pedido, la referencia primero. El tipo crudo
-- existe __aunque la forma coincida hoy__: no atar el DTO de @common@ al contrato
-- de un servicio que es nuestro y va a moverse. Sin efectos: determinista y testeable.
--
-- La identidad de cada coche (@ceCar@, @ceDriver@) es obligatoria (@.:@); el
-- resto va con @.:?@ y su valor vacío, porque __un coche sin vuelta es una
-- respuesta válida__: llega sin sectores, y decidir si eso tumba la comparación
-- es del 'Handler.Comparison.Context' ('comparable'), no del parseo.
module Handler.Comparison.Helper
  ( -- * Envoltura cruda del microservicio FastF1
    RawComparison (..)
  , RawEntry (..)
  , RawGap (..)
    -- * Transformación pura
  , assembleComparison
  , comparable
  , withNotice
    -- * Parámetros de la petición
  , defaultSession
  , defaultDrivers
  , adjustSamples
  , resolveParams
  ) where

import           Common.Types          (ComparisonEntry (..),
                                        LapComparison (..), TelemetryGap (..),
                                        TracePoint)
import           Data.Aeson            (FromJSON (..), withObject, (.!=), (.:),
                                        (.:?))
import           Data.Maybe            (isJust)
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Handler.FastF1.Helper (queryParam, sessionParam)
import           Outcome               (Rejection)

-- | La comparación tal como la emite el microservicio.
data RawComparison = RawComparison
  { rcEntries   :: [RawEntry]
  , rcSamples   :: Int
  , rcTelemetry :: Maybe RawGap
  }
  deriving (Eq, Show)

instance FromJSON RawComparison where
  parseJSON = withObject "RawComparison" $ \o ->
    RawComparison
      <$> o .:  "lcEntries"
      <*> o .:? "lcSamples" .!= 0
      <*> o .:? "lcTelemetry"

-- | Lo que falta de la telemetría, tal como lo emite el microservicio con trazas y la
-- telemetría de la sesión incompleta.
data RawGap = RawGap
  { rgCoverage :: Double
  , rgRetryAt  :: Text
  }
  deriving (Eq, Show)

instance FromJSON RawGap where
  parseJSON = withObject "RawGap" $ \o ->
    RawGap <$> o .: "coverage" <*> o .: "retryAt"

-- | Un coche tal como lo emite el microservicio. Los tiempos llegan ya
-- formateados (@\"1:29.345\"@) porque formatear es trabajo del servicio Python
-- (2026-07-31).
data RawEntry = RawEntry
  { reCar       :: Text
  , reDriver    :: Text
  , reLap       :: Text
  , rePart      :: Maybe Text
  , reSectors   :: Maybe (Double, Double, Double)
  , reFrontiers :: Maybe (Double, Double)
  , reTrace     :: [TracePoint]
  }
  deriving (Eq, Show)

instance FromJSON RawEntry where
  parseJSON = withObject "RawEntry" $ \o ->
    RawEntry
      <$> o .:  "ceCar"
      <*> o .:  "ceDriver"
      <*> o .:? "ceLap" .!= ""
      <*> o .:? "cePart"
      <*> o .:? "ceSectors"
      <*> o .:? "ceFrontiers"
      <*> o .:? "ceTrace" .!= []

-- | Traduce la comparación cruda a 'LapComparison' __preservando el orden de los
-- coches__ —el primero es la referencia— y de cada traza. Sale sin aviso
-- ('lcNotice' vacío): el aviso depende de lo pedido, no de lo servido
-- ('withNotice').
assembleComparison :: RawComparison -> LapComparison
assembleComparison raw =
  MkLapComparison
    { lcEntries   = map entry (rcEntries raw)
    , lcSamples   = rcSamples raw
    , lcNotice    = ""
    , lcTelemetry = gap <$> rcTelemetry raw
    }
  where
    gap g = MkTelemetryGap {tgCoverage = rgCoverage g, tgRetryAt = rgRetryAt g}
    entry e =
      MkComparisonEntry
        { ceCar       = reCar e
        , ceDriver    = reDriver e
        , ceLap       = reLap e
        , cePart      = rePart e
        , ceSectors   = reSectors e
        , ceFrontiers = reFrontiers e
        , ceTrace     = reTrace e
        }

-- | Si la comparación se puede servir: algún coche tiene sus tres sectores. Con
-- ninguno no hay Δ que calcular, contra la referencia ni contra el más rápido.
comparable :: LapComparison -> Bool
comparable = any (isJust . ceSectors) . lcEntries

-- | La comparación con el aviso de lo que se ajustó de la petición.
withNotice :: Text -> LapComparison -> LapComparison
withNotice notice c = c { lcNotice = notice }

-- | Sesión que se consulta cuando @\/api\/comparison@ no recibe @?session=@.
-- @latest@ es la última carrera disputada, resuelta por el microservicio.
defaultSession :: Text
defaultSession = "latest"

-- | Coches que se comparan cuando @\/api\/comparison@ no recibe @?drivers=@:
-- __números de coche__, no acrónimos, porque es lo que acepta el microservicio
-- (2026-08-01), y __la referencia primero__: @16@ (LEC) contra @1@ (NOR). Son los
-- dos de 'Handler.Comparison.Context.dummy', en el mismo orden, para que la
-- respuesta sin parámetros y el respaldo hablen de los mismos coches.
defaultDrivers :: Text
defaultDrivers = "16,1"

-- | Las muestras por coche que se piden al microservicio, y el aviso si no son
-- las pedidas: 0 (sin trazas) o de 60 a 250 de 5 en 5. Un negativo pasa a 0, de 1
-- a 59 a 60, por encima de 250 a 250, y lo demás al múltiplo de 5 más cercano.
-- El aviso es vacío cuando no se ajusta nada.
adjustSamples :: Int -> (Int, Text)
adjustSamples n = (used, notice)
  where
    used
      | n <= 0    = 0
      | n < 60    = 60
      | n > 250   = 250
      | r <= 2    = n - r
      | otherwise = n + 5 - r
    r = n `mod` 5
    notice
      | used == n = ""
      | otherwise =
          "samples=" <> tshow n <> " fuera de 60–250 de 5 en 5: se usó " <> tshow used
    tshow = T.pack . show

-- | Aplica los defaults a los @QueryParam@ opcionales de 'Server.Api' y devuelve
-- la __clave de cache__ —sesión, coches y muestras ya ajustadas, resuelta una sola
-- vez para que @?session=latest@ y la ausencia del parámetro no ocupen dos
-- entradas— junto con el aviso de 'adjustSamples'. Sin @?samples=@, 0 y sin aviso.
--
-- Un parámetro de texto escrito pero vacío se rechaza
-- ('Handler.FastF1.Helper.queryParam').
resolveParams
  :: Maybe Text -> Maybe Text -> Maybe Int -> Either Rejection ((Text, Text, Int), Text)
resolveParams session drivers samples = do
  s <- sessionParam defaultSession session
  d <- queryParam "drivers" "comparar los coches por defecto" defaultDrivers drivers
  let (n, notice) = maybe (0, "") adjustSamples samples
  pure ((s, d, n), notice)
