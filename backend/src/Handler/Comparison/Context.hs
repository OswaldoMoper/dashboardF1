-- | Área comparación de vueltas — orquestación del caso de uso.
--
-- Quinta y última área de la Fase 4, y la primera cuya respuesta es __un
-- objeto__ y no una colección. La escalera es la misma de las otras cuatro
-- (@try@ → cache → dummy, 2026-07-22) pero el criterio de
-- fallo no puede ser el habitual: no hay lista vacía que mirar.
--
-- El criterio es @'null' . 'lcDelta'@ (2026-08-03). Es el
-- análogo exacto de la lista vacía de las otras áreas: @lcDelta@ es la única
-- serie del DTO —los otros cuatro campos son etiquetas— y sin ella no hay nada
-- que dibujar, así que un objeto bien formado y sin delta es tan poco servible
-- como una tabla vacía. Sin este criterio, el @try@ solo cubriría el servicio
-- caído, el 404 y el JSON con otra forma: la comparación sin traza pasaría
-- limpia hasta el widget.
module Handler.Comparison.Context where

import           App                        (Env (..))
import           Common.Types               (LapComparison (..))
import           Config                     (Config)
import           Control.Concurrent.STM     (atomically, modifyTVar',
                                             readTVarIO)
import           Control.Exception          (SomeException, try)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromMaybe)
import           Data.Text                  (Text)
import           Handler.Comparison.Helper  (assembleComparison, resolveParams)
import qualified Handler.Comparison.Manager as Manager
import           Outcome                    (Outcome (..), classify)

-- | La comparación de la vuelta rápida de dos coches, por tres ramas y en este
-- orden:
--
-- * el fetch trae delta → se guarda en la cache y se sirve;
-- * la excepción es culpa del cliente ('Outcome.classify') → se rechaza sin tocar
--   la cache (2026-08-14);
-- * cualquier otra cosa —servicio apagado, techo vencido, @5xx@, JSON con otra
--   forma, o un delta vacío (@null . 'lcDelta'@, 2026-08-03)— → la última
--   respuesta buena __de esa misma clave__ y, sin ninguna, el dummy.
--
-- La cache va por clave resuelta: sin ella, quien pide dos coches recibiría la
-- comparación de otros dos (2026-08-01).
--
-- Un parámetro escrito pero vacío se rechaza antes de salir a la red y sin tocar
-- la cache.
getComparison :: Env -> Maybe Text -> Maybe Text -> IO (Outcome LapComparison)
getComparison env session drivers = case resolveParams session drivers of
  Left rejection -> pure (Refused rejection)
  Right key@(sessionKey, driversKey) -> do
    result <-
      try (fetchLapComparison (envConfig env) sessionKey driversKey)
        :: IO (Either SomeException LapComparison)
    case result of
      Right comparison | not (null (lcDelta comparison)) -> do
        atomically (modifyTVar' (envComparisonCache env) (Map.insert key comparison))
        pure (Served comparison)
      Left e | Just rejection <- classify e -> pure (Refused rejection)
      _ -> do
        cached <- readTVarIO (envComparisonCache env)
        pure (Served (lookupCached key cached))

-- | Respaldo para una clave: la última respuesta buena de __esa__ combinación, o
-- el dummy. Nunca la de otra clave (espejo de
-- 'Handler.Telemetry.Context.lookupCached').
lookupCached :: (Text, Text) -> Map (Text, Text) LapComparison -> LapComparison
lookupCached key = fromMaybe dummy . Map.lookup key

-- | El GET al microservicio y el mapeo puro, encadenados. Vive fuera del @try@
-- del llamador solo por legibilidad: cualquier excepción que lance —servicio
-- apagado, timeout, JSON con otra forma, o un @400@ porque @drivers@ no son
-- exactamente dos números de coche— la atrapa 'getComparison'.
fetchLapComparison :: Config -> Text -> Text -> IO LapComparison
fetchLapComparison cfg sessionKey driversKey =
  assembleComparison <$> Manager.fetchComparison cfg sessionKey driversKey

-- | Comparación dummy (respaldo cuando el microservicio nunca dio datos). Misma
-- forma que emite 'Handler.Comparison.Helper.assembleComparison' —acrónimos,
-- tiempos ya formateados y un delta no vacío—, para que el widget sea ejercitable
-- sin el servicio levantado.
--
-- El delta son las cuatro fronteras de sector, arranca en @0.0@ y acaba en la
-- diferencia entre los dos tiempos (2026-08-11).
--
-- Los coches son los de 'Handler.Comparison.Helper.defaultDrivers', con el
-- acrónimo que les da la parrilla real (@1@ es @NOR@). La coherencia con
-- 'Handler.Drivers.Context.dummy' la fija un caso de @backend-test@ (2026-08-06).
dummy :: LapComparison
dummy =
  MkLapComparison
    { lcDriverA = "NOR"
    , lcDriverB = "LEC"
    , lcCarA = "1"
    , lcCarB = "16"
    , lcLapA = "1:29.345"
    , lcLapB = "1:29.512"
    , lcDelta = [0.0, -0.048, 0.081, 0.167]
    }
