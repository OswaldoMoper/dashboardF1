-- | Área parrilla — orquestación del caso de uso.
--
-- Sexta área del backend y la primera desde la Fase 3, así que el molde está
-- fijado: escalera @try@ → cache → dummy (2026-07-22) y
-- 'resolveParams' como único punto testeable sin red.
--
-- __El criterio de fallo vuelve a ser el simple__ —la lista vacía—, y conviene
-- decirlo porque la última área en llegar hizo lo contrario. El
-- @'null' . 'Common.Types.lcDelta'@ de 'Handler.Comparison.Context'
-- (2026-08-03) fue la __excepción__ que impuso un DTO que
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
import           Common.Types            (DriverEntry (..))
import           Config                  (Config)
import           Control.Concurrent.STM  (atomically, modifyTVar', readTVarIO)
import           Control.Exception       (SomeException, try)
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Maybe              (fromMaybe)
import           Data.Text               (Text)
import           Handler.Drivers.Helper  (assembleDrivers)
import qualified Handler.Drivers.Manager as Manager
import           Outcome                 (Outcome (..), classify)

-- | Sesión que se consulta cuando @\/api\/drivers@ no recibe @?session=@.
-- @latest@ es la última carrera disputada, resuelta por el microservicio.
defaultSession :: Text
defaultSession = "latest"

-- | Aplica el default al @QueryParam@ opcional de 'Server.Api'. Espejo de los
-- @resolveParams@ de Telemetry y Comparison, y por la misma razón: es lo único
-- testeable sin red del módulo, y lo que devuelve es también la __clave de
-- cache__, resuelta una sola vez y aquí para que @?session=latest@ y la ausencia
-- del parámetro no ocupen dos entradas con el mismo contenido.
--
-- Devuelve un 'Text' y no un par, que es la diferencia de forma con las otras
-- dos áreas parametrizadas: aquí solo hay un parámetro que resolver.
resolveParams :: Maybe Text -> Text
resolveParams = fromMaybe defaultSession

-- | Devuelve la parrilla de una sesión: intenta el fetch real; si funciona __y
-- trae coches__, refresca la cache y devuelve; ante fallo o lista vacía sirve la
-- última respuesta buena __de esa misma sesión__; sin ninguna, el dummy.
--
-- __Segunda área con la escalera de tres ramas__, replicando el molde que
-- 'Handler.Comparison.Context.getComparison' estrenó
-- (2026-08-14). La rama del medio es la única nueva: si la excepción se reconoce
-- como culpa del cliente ('Outcome.classify'), la petición se rechaza y __no se
-- toca la cache__ —una petición mala no invalida ni refresca nada—. Las otras dos
-- son las de siempre y el degradado sale byte a byte como salía.
--
-- El orden importa: el @Right@ bueno va primero, así que una parrilla válida nunca
-- pasa por el clasificador; y el @_@ final sigue absorbiendo lo que
-- 'Outcome.classify' no reconoce —servicio apagado, timeout, @5xx@, JSON con otra
-- forma— más el @Right@ con la lista vacía, que es el criterio de fallo de esta
-- área: una sesión sin parrilla publicada no es un rechazo, se degrada.
--
-- Los dos rechazos de aquí están medidos y son distintos entre sí: @?session=nope@
-- da @400@ (la @session_key@ tiene otra forma) y @?session=2026-99-R@ da @404@ (se
-- escribió bien y esa sesión no se disputó). Ésa es exactamente la separación que
-- 'Outcome.Rejection' mantiene en dos constructores.
getDrivers :: Env -> Maybe Text -> IO (Outcome [DriverEntry])
getDrivers env session = do
  let key = resolveParams session
  result <-
    try (fetchDriverGrid (envConfig env) key)
      :: IO (Either SomeException [DriverEntry])
  case result of
    Right grid | not (null grid) -> do
      atomically (modifyTVar' (envDriversCache env) (Map.insert key grid))
      pure (Served grid)
    Left e | Just rejection <- classify e -> pure (Refused rejection)
    _ -> do
      cached <- readTVarIO (envDriversCache env)
      pure (Served (lookupCached key cached))

-- | Respaldo para una clave: la última parrilla buena de __esa__ sesión, o el
-- dummy. Nunca la de otra sesión (espejo de
-- 'Handler.Comparison.Context.lookupCached').
lookupCached :: Text -> Map Text [DriverEntry] -> [DriverEntry]
lookupCached key = fromMaybe dummy . Map.lookup key

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
