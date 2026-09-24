-- | Cliente del feed oficial — capa de efectos.
--
-- @GET \/fastf1\/live@ al microservicio, que es quien mantiene la conversación con
-- el feed y entrega la tabla ya armada junto a la sesión que anuncia. Sin lógica de
-- negocio: la forma del dato es de 'Handler.Feed.Helper', el mapeo al DTO de
-- 'Handler.Live.Helper.feedRows' y 'Handler.Live.Helper.feedSession', y la
-- orquestación de 'Handler.Live.Context'.
--
-- Comparte con los otros dos clientes del microservicio ('Handler.Telemetry.Manager'
-- y 'Handler.Comparison.Manager') la 'HttpConfig' sin reintentos y el puerto de
-- 'Handler.FastF1.Manager'. __Lo que no comparte es el techo de duración__, y ésa es
-- la única razón por la que este módulo no usa 'Handler.FastF1.Manager.fastf1Options'
-- entero: ver 'feedTimeout'.
module Handler.Feed.Manager
  ( feedBase
  , feedTimeoutSeconds
  , feedTimeout
  , fetchFeedLive
  ) where

import           Config                 (Config (..))
import           Data.Text              (Text)
import           Handler.FastF1.Manager (fastf1Port, runFastF1)
import           Handler.Feed.Helper    (FeedLive)
import           Network.HTTP.Req

-- | Base del endpoint del directo: @http:\/\/\<host\>\/fastf1\/live@. El host lo
-- decide la 'Config', como en los otros dos clientes.
feedBase :: Text -> Url 'Http
feedBase host = http host /: "fastf1" /: "live"

-- | Techo de duración de la petición al feed, en segundos.
--
-- __Es constante y propia, y no el default de 5 s que usan los otros dos clientes
-- del microservicio.__ Una foto del feed cuesta ~17 s medidos (16,87, 17,00 y 16,99
-- s en tres pasadas sin sesión en marcha, 2026-09-12): el coste no está en la red
-- sino en la conversación con el feed —la negociación son 0,2-0,5 s—, así que no es
-- una lentitud que vaya a desaparecer. Con 5 s __toda__ respuesta buena se leería
-- como fallo.
--
-- __Lo que el llamador tiene que saber:__ pasar de este techo no es «tarda mucho»,
-- es un fallo del feed, y un fallo del feed sirve desde la cache __sin__ intentar
-- OpenF1 (2026-09-12). O sea que este número decide cuánto se espera antes de
-- enseñar dato viejo, no cuánto se espera antes de reintentar.
--
-- __El margen sobre los 17 s no es de adorno:__ cada cliente abierto sostiene su
-- propia conexión durante toda la foto, así que un navegador refrescando y un
-- @curl@ a la vez se solapan dentro del microservicio. Con 20 s ya se vio una foto
-- pasarse (2026-09-12, 22:56).
--
-- El microservicio puede tardar todavía más contestando bien: su propio
-- @_live_snapshot@ aplica su plazo de 15 s __tres__ veces —negociación, aceptación
-- de la conexión y llegada del estado—, o sea hasta ~45 s. Descartar ese tramo es
-- deliberado: esperar 45 s con un refresco de 10 s congela cuatro ciclos.
feedTimeoutSeconds :: Int
feedTimeoutSeconds = 30

-- | 'feedTimeoutSeconds' como 'Option' (@req@ lo toma en microsegundos).
feedTimeout :: Option 'Http
feedTimeout = responseTimeout (feedTimeoutSeconds * 1000000)

-- | @GET \/fastf1\/live@, decodificado a 'FeedLive' — la tabla y su sesión.
--
-- __La tabla vacía es la respuesta normal cuando no hay sesión en marcha__, y no un
-- error: el microservicio reserva el @503@ para el feed caído. Los dos casos llegan
-- aquí distintos —filas vacías frente a excepción— porque la escalera los trata al
-- revés, y fundirlos cerraría el camino a OpenF1 fuera de sesión.
--
-- Lanza si el servicio está apagado, si vence el techo o si responde otra forma; es
-- el @try@ del 'Handler.Live.Context' quien decide qué hacer con eso.
--
-- La firma de retorno no es opcional: sin ella el tipo que decodifica
-- 'jsonResponse' queda ambiguo.
fetchFeedLive :: Config -> IO FeedLive
fetchFeedLive cfg = runFastF1 cfg $ do
  res <-
    req
      GET
      (feedBase (cfgTelemetryHost cfg))
      NoReqBody
      jsonResponse
      (fastf1Port (cfgTelemetryPort cfg) <> feedTimeout)
  pure (responseBody res)
