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
dummy :: [TelemetryPoint]
dummy =
  [ TelemetryPoint 0.0 0 312.5 1.0 0.0 8 11800
  , TelemetryPoint 0.5 42 298.1 0.0 0.6 7 10500
  , TelemetryPoint 1.0 78 265.3 0.0 1.0 5 9200
  , TelemetryPoint 1.5 110 289.7 0.8 0.0 6 10100
  , TelemetryPoint 2.0 156 320.4 1.0 0.0 8 12000
  ]
