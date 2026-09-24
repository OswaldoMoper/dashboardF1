-- | La procedencia de una respuesta, en cabeceras (INFRA): de qué peldaño de la
-- escalera y de qué fuente salió el dato ('Common.Origin'), y cuándo se trajo lo
-- guardado. El cuerpo JSON no cambia.
--
-- __Los nombres de las cabeceras viven dos veces__ —'Symbol' aquí, para el tipo de
-- Servant, y 'Text' en 'Common.Origin'— y la suite comprueba que no diverjan: si lo
-- hicieran, el widget no reconocería la cabecera y callaría sin error.
module Provenance
  ( OriginHeaderName
  , FetchedAtHeaderName
  , SourceHeaderName
  , WithProvenance
  , withProvenance
  , fetchedAtText
  , isoInstant
  ) where

import           Common.Origin    (Origin, Source, originLabel, sourceLabel)
import           Data.Text        (Text)
import qualified Data.Text        as T
import           Data.Time.Clock  (UTCTime)
import           Data.Time.Format (defaultTimeLocale, formatTime)
import           Servant          (Header, Headers, addHeader, noHeader)

-- | Nombre de la cabecera de procedencia; espejo de 'Common.Origin.originHeader'.
type OriginHeaderName = "X-Data-Origin"

-- | Nombre de la cabecera del instante; espejo de 'Common.Origin.fetchedAtHeader'.
type FetchedAtHeaderName = "X-Data-Fetched-At"

-- | Nombre de la cabecera de la fuente; espejo de 'Common.Origin.sourceHeader'.
type SourceHeaderName = "X-Data-Source"

-- | Un cuerpo con las tres cabeceras de procedencia.
type WithProvenance a =
  Headers
    '[ Header OriginHeaderName Text
     , Header FetchedAtHeaderName Text
     , Header SourceHeaderName Text
     ]
    a

-- | Pone la procedencia en cabeceras.
--
-- @X-Data-Origin@ va siempre; las otras dos __faltan__ cuando quien llama no las
-- tiene: el instante solo lo hay al servir de lo guardado —porque aún vale o porque
-- la fuente no contestó—, y la fuente solo si el dato salió de alguna —el respaldo
-- estático no—. Es pura para que la suite pueda comprobar qué cabeceras salen en
-- cada peldaño sin levantar red.
withProvenance :: Origin -> Maybe Source -> Maybe UTCTime -> a -> WithProvenance a
withProvenance origin source fetchedAt body =
  addHeader (originLabel origin) (withFetchedAt (withSource body))
  where
    withSource :: a -> Headers '[Header SourceHeaderName Text] a
    withSource = maybe noHeader (addHeader . sourceLabel) source

    withFetchedAt
      :: Headers '[Header SourceHeaderName Text] a
      -> Headers '[Header FetchedAtHeaderName Text, Header SourceHeaderName Text] a
    withFetchedAt = maybe noHeader (addHeader . fetchedAtText) fetchedAt

-- | El instante en ISO 8601 y UTC, __con segundos enteros__.
--
-- Los segundos van sin fracción a propósito: el sello se lee como una hora
-- («14:03»), y los microsegundos de 'getCurrentTime' solo serían ruido en la
-- cabecera.
--
-- La forma la pone 'isoInstant', que es la misma que el filtro del calendario de
-- OpenF1 manda en la URL. El nombre se queda porque dice para qué es este uso, que
-- la función general no puede decir.
fetchedAtText :: UTCTime -> Text
fetchedAtText = isoInstant

-- | Un instante en la forma ISO 8601 que este proyecto emite, con segundos enteros.
--
-- La usan el filtro del calendario de OpenF1 y la cabecera @X-Data-Fetched-At@. Son
-- dos usos distintos de la __misma__ forma, y por eso vive aquí en vez de dos veces.
isoInstant :: UTCTime -> Text
isoInstant = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
