-- | Cliente del microservicio FastF1 — plumbing HTTP de la parrilla.
--
-- __Tercer consumidor__ del microservicio Python local, después de
-- 'Handler.Telemetry.Manager' y 'Handler.Comparison.Manager'. Es el que el
-- 2026-08-03 fijaba como condición para extraer lo compartido a
-- 'Handler.FastF1.Manager' — que el 2026-08-04 se adelantó a cumplir por otra
-- razón (la política de reintentos), así que ese módulo simplemente tiene un
-- consumidor más y no hay nada que refactorizar.
--
-- Lo propio de este cliente, y por lo que existe: la base de URL y que __no
-- lleva query string__. La sesión va en el path, como en telemetría; a
-- diferencia de comparación, no hay parámetros que añadir a la 'Option'.
module Handler.Drivers.Manager
  ( driversBase
  , fetchDrivers
  ) where

import           Config                 (Config (..))
import           Data.Text              (Text)
import           Handler.Drivers.Helper (RawDriver)
import           Handler.FastF1.Manager (fastf1Config, fastf1Options)
import           Network.HTTP.Req

-- | Base del endpoint de parrilla: @http:\/\/\<host\>\/fastf1\/drivers@. El host
-- es parámetro y no literal porque lo decide la 'Config'.
driversBase :: Text -> Url 'Http
driversBase host = http host /: "fastf1" /: "drivers"

-- | @GET \/fastf1\/drivers\/{session_key}@, decodificado a la lista de
-- 'RawDriver'. Sin lógica de negocio: el mapeo a 'Common.Types.DriverEntry' es de
-- 'Handler.Drivers.Helper' y la orquestación (cache, degradado) del
-- 'Handler.Drivers.Context'.
--
-- Lanza si el servicio está apagado, si la sesión no resuelve (404) o si la
-- respuesta trae otra forma; es el @try@ del 'Context' quien decide qué hacer con
-- eso. Lo que __no__ lanza es la sesión sin parrilla: el servicio devuelve @[]@ a
-- propósito, y esa lista vacía es justo lo que el 'Context' trata como fallo.
fetchDrivers :: Config -> Text -> IO [RawDriver]
fetchDrivers cfg sessionKey = runReq fastf1Config $ do
  res <-
    req
      GET
      (driversBase (cfgTelemetryHost cfg) /: sessionKey)
      NoReqBody
      jsonResponse
      (fastf1Options cfg)
  pure (responseBody res)
