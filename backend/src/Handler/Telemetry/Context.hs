-- | Área telemetría — orquestación del caso de uso.
--
-- Espejo de 'Handler.Live.Context' \/ 'Handler.TyreStrategy.Context' \/
-- 'Handler.Historical.Context': aquí viven el @try@ sobre el fetch al
-- microservicio FastF1 ('Handler.Telemetry.Manager'), el mapeo puro
-- ('Handler.Telemetry.Helper') y el degradado @cache -> dummy@ con
-- 'App.envTelemetryCache'.
--
-- __Scaffold deliberado__: hoy devuelve solo el dummy, así que @\/api\/telemetry@
-- responde exactamente lo mismo que antes de existir este módulo. El fetch real
-- entra en su propio commit porque es el que cambia comportamiento observable y
-- hay que validarlo con el servicio encendido __y apagado__ — el camino
-- degradado importa aquí más que en las otras tres áreas, porque el servicio es
-- nuestro y estará apagado la mayor parte del tiempo (precedente: sesiones 2, 3
-- y 4 de Fase 3).
module Handler.Telemetry.Context where

import           App          (Env)
import           Common.Types (TelemetryPoint (..))
import           Data.Text    (Text)

-- | Sesión que se consulta. @\/api\/telemetry@ no recibe parámetros, así que la
-- elección es de este módulo. Los query params (sesión y piloto) son __deuda
-- explícita__: meterlos es un cambio cross —@Server.Api@ + @Common.Route@ +
-- @Widgets.Telemetry@— y merece su propia sesión.
defaultSession :: Text
defaultSession = "latest"

-- | Pilotos que se consultan. @all@ trae la vuelta rápida de __todos__ los de la
-- sesión en una sola llamada HTTP; pedirlos uno a uno necesitaría @async@, que
-- no es dependencia del backend, y multiplicaría los puntos de fallo del @try@
-- (2026-07-31).
defaultDrivers :: Text
defaultDrivers = "all"

-- | Devuelve la telemetría de la vuelta rápida de cada piloto. Ignora el 'Env'
-- mientras no haya fetch real; la firma ya es la definitiva ('IO' + 'Env') para
-- que el commit siguiente toque solo el cuerpo y no al llamador.
getTelemetry :: Env -> IO [TelemetryPoint]
getTelemetry _env = pure dummy

-- | Telemetría dummy (respaldo cuando el microservicio nunca dio datos). Misma
-- forma que emite 'Handler.Telemetry.Helper.assemblePoints' —lista plana con los
-- puntos de cada piloto contiguos y en orden de vuelta— y con __dos pilotos__,
-- para que el widget sea ejercitable sin el servicio levantado.
dummy :: [TelemetryPoint]
dummy =
  [ TelemetryPoint "VER" 0.0 0 312.5 1.0 0.0 8 11800
  , TelemetryPoint "VER" 0.5 42 298.1 0.0 0.6 7 10500
  , TelemetryPoint "VER" 1.0 78 265.3 0.0 1.0 5 9200
  , TelemetryPoint "NOR" 0.0 0 309.8 1.0 0.0 8 11650
  , TelemetryPoint "NOR" 0.5 40 289.7 0.0 0.8 6 10100
  ]
