-- | Área Live timing — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/live@ y delega en 'Handler.Live.Context', que orquesta las dos
-- fuentes (vía 'Handler.Feed.Manager' y 'Handler.Live.Manager'), el mapeo puro
-- ('Handler.Live.Helper') y la cache STM del 'Env'.
--
-- __Es el único handler que responde con cabeceras propias:__ de dónde salió el
-- dato ('Common.Origin'), que son dos preguntas —qué peldaño de la escalera y qué
-- fuente— y que el @Context@ conoce en cada una.
--
-- __Las cabeceras siguen siendo metadato y el cuerpo sigue siendo contenido__, y
-- por eso el dato de sesión no entró en ellas: viaja dentro de
-- 'Common.Types.LiveTable', envolviendo las filas (2026-09-13).
--
-- __Los nombres de las cabeceras viven aquí, a nivel de tipo, y no en 'Server'__,
-- porque 'Server' importa este módulo. Son los mismos que 'Common.Origin' guarda
-- como 'Text', y la suite comprueba que no diverjan: si lo hicieran, el widget no
-- reconocería la cabecera y callaría sin error. Cuando otra área emita
-- procedencia, se mudan a un módulo de la raíz.
module Handler.Live where

import           App                    (Env)
import           Common.Origin          (originLabel, sourceLabel)
import           Common.Types           (LiveTable)
import           Control.Monad.IO.Class (liftIO)
import           Data.Text              (Text)
import           Data.Time.Clock        (UTCTime)
import           Handler.Live.Context   (LiveResult (..))
import qualified Handler.Live.Context   as Context
import           Handler.Live.Helper    (isoInstant)
import           Servant                (Handler, Header, Headers, addHeader,
                                         noHeader)

-- | Nombre de la cabecera de procedencia; espejo de 'Common.Origin.originHeader'.
type OriginHeaderName = "X-Data-Origin"

-- | Nombre de la cabecera del instante; espejo de 'Common.Origin.fetchedAtHeader'.
type FetchedAtHeaderName = "X-Data-Fetched-At"

-- | Nombre de la cabecera de la fuente; espejo de 'Common.Origin.sourceHeader'.
type SourceHeaderName = "X-Data-Source"

-- | La respuesta de @\/api\/live@: la tabla con su sesión, más las tres cabeceras.
type LiveResponse =
  Headers
    '[ Header OriginHeaderName Text
     , Header FetchedAtHeaderName Text
     , Header SourceHeaderName Text
     ]
    LiveTable

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
    (withFetchedAt (withSource (lrTable result)))
  where
    withSource
      :: LiveTable
      -> Headers '[Header SourceHeaderName Text] LiveTable
    withSource = maybe noHeader (addHeader . sourceLabel) (lrSource result)

    withFetchedAt
      :: Headers '[Header SourceHeaderName Text] LiveTable
      -> Headers
           '[Header FetchedAtHeaderName Text, Header SourceHeaderName Text]
           LiveTable
    withFetchedAt = maybe noHeader (addHeader . fetchedAtText) (lrFetchedAt result)

-- | El instante en ISO 8601 y UTC, __con segundos enteros__.
--
-- Los segundos van sin fracción a propósito: el sello se lee como una hora
-- («14:03»), y los microsegundos de 'getCurrentTime' solo serían ruido en la
-- cabecera.
--
-- La forma la pone 'Handler.Live.Helper.isoInstant', que es la misma que el filtro
-- del calendario de OpenF1 manda en la URL. El nombre se queda porque dice para qué
-- es este uso, que la función general no puede decir.
fetchedAtText :: UTCTime -> Text
fetchedAtText = isoInstant
