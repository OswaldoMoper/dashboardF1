-- | Cliente del microservicio FastF1 — plumbing HTTP de telemetría.
--
-- Acceso al microservicio Python local (@telemetry-service@) con el cliente
-- @req@. Es el primer cliente __HTTP y local__ del backend —los otros tres son
-- HTTPS públicos—, así que el 'Url' es @'Http'@ y el puerto viaja en una
-- 'Option': en @req@ el puerto no forma parte del 'Url'. Host y puerto salen de
-- la 'Config' (@TELEMETRY_HOST@\/@TELEMETRY_PORT@) y no de un literal, porque el
-- servicio corre en la máquina de desarrollo hoy y en otra mañana
-- (2026-07-31).
--
-- Lo compartido con el otro consumidor del microservicio vive desde hoy en
-- 'Handler.FastF1.Manager': el puerto (que era @telemetryPort@ de este módulo),
-- el techo de duración de un intento y la 'HttpConfig' sin reintentos. Lo que
-- queda aquí es lo que de verdad distingue a este cliente: su base de URL y que
-- el piloto viaja como __segmento de path__.
--
-- Base de URL propia: NO reusa 'Handler.OpenF1.Manager.fetchList'. Ese GET está
-- cerrado sobre @openf1Base :: Url ''Https@ y @latestSession :: Option ''Https@,
-- y en @req@ el esquema vive en el __tipo__ — pasarle un @Url ''Http@ es un
-- error de tipos, no un detalle de configuración. Además admite __un solo__
-- segmento de path y ninguna 'Option', mientras aquí hacen falta cuatro
-- segmentos y el puerto. Generalizarlo sobre el esquema sería reinventar @req@ y
-- tocar a sus tres consumidores actuales. Mismo criterio que
-- 'Handler.Historical.Manager' con Jolpica.
module Handler.Telemetry.Manager
  ( telemetryBase
  , fetchTelemetry
  ) where

import           Config                   (Config (..))
import           Data.Text                (Text)
import           Handler.FastF1.Manager   (fastf1Config, fastf1Options)
import           Handler.Telemetry.Helper (FastF1Point)
import           Network.HTTP.Req

-- | Base del endpoint de telemetría: @http:\/\/\<host\>\/fastf1\/telemetry@. El
-- host es parámetro y no literal porque lo decide la 'Config'.
telemetryBase :: Text -> Url 'Http
telemetryBase host = http host /: "fastf1" /: "telemetry"

-- | @GET \/fastf1\/telemetry\/{session_key}\/{driver}@, decodificado al tipo
-- crudo 'FastF1Point'. Sin lógica de negocio: el mapeo a
-- 'Common.Types.TelemetryPoint' es de 'Handler.Telemetry.Helper' y la
-- orquestación (cache, degradado) del 'Handler.Telemetry.Context'. Lanza si el
-- servicio está apagado o responde otra forma; es el @try@ del 'Context' quien
-- decide qué hacer con eso.
--
-- La firma de retorno no es opcional: sin ella el tipo que decodifica
-- 'jsonResponse' queda ambiguo.
fetchTelemetry :: Config -> Text -> Text -> IO [FastF1Point]
fetchTelemetry cfg sessionKey driver = runReq fastf1Config $ do
  res <-
    req
      GET
      (telemetryBase (cfgTelemetryHost cfg) /: sessionKey /: driver)
      NoReqBody
      jsonResponse
      (fastf1Options cfg)
  pure (responseBody res)
