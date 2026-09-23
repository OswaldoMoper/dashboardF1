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

-- | Devuelve la comparación de la vuelta rápida de dos coches: intenta el fetch
-- real; si funciona __y trae delta__, refresca la cache y devuelve; ante fallo o
-- delta vacío sirve la última respuesta buena __de esa misma clave__; sin
-- ninguna, el dummy.
--
-- __Primera área con la escalera de tres ramas__
-- (2026-08-14). La rama nueva es la del medio y solo ella es nueva: si la excepción
-- se reconoce como culpa del cliente ('Outcome.classify'), la petición se rechaza
-- y __no se toca la cache__ —una petición mala no invalida ni refresca nada—. Las
-- otras dos son las de siempre, y el degradado del servicio caído sale byte a byte
-- como salía: sigue siendo el escenario normal y sigue tardando ~5 s
-- (2026-08-04).
--
-- El orden de las ramas importa: el @Right@ bueno va primero, así que una
-- respuesta válida nunca pasa por el clasificador. Y el @_@ final sigue
-- absorbiendo lo que 'Outcome.classify' no reconoce —servicio apagado, timeout,
-- @5xx@, JSON con otra forma— más el @Right@ con delta vacío, que es el criterio
-- de fallo propio de esta área (@null . 'lcDelta'@,
-- 2026-08-03): un objeto sin serie no es un rechazo, es una sesión sin vueltas
-- comparables, y eso se degrada.
--
-- La cache nace con clave, sin fase intermedia de caja única: es aplicación
-- directa del 2026-08-01 —no una re-discusión— y nacer sin ella sería
-- reintroducir a sabiendas el bug que esa decisión arregló, con el mismo agravante
-- de silencio (una petición de dos coches recibiría la comparación de otros dos
-- presentada como suya).
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

-- | Comparación dummy (respaldo cuando el microservicio nunca dio datos). Se muda
-- aquí desde 'Handler.Comparison', como en las otras cuatro áreas. Misma forma que
-- emite 'Handler.Comparison.Helper.assembleComparison' —acrónimos, tiempos ya
-- formateados y un delta no vacío—, para que el widget de comparación sea
-- ejercitable sin el servicio levantado.
--
-- __El delta son cuatro valores desde el 2026-08-11__,
-- no los cinco de paso libre que tenía desde la Fase 1: las cuatro
-- fronteras de sector. Y suman: arranca en @0.0@ y acaba en @0.167@, que es la
-- diferencia entre los dos tiempos de aquí arriba. Un respaldo que no cumpla los
-- invariantes del endpoint entrena el ojo a aceptar gráficos que el dato real no
-- puede producir.
--
-- Los coches son los de 'Handler.Comparison.Helper.defaultDrivers', no dos
-- cualesquiera: así la respuesta sin parámetros y el respaldo hablan de los
-- mismos, y el @1@\/@16@ que el widget muestra es el que mandaría de vuelta al
-- pedir otra comparación.
--
-- __El acrónimo del coche @1@ es @NOR@ y no @VER@ desde el 2026-08-06__, que es
-- cuando el repo vio por primera vez una parrilla real (@\/api\/drivers@): el @1@
-- lo lleva el campeón vigente. El dummy decía @VER@ desde la Fase 1 por inercia,
-- y con dos áreas cuyos respaldos se miran a la vez esa inercia pasó a ser una
-- contradicción visible — el selector listando @NOR@ y esta cabecera diciendo
-- @VER@ del mismo coche. La coherencia entre los dos dummies la fija un caso de
-- @backend-test@, no la buena memoria.
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
