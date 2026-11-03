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
import           Common.Origin             (Origin (..))
import           Common.Types              (TelemetryPoint (..))
import           Config                    (Config)
import           Control.Concurrent.STM    (atomically, readTVar, writeTVar)
import           Control.Exception         (SomeException, try)
import           Data.Maybe                (fromMaybe)
import           Data.Text                 (Text)
import           Data.Time.Clock           (getCurrentTime)
import           Handler.FastF1.Helper     (fastf1Step)
import           Handler.Telemetry.Helper  (assemblePoints, resolveParams)
import qualified Handler.Telemetry.Manager as Manager
import           Outcome                   (Outcome (..), classify)
import           Provenance                (Provenanced (..))

-- | La telemetría de la vuelta rápida de cada piloto, con su procedencia, por tres
-- ramas y en este orden:
--
-- * el fetch trae puntos → se guardan en la cache con la hora y se sirven ('Fresh');
-- * la excepción es culpa del cliente ('Outcome.classify') → se rechaza sin tocar
--   la cache (2026-08-14);
-- * cualquier otra cosa —servicio apagado, techo vencido, @5xx@, JSON con otra
--   forma, o la lista vacía de una sesión que no publicó telemetría— → la última
--   respuesta buena __de esa misma clave__ ('Cached', con su hora) y, sin ninguna,
--   el dummy ('Sample').
--
-- La cache va por clave resuelta: sin ella, quien pide un piloto recibiría la
-- telemetría de otro (2026-08-01).
--
-- Un parámetro escrito pero vacío se rechaza antes de salir a la red y sin tocar
-- la cache.
getTelemetry
  :: Env -> Maybe Text -> Maybe Text -> IO (Outcome (Provenanced [TelemetryPoint]))
getTelemetry env session driver = case resolveParams session driver of
  Left rejection -> pure (Refused rejection)
  Right key@(sessionKey, driverKey) -> do
    result <-
      try (fetchPoints (envConfig env) sessionKey driverKey)
        :: IO (Either SomeException [TelemetryPoint])
    case result of
      Left e | Just rejection <- classify e -> pure (Refused rejection)
      _ -> do
        now <- getCurrentTime
        served <- atomically $ do
          cached <- readTVar (envTelemetryCache env)
          let (shown, kept) = fastf1Step (not . null) now key (either (const Nothing) Just result) cached
          writeTVar (envTelemetryCache env) kept
          pure shown
        pure (Served (fromMaybe (Provenanced Sample Nothing Nothing dummy) served))

-- | El GET al microservicio y el mapeo puro, encadenados. Vive fuera del @try@
-- del llamador solo por legibilidad: cualquier excepción que lance —servicio
-- apagado, timeout, JSON con otra forma, o un @400@ por un @driver@ que no son
-- números de coche— la atrapa 'getTelemetry'.
fetchPoints :: Config -> Text -> Text -> IO [TelemetryPoint]
fetchPoints cfg sessionKey driverKey =
  assemblePoints <$> Manager.fetchTelemetry cfg sessionKey driverKey

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
