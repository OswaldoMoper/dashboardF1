-- | Área telemetría — orquestación del caso de uso.
--
-- Espejo de 'Handler.Live.Context' \/ 'Handler.TyreStrategy.Context' \/
-- 'Handler.Historical.Context': aquí viven el @try@ sobre el fetch al
-- microservicio FastF1 ('Handler.Telemetry.Manager'), el mapeo puro
-- ('Handler.Telemetry.Helper') y el degradado @cache -> dummy@ con
-- 'App.envTelemetryCache'.
--
-- El camino degradado importa aquí __más__ que en las otras tres áreas: los
-- otros clientes hablan con servicios públicos que están siempre en pie,
-- mientras que este es nuestro y estará apagado la mayor parte del tiempo. Que
-- @\/api\/telemetry@ siga respondiendo con el servicio caído no es un extra, es
-- el caso normal.
module Handler.Telemetry.Context where

import           App                       (Env (..))
import           Common.Types              (TelemetryPoint (..))
import           Config                    (Config)
import           Control.Concurrent.STM    (atomically, readTVarIO, writeTVar)
import           Control.Exception         (SomeException, try)
import           Data.Maybe                (fromMaybe)
import           Data.Text                 (Text)
import           Handler.Telemetry.Helper  (assemblePoints)
import qualified Handler.Telemetry.Manager as Manager

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

-- | Devuelve la telemetría de la vuelta rápida de cada piloto: intenta el fetch
-- real; si funciona, refresca la cache y devuelve; ante fallo o lista vacía sirve
-- la última respuesta buena; sin ninguna, el dummy (espejo exacto de
-- 'Handler.Historical.Context.getHistorical').
--
-- La lista vacía cuenta como fallo, no como respuesta: el microservicio devuelve
-- @[]@ cuando la sesión no publicó telemetría, y servir una tabla vacía sería
-- peor que servir la vuelta anterior.
getTelemetry :: Env -> IO [TelemetryPoint]
getTelemetry env = do
  result <- try (fetchPoints (envConfig env)) :: IO (Either SomeException [TelemetryPoint])
  case result of
    Right points | not (null points) -> do
      atomically (writeTVar (envTelemetryCache env) (Just points))
      pure points
    _ -> do
      cached <- readTVarIO (envTelemetryCache env)
      pure (fromMaybe dummy cached)

-- | El GET al microservicio y el mapeo puro, encadenados. Vive fuera del @try@
-- del llamador solo por legibilidad: cualquier excepción que lance —servicio
-- apagado, timeout, JSON con otra forma— la atrapa 'getTelemetry'.
fetchPoints :: Config -> IO [TelemetryPoint]
fetchPoints cfg =
  assemblePoints <$> Manager.fetchTelemetry cfg defaultSession defaultDrivers

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
