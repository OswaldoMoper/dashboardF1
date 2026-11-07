-- | Área comparación de vueltas — orquestación del caso de uso.
--
-- Quinta y última área de la Fase 4, y la primera cuya respuesta es __un
-- objeto__ y no una colección. La escalera es la misma de las otras cuatro
-- (@try@ → cache → dummy, 2026-07-22) pero el criterio de
-- fallo no puede ser el habitual: no hay lista vacía que mirar.
--
-- El criterio es 'Handler.Comparison.Helper.comparable': que __algún__ coche tenga
-- sus tres sectores (2026-08-03; redecidido con los coches sin vuelta, 2026-10-02).
-- Un coche sin vuelta se sirve como tal y lo dice la página; solo una comparación
-- en la que ninguno tiene vuelta cae a lo guardado o al dummy.
module Handler.Comparison.Context where

import           App                        (Env (..))
import           Common.Origin              (Origin (..))
import           Common.Types               (ComparisonEntry (..),
                                             LapComparison (..))
import           Config                     (Config)
import           Control.Concurrent.STM     (atomically, readTVar, writeTVar)
import           Control.Exception          (SomeException, try)
import           Data.Maybe                 (fromMaybe)
import           Data.Text                  (Text)
import           Data.Time.Clock            (getCurrentTime)
import           Handler.Comparison.Helper  (assembleComparison, comparable,
                                             resolveParams, withNotice)
import qualified Handler.Comparison.Manager as Manager
import           Handler.FastF1.Helper      (fastf1Step)
import           Outcome                    (Outcome (..), classify)
import           Provenance                 (Provenanced (..))

-- | La comparación de la vuelta rápida de 1 a 5 coches, con su procedencia, por tres
-- ramas y en este orden:
--
-- * el fetch trae algún coche con vuelta ('comparable') → se guarda en la cache con
--   la hora y se sirve ('Fresh');
-- * la excepción es culpa del cliente ('Outcome.classify') → se rechaza sin tocar
--   la cache (2026-08-14);
-- * cualquier otra cosa —servicio apagado, techo vencido, @5xx@, JSON con otra
--   forma, o ningún coche con vuelta— → la última respuesta buena __de esa misma
--   clave__ ('Cached', con su hora) y, sin ninguna, el dummy ('Sample').
--
-- Las tres ramas que sirven llevan el aviso de lo que se ajustó de @samples@. La
-- cache va sin él y por clave resuelta: sin clave, quien pide unos coches
-- recibiría la comparación de otros (2026-08-01).
--
-- Un parámetro escrito pero vacío se rechaza antes de salir a la red y sin tocar
-- la cache.
getComparison
  :: Env -> Maybe Text -> Maybe Text -> Maybe Int -> IO (Outcome (Provenanced LapComparison))
getComparison env session drivers samples =
  case resolveParams session drivers samples of
    Left rejection -> pure (Refused rejection)
    Right (key@(sessionKey, driversKey, n), notice) -> do
      result <-
        try (fetchLapComparison (envConfig env) sessionKey driversKey n)
          :: IO (Either SomeException LapComparison)
      case result of
        Left e | Just rejection <- classify e -> pure (Refused rejection)
        _ -> do
          now <- getCurrentTime
          served <- atomically $ do
            cached <- readTVar (envComparisonCache env)
            let (shown, kept) = fastf1Step comparable now key (either (const Nothing) Just result) cached
            writeTVar (envComparisonCache env) kept
            pure shown
          let shownWith p = p {pvBody = withNotice notice (pvBody p)}
          pure (Served (shownWith (fromMaybe (Provenanced Sample Nothing Nothing dummy) served)))

-- | El GET al microservicio y el mapeo puro, encadenados. Vive fuera del @try@
-- del llamador solo por legibilidad: cualquier excepción que lance —servicio
-- apagado, timeout, JSON con otra forma, o un @400@ porque @drivers@ no son de 1
-- a 5 números de coche— la atrapa 'getComparison'.
fetchLapComparison :: Config -> Text -> Text -> Int -> IO LapComparison
fetchLapComparison cfg sessionKey driversKey n =
  assembleComparison <$> Manager.fetchComparison cfg sessionKey driversKey n

-- | Comparación dummy (respaldo cuando el microservicio nunca dio datos). Misma
-- forma que emite 'Handler.Comparison.Helper.assembleComparison', para que el
-- widget sea ejercitable sin el servicio levantado. Sin trazas, se pidan o no
-- (2026-10-02).
--
-- Los coches son los de 'Handler.Comparison.Helper.defaultDrivers', en su orden
-- (la referencia, LEC, primero), con el acrónimo que les da la parrilla real. La
-- coherencia con 'Handler.Drivers.Context.dummy' la fija un caso de
-- @backend-test@ (2026-08-06). Los sectores suman los tiempos de vuelta, así que
-- la Δ de NOR acaba en −0,167 (2026-10-02).
dummy :: LapComparison
dummy =
  MkLapComparison
    { lcEntries =
        [ entry "16" "LEC" "1:29.512" (29.0, 31.0, 29.512)
        , entry "1" "NOR" "1:29.345" (29.048, 30.871, 29.426)
        ]
    , lcSamples   = 0
    , lcNotice    = ""
    , lcTelemetry = Nothing
    }
  where
    entry car driver lap sectors =
      MkComparisonEntry
        { ceCar       = car
        , ceDriver    = driver
        , ceLap       = lap
        , cePart      = Nothing
        , ceSectors   = Just sectors
        , ceFrontiers = Nothing
        , ceTrace     = []
        }
