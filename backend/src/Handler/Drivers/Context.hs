-- | Área parrilla — orquestación del caso de uso.
--
-- Sexta área del backend y la primera desde la Fase 3, así que el molde está
-- fijado: escalera @try@ → cache → dummy (2026-07-22) y
-- 'resolveParams' como único punto testeable sin red.
--
-- __El criterio de fallo vuelve a ser el simple__ —la lista vacía—, y conviene
-- decirlo porque la última área en llegar hizo lo contrario. El
-- «ningún coche con sectores» de 'Handler.Comparison.Context'
-- (2026-08-03) es la __excepción__ que impuso un DTO que
-- era un objeto y no una colección: sin lista que mirar, hubo que elegir un
-- campo. Aquí la respuesta vuelve a ser una lista, así que @null@ basta y no hay
-- nada que inventar.
--
-- __La cache lleva clave, y con una sola componente.__ Las dos áreas de FastF1
-- cachean por pares —@(sesión, piloto)@ y @(sesión, coches)@— porque sus
-- endpoints filtran; éste no filtra, así que la clave es @session_key@ y ya. Que
-- la lleve no es una comodidad sino correctitud: la parrilla es la de __esa__
-- sesión, y un piloto sustituto o un tercer coche en libres la cambian, así que
-- una caja única serviría la parrilla de otra sesión como si fuera la pedida.
module Handler.Drivers.Context where

import           App                     (Env (..))
import           Common.Origin           (Origin (..))
import           Common.Types            (DriverEntry (..))
import           Config                  (Config)
import           Control.Concurrent.STM  (atomically, readTVar, writeTVar)
import           Control.Exception       (SomeException, try)
import           Data.Maybe              (fromMaybe)
import           Data.Text               (Text)
import           Data.Time.Clock         (getCurrentTime)
import           Handler.Drivers.Helper  (assembleDrivers, resolveParams)
import qualified Handler.Drivers.Manager as Manager
import           Handler.FastF1.Helper   (fastf1Step)
import           Outcome                 (Outcome (..), classify)
import           Provenance              (Provenanced (..))

-- | La parrilla de una sesión, con su procedencia, por tres ramas y en este orden:
--
-- * la excepción es culpa del cliente ('Outcome.classify') → se rechaza sin tocar
--   la cache;
-- * el fetch trae coches → se guardan en la cache con la hora y se sirven ('Fresh');
-- * cualquier otra cosa —servicio apagado, timeout, @5xx@, JSON con otra forma, o
--   la lista vacía de una sesión sin parrilla publicada— → la última parrilla buena
--   __de esa misma sesión__ ('Cached', con su hora) y, sin ninguna, el dummy
--   ('Sample').
--
-- Los dos rechazos de aquí están medidos y son distintos entre sí: @?session=nope@
-- da @400@ (la @session_key@ tiene otra forma) y @?session=2026-99-R@ da @404@ (se
-- escribió bien y esa sesión no se disputó). Ésa es exactamente la separación que
-- 'Outcome.Rejection' mantiene en dos constructores.
--
-- Un parámetro escrito pero vacío se rechaza antes de salir a la red y sin tocar
-- la cache.
getDrivers :: Env -> Maybe Text -> IO (Outcome (Provenanced [DriverEntry]))
getDrivers env session = case resolveParams session of
  Left rejection -> pure (Refused rejection)
  Right key -> do
    result <-
      try (fetchDriverGrid (envConfig env) key)
        :: IO (Either SomeException [DriverEntry])
    case result of
      Left e | Just rejection <- classify e -> pure (Refused rejection)
      _ -> do
        now <- getCurrentTime
        served <- atomically $ do
          cached <- readTVar (envDriversCache env)
          let (shown, kept) = fastf1Step (not . null) now key (either (const Nothing) Just result) cached
          writeTVar (envDriversCache env) kept
          pure shown
        pure (Served (fromMaybe (Provenanced Sample Nothing Nothing dummy) served))

-- | El GET al microservicio y el mapeo puro, encadenados. Vive fuera del @try@
-- del llamador solo por legibilidad: cualquier excepción que lance —servicio
-- apagado, timeout, sesión no resoluble, o JSON con otra forma— la atrapa
-- 'getDrivers'.
fetchDriverGrid :: Config -> Text -> IO [DriverEntry]
fetchDriverGrid cfg sessionKey =
  assembleDrivers <$> Manager.fetchDrivers cfg sessionKey

-- | Parrilla dummy (respaldo cuando el microservicio nunca dio datos).
--
-- __Corta a propósito y con los coches que las otras áreas nombran.__ Incluye el
-- @1@ y el @16@ del dummy de 'Handler.Comparison.Context' porque las dos áreas se
-- consumen juntas: sin eso, con el servicio apagado el widget de comparación
-- pintaría dos coches que no aparecen en la lista de los que se pueden elegir —
-- una contradicción visible entre dos respaldos.
--
-- No pretende ser la parrilla completa. Seis coches bastan para ejercitar un
-- selector y dejan claro que es un respaldo y no el dato; veintidós entradas
-- inventadas se confundirían con los reales.
dummy :: [DriverEntry]
dummy =
  [ MkDriverEntry "1" "NOR" "McLaren"
  , MkDriverEntry "16" "LEC" "Ferrari"
  , MkDriverEntry "3" "VER" "Red Bull Racing"
  , MkDriverEntry "44" "HAM" "Ferrari"
  , MkDriverEntry "63" "RUS" "Mercedes"
  , MkDriverEntry "81" "PIA" "McLaren"
  ]
