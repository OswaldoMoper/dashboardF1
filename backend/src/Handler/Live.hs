-- | Área Live timing — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/live@ y delega en 'Handler.Live.Context', que orquesta las dos
-- fuentes (vía 'Handler.Feed.Manager' y 'Handler.Live.Manager'), el mapeo puro
-- ('Handler.Live.Helper') y la cache STM del 'Env'.
--
-- __Es el único handler que responde con cabeceras propias:__ de dónde salió el
-- dato ('Common.Origin'), que son dos preguntas —qué peldaño de la escalera y qué
-- fuente— y que el @Context@ conoce en cada una. El cuerpo JSON es el mismo que
-- antes de existir ellas, así que ningún DTO ni ningún widget cambia de forma.
--
-- __Los nombres de las cabeceras viven aquí, a nivel de tipo, y no en 'Server'__,
-- porque 'Server' importa este módulo. Son los mismos que 'Common.Origin' guarda
-- como 'Text', y la suite comprueba que no diverjan: si lo hicieran, el widget no
-- reconocería la cabecera y callaría sin error. Cuando otra área emita
-- procedencia, se mudan a un módulo de la raíz.
module Handler.Live where

import           App                    (Env)
import           Common.Origin          (originLabel, sourceLabel)
import           Common.Types           (LiveTimingRow)
import           Control.Monad.IO.Class (liftIO)
import           Data.Text              (Text)
import qualified Data.Text              as T
import           Data.Time.Clock        (UTCTime)
import           Data.Time.Format       (defaultTimeLocale, formatTime)
import           Handler.Live.Context   (LiveResult (..))
import qualified Handler.Live.Context   as Context
import           Servant                (Handler, Header, Headers, addHeader,
                                         noHeader)

-- | Nombre de la cabecera de procedencia; espejo de 'Common.Origin.originHeader'.
type OriginHeaderName = "X-Data-Origin"

-- | Nombre de la cabecera del instante; espejo de 'Common.Origin.fetchedAtHeader'.
type FetchedAtHeaderName = "X-Data-Fetched-At"

-- | Nombre de la cabecera de la fuente; espejo de 'Common.Origin.sourceHeader'.
type SourceHeaderName = "X-Data-Source"

-- | La respuesta de @\/api\/live@: las filas de siempre más las tres cabeceras.
type LiveResponse =
  Headers
    '[ Header OriginHeaderName Text
     , Header FetchedAtHeaderName Text
     , Header SourceHeaderName Text
     ]
    [LiveTimingRow]

liveHandler :: Env -> Handler LiveResponse
liveHandler env = withOrigin <$> liftIO (Context.getLiveTiming env)

-- | Pone la procedencia en cabeceras.
--
-- @X-Data-Origin@ va siempre; las otras dos __faltan__ cuando el @Context@ no las
-- tiene: el instante solo lo hay al servir desde la cache, y la fuente solo si el
-- dato salió de alguna —el respaldo estático no—. Es pura para que la suite pueda
-- comprobar qué cabeceras salen en cada peldaño sin levantar red.
withOrigin :: LiveResult -> LiveResponse
withOrigin result =
  addHeader
    (originLabel (lrOrigin result))
    (withFetchedAt (withSource (lrRows result)))
  where
    withSource
      :: [LiveTimingRow]
      -> Headers '[Header SourceHeaderName Text] [LiveTimingRow]
    withSource = maybe noHeader (addHeader . sourceLabel) (lrSource result)

    withFetchedAt
      :: Headers '[Header SourceHeaderName Text] [LiveTimingRow]
      -> Headers
           '[Header FetchedAtHeaderName Text, Header SourceHeaderName Text]
           [LiveTimingRow]
    withFetchedAt = maybe noHeader (addHeader . fetchedAtText) (lrFetchedAt result)

-- | El instante en ISO 8601 y UTC, __con segundos enteros__.
--
-- @%S@ no lleva fracción, y es a propósito: el sello se lee como una hora
-- («14:03»), y los microsegundos de 'getCurrentTime' solo serían ruido en la
-- cabecera.
fetchedAtText :: UTCTime -> Text
fetchedAtText = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
