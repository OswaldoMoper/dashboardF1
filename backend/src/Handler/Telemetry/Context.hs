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
import           Control.Concurrent.STM    (atomically, modifyTVar', readTVarIO)
import           Control.Exception         (SomeException, try)
import           Data.Map.Strict           (Map)
import qualified Data.Map.Strict           as Map
import           Data.Maybe                (fromMaybe)
import           Data.Text                 (Text)
import           Handler.Telemetry.Helper  (assemblePoints, resolveParams)
import qualified Handler.Telemetry.Manager as Manager
import           Outcome                   (Outcome (..), classify)

-- | Devuelve la telemetría de la vuelta rápida de cada piloto: intenta el fetch
-- real; si funciona, refresca la cache y devuelve; ante fallo o lista vacía sirve
-- la última respuesta buena __de esa misma clave__; sin ninguna, el dummy
-- (espejo de 'Handler.Historical.Context.getHistorical', con la clave como única
-- diferencia).
--
-- La lista vacía cuenta como fallo, no como respuesta: el microservicio devuelve
-- @[]@ cuando la sesión no publicó telemetría, y servir una tabla vacía sería
-- peor que servir la vuelta anterior.
--
-- La cache se lee y escribe con la __clave resuelta__ porque desde que hay
-- parámetros el degradado sin clave es un bug de correctitud: una petición de un
-- piloto concreto recibiría la última respuesta buena de @all@, es decir la
-- telemetría de otros coches presentada como suya
-- (2026-08-01).
--
-- __Tercera y última área con la escalera de tres ramas__, y con ella se cierra el
-- contrato de degradado de la Fase 4: las tres que hablan con el microservicio
-- discriminan un @400@\/@404@ del cliente de un servicio caído
-- (2026-08-14). Las otras tres áreas del backend se quedan en
-- @IO a@ __por decisión y no por deuda__: no tienen @QueryParam@, así que no
-- admiten query malo y no hay nada que discriminar en ellas.
--
-- La rama del medio es la única nueva, no toca la cache —una petición mala no
-- invalida ni refresca nada— y el orden importa: una respuesta válida nunca pasa
-- por el clasificador, y el @_@ final sigue absorbiendo lo que
-- 'Outcome.classify' no reconoce —servicio apagado, timeout, @5xx@, JSON con otra
-- forma— más el @Right@ con la lista vacía, que aquí es una sesión sin telemetría
-- publicada y se degrada.
--
-- Un parámetro escrito pero vacío se rechaza antes de salir a la red y sin tocar
-- la cache.
getTelemetry :: Env -> Maybe Text -> Maybe Text -> IO (Outcome [TelemetryPoint])
getTelemetry env session driver = case resolveParams session driver of
  Left rejection -> pure (Refused rejection)
  Right key@(sessionKey, driverKey) -> do
    result <-
      try (fetchPoints (envConfig env) sessionKey driverKey)
        :: IO (Either SomeException [TelemetryPoint])
    case result of
      Right points | not (null points) -> do
        atomically (modifyTVar' (envTelemetryCache env) (Map.insert key points))
        pure (Served points)
      Left e | Just rejection <- classify e -> pure (Refused rejection)
      _ -> do
        cached <- readTVarIO (envTelemetryCache env)
        pure (Served (lookupCached key cached))

-- | Respaldo para una clave: la última respuesta buena de __esa__ combinación, o
-- el dummy. Nunca la de otra clave.
lookupCached :: (Text, Text) -> Map (Text, Text) [TelemetryPoint] -> [TelemetryPoint]
lookupCached key = fromMaybe dummy . Map.lookup key

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
