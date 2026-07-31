-- | Área telemetría — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/telemetry@. Fase 1: dummy estático (ignora el 'Env'); en
-- Fase 4 lo alimenta un @Handler.Telemetry.Manager@ que consulta el
-- microservicio FastF1, orquestado por un @Handler.Telemetry.Context@.
module Handler.Telemetry where

import           App          (Env)
import           Common.Types (TelemetryPoint (..))
import           Servant      (Handler)

telemetryHandler :: Env -> Handler [TelemetryPoint]
telemetryHandler _env = pure dummy

-- | Muestreo dummy a lo largo de una vuelta (placeholder de FastF1).
--
-- Lleva __dos pilotos__ a propósito: la respuesta real concatena la vuelta
-- rápida de cada coche en una sola lista etiquetada, así que un dummy de un solo
-- piloto no ejercitaría la forma que el widget tiene que pintar.
dummy :: [TelemetryPoint]
dummy =
  [ TelemetryPoint "VER" 0.0 0 312.5 1.0 0.0 8 11800
  , TelemetryPoint "VER" 0.5 42 298.1 0.0 0.6 7 10500
  , TelemetryPoint "VER" 1.0 78 265.3 0.0 1.0 5 9200
  , TelemetryPoint "NOR" 0.0 0 309.8 1.0 0.0 8 11650
  , TelemetryPoint "NOR" 0.5 40 289.7 0.0 0.8 6 10100
  ]
