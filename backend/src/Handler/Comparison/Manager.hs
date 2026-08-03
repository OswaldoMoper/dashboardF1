-- | Cliente del microservicio FastF1 — plumbing HTTP de comparación.
--
-- Segundo consumidor del microservicio Python local, después de
-- 'Handler.Telemetry.Manager'. Comparte con él el esquema (@'Http'@, no HTTPS
-- como los tres clientes públicos), el host y el puerto de la 'Config', y por eso
-- __reusa 'Handler.Telemetry.Manager.telemetryPort'__ en vez de declarar su
-- propio alias de 'port'.
--
-- Que un @Manager@ de negocio importe de otro es la excepción y conviene decir
-- por qué no se extrajo un @Handler.FastF1.Manager@ compartido, como sí se hizo
-- con OpenF1 en su segundo consumidor (2026-07-23): allí lo
-- compartido era un GET completo más la base de URL y la 'Option' de sesión; aquí
-- es __una línea__ (@telemetryPort = port@). Las dos bases de URL difieren en el
-- último segmento y los dos GET difieren en la forma —una lista contra un objeto,
-- el @drivers@ en query contra el @driver@ en path—, así que un módulo común
-- tendría exactamente un valor dentro. Se extrae con el tercer consumidor
-- (2026-08-03).
module Handler.Comparison.Manager
  ( comparisonBase
  , fetchComparison
  ) where

import           Config                    (Config (..))
import           Data.Text                 (Text)
import           Handler.Comparison.Helper (RawComparison)
import           Handler.Telemetry.Manager (telemetryPort)
import           Network.HTTP.Req

-- | Base del endpoint de comparación: @http:\/\/\<host\>\/fastf1\/comparison@.
-- El host es parámetro y no literal porque lo decide la 'Config'.
comparisonBase :: Text -> Url 'Http
comparisonBase host = http host /: "fastf1" /: "comparison"

-- | @GET \/fastf1\/comparison\/{session_key}?drivers=…@, decodificado al tipo
-- crudo 'RawComparison'. Sin lógica de negocio: el mapeo a
-- 'Common.Types.LapComparison' es de 'Handler.Comparison.Helper' y la
-- orquestación (cache, degradado) del 'Handler.Comparison.Context'.
--
-- __La diferencia con 'Handler.Telemetry.Manager.fetchTelemetry'__: allí el
-- piloto es un segmento de path; aquí los coches van en el __query string__
-- (@\"drivers\" =: drivers@), porque así lo expone el servicio — la comparación
-- es de dos coches y una lista en el path se confundiría con la jerarquía de
-- recursos. Por eso la 'Option' lleva el puerto __y__ el parámetro.
--
-- Lanza si el servicio está apagado, si @drivers@ no son exactamente dos números
-- de coche (400 del servicio) o si la respuesta trae otra forma; es el @try@ del
-- 'Context' quien decide qué hacer con eso.
fetchComparison :: Config -> Text -> Text -> IO RawComparison
fetchComparison cfg sessionKey drivers = runReq defaultHttpConfig $ do
  res <-
    req
      GET
      (comparisonBase (cfgTelemetryHost cfg) /: sessionKey)
      NoReqBody
      jsonResponse
      (telemetryPort (cfgTelemetryPort cfg) <> "drivers" =: drivers)
  pure (responseBody res)
