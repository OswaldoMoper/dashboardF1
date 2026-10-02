-- | Cliente del microservicio FastF1 — plumbing HTTP de comparación.
--
-- Segundo consumidor del microservicio Python local, después de
-- 'Handler.Telemetry.Manager'. Comparte con él el esquema (@'Http'@, no HTTPS
-- como los tres clientes públicos), el host y el puerto de la 'Config', y también
-- la política de fallo — todo eso vive en 'Handler.FastF1.Manager'.
--
-- Hasta el 2026-08-03 este módulo importaba @telemetryPort@ directamente de
-- 'Handler.Telemetry.Manager' —un @Manager@ de negocio importando de otro, la
-- única vez en el repo— porque lo compartido era una línea y no justificaba un
-- módulo (2026-08-03). Lo que lo justifica ahora no es un
-- tercer consumidor sino que lo compartido dejó de ser un alias: los dos clientes
-- necesitan la misma 'HttpConfig' sin reintentos y el mismo techo de duración, y
-- eso no puede divergir entre áreas.
--
-- Lo que sigue siendo propio de este cliente, y por eso los dos módulos existen:
-- la base de URL (difiere en el último segmento), la forma de la respuesta (un
-- objeto, no una lista) y que los coches viajan en el __query string__.
module Handler.Comparison.Manager
  ( comparisonBase
  , fetchComparison
  ) where

import           Config                    (Config (..))
import           Data.Text                 (Text)
import           Handler.Comparison.Helper (RawComparison)
import           Handler.FastF1.Manager    (fastf1Options, runFastF1)
import           Network.HTTP.Req

-- | Base del endpoint de comparación: @http:\/\/\<host\>\/fastf1\/comparison@.
-- El host es parámetro y no literal porque lo decide la 'Config'.
comparisonBase :: Text -> Url 'Http
comparisonBase host = http host /: "fastf1" /: "comparison"

-- | @GET \/fastf1\/comparison\/{session_key}?drivers=…&samples=…@, decodificado al tipo
-- crudo 'RawComparison'. Sin lógica de negocio: el mapeo a
-- 'Common.Types.LapComparison' es de 'Handler.Comparison.Helper' y la
-- orquestación (cache, degradado) del 'Handler.Comparison.Context'.
--
-- __La diferencia con 'Handler.Telemetry.Manager.fetchTelemetry'__: allí el
-- piloto es un segmento de path; aquí los coches van en el __query string__
-- (@\"drivers\" =: drivers@), porque así lo expone el servicio — la comparación
-- es de varios coches y una lista en el path se confundiría con la jerarquía de
-- recursos. Por eso la 'Option' lleva el puerto __y__ los parámetros.
--
-- @samples@ llega ya ajustado ('Handler.Comparison.Helper.adjustSamples').
--
-- Lanza si el servicio está apagado, si @drivers@ no son de 1 a 5 números de
-- coche o @samples@ está fuera de rango (400 del servicio) o si la respuesta trae
-- otra forma; es el @try@ del 'Context' quien decide qué hacer con eso.
fetchComparison :: Config -> Text -> Text -> Int -> IO RawComparison
fetchComparison cfg sessionKey drivers samples = runFastF1 cfg $ do
  res <-
    req
      GET
      (comparisonBase (cfgTelemetryHost cfg) /: sessionKey)
      NoReqBody
      jsonResponse
      (fastf1Options cfg <> "drivers" =: drivers <> "samples" =: samples)
  pure (responseBody res)
