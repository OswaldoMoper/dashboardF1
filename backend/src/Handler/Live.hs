-- | Área Live timing — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/live@ y delega en 'Handler.Live.Context', que orquesta el
-- fetch real a OpenF1 (vía 'Handler.Live.Manager'), el mapeo puro
-- ('Handler.Live.Helper') y la cache STM del 'Env'.
--
-- __Es el único handler que responde con cabeceras propias:__ la procedencia del
-- dato ('Common.Origin'), que el @Context@ conoce en cada peldaño de la escalera.
-- El cuerpo JSON es el mismo que antes de existir ellas, así que ningún DTO ni
-- ningún widget cambia de forma.
--
-- __Los nombres de las cabeceras viven aquí, a nivel de tipo, y no en 'Server'__,
-- porque 'Server' importa este módulo. Son los mismos que 'Common.Origin' guarda
-- como 'Text', y la suite comprueba que no diverjan: si lo hicieran, el widget no
-- reconocería la cabecera y callaría sin error. Cuando otra área emita
-- procedencia, se mudan a un módulo de la raíz.
module Handler.Live where

import           App                    (Env)
import           Common.Origin          (Origin, originLabel)
import           Common.Types           (LiveTimingRow)
import           Control.Monad.IO.Class (liftIO)
import           Data.Text              (Text)
import qualified Data.Text              as T
import           Data.Time.Clock        (UTCTime)
import           Data.Time.Format       (defaultTimeLocale, formatTime)
import qualified Handler.Live.Context   as Context
import           Servant                (Handler, Header, Headers, addHeader,
                                         noHeader)

-- | Nombre de la cabecera de procedencia; espejo de 'Common.Origin.originHeader'.
type OriginHeaderName = "X-Data-Origin"

-- | Nombre de la cabecera del instante; espejo de 'Common.Origin.fetchedAtHeader'.
type FetchedAtHeaderName = "X-Data-Fetched-At"

-- | La respuesta de @\/api\/live@: las filas de siempre más las dos cabeceras.
type LiveResponse =
  Headers
    '[Header OriginHeaderName Text, Header FetchedAtHeaderName Text]
    [LiveTimingRow]

liveHandler :: Env -> Handler LiveResponse
liveHandler env = withOrigin <$> liftIO (Context.getLiveTiming env)

-- | Pone la procedencia en cabeceras.
--
-- @X-Data-Origin@ va siempre; @X-Data-Fetched-At@ solo cuando hay instante, que
-- el @Context@ da únicamente al servir desde la cache. Es pura para que la suite
-- pueda comprobar qué cabeceras salen en cada peldaño sin levantar red.
withOrigin :: (Origin, Maybe UTCTime, [LiveTimingRow]) -> LiveResponse
withOrigin (origin, fetchedAt, rows) =
  addHeader (originLabel origin) (withFetchedAt rows)
  where
    withFetchedAt
      :: [LiveTimingRow] -> Headers '[Header FetchedAtHeaderName Text] [LiveTimingRow]
    withFetchedAt = maybe noHeader (addHeader . fetchedAtText) fetchedAt

-- | El instante en ISO 8601 y UTC, __con segundos enteros__.
--
-- @%S@ no lleva fracción, y es a propósito: el sello se lee como una hora
-- («14:03»), y los microsegundos de 'getCurrentTime' solo serían ruido en la
-- cabecera.
fetchedAtText :: UTCTime -> Text
fetchedAtText = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
