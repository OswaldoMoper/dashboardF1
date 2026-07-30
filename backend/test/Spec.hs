-- | Invariantes de la lógica pura del área Historical
-- ('Handler.Historical.Helper').
--
-- Los fixtures son recortes reales de Jolpica en 'ByteString' y se decodifican con
-- 'eitherDecodeStrict', así que cada caso ejercita __el 'FromJSON' y el
-- @assemble*@ juntos__: los dos son la unidad que el 'Handler.Historical.Context'
-- consume, y separarlos dejaría sin cubrir precisamente los campos opcionales, que
-- viven en el decode.
module Main (main) where

import           Common.Types              (HistoricalStat (..), StatEntity (..))
import           Data.Aeson                (eitherDecodeStrict)
import           Data.ByteString           (ByteString)
import qualified Data.Text                 as T
import           Handler.Historical.Helper (Root, assembleConstructorStats,
                                            assembleStats, parseNum)
import           Test.Hspec
import           Test.Hspec.QuickCheck     (prop)
import           Test.QuickCheck           (Property, (===))

main :: IO ()
main = hspec $ do
  describe "assembleStats" $ do
    it "emite dos KPIs por piloto, en el orden de la clasificación y con la identidad completa" $
      driverStatsOf driverStandings
        `shouldBe`
          [ HistoricalStat DriverStat "VER" "Max" "Verstappen" 393 "points"
          , HistoricalStat DriverStat "VER" "Max" "Verstappen" 9 "wins"
          , HistoricalStat DriverStat "NOR" "Lando" "Norris" 331 "points"
          , HistoricalStat DriverStat "NOR" "Lando" "Norris" 3 "wins"
          ]

    it "descarta solo la métrica no parseable, no la entrada entera" $
      driverStatsOf unparseablePoints
        `shouldBe` [HistoricalStat DriverStat "HAM" "Lewis" "Hamilton" 4 "wins"]

    it "usa el apellido como código cuando Jolpica omite `code`" $
      driverStatsOf driverWithoutCode
        `shouldBe`
          [ HistoricalStat DriverStat "Bortoleto" "Gabriel" "Bortoleto" 12 "points"
          , HistoricalStat DriverStat "Bortoleto" "Gabriel" "Bortoleto" 0 "wins"
          ]

    it "omite el KPI de victorias cuando Jolpica no publica `wins`" $
      driverStatsOf driverWithoutWins
        `shouldBe` [HistoricalStat DriverStat "ALO" "Fernando" "Alonso" 24 "points"]

    it "devuelve [] cuando la respuesta no trae la clave DriverStandings" $
      driverStatsOf standingsListWithoutKeys `shouldBe` []

    it "ignora la clasificación de constructores" $
      driverStatsOf constructorStandings `shouldBe` []

  describe "assembleConstructorStats" $ do
    it "emite dos KPIs por constructor, con `constructorId` en hsCode y `name` en hsFamilyName" $
      constructorStatsOf constructorStandings
        `shouldBe`
          [ HistoricalStat ConstructorStat "red_bull" "" "Red Bull" 712 "points"
          , HistoricalStat ConstructorStat "red_bull" "" "Red Bull" 12 "wins"
          , HistoricalStat ConstructorStat "mclaren" "" "McLaren" 640 "points"
          , HistoricalStat ConstructorStat "mclaren" "" "McLaren" 9 "wins"
          ]

    it "devuelve [] cuando la respuesta no trae la clave ConstructorStandings" $
      constructorStatsOf standingsListWithoutKeys `shouldBe` []

    it "ignora la clasificación de pilotos" $
      constructorStatsOf driverStandings `shouldBe` []

  describe "parseNum" $ do
    prop "recupera cualquier entero mostrado como cadena (forma de points/wins en Ergast)"
      roundTripsInt
    prop "es inversa de `show` sobre Double bien formados" roundTripsDouble

    it "es Nothing sobre los textos no numéricos que puede traer Ergast" $ do
      parseNum "" `shouldBe` Nothing
      parseNum "n/a" `shouldBe` Nothing
      parseNum "-" `shouldBe` Nothing
      parseNum "12 points" `shouldBe` Nothing

-- * Propiedades

-- | @points@\/@wins@ llegan de Ergast como enteros en cadena; es la forma que
-- 'parseNum' tiene que recuperar sin excepción.
roundTripsInt :: Int -> Property
roundTripsInt n = parseNum (T.pack (show n)) === Just (fromIntegral n)

-- | Generalización de la anterior a los medios puntos ("18.5") que Ergast publica
-- en carreras suspendidas. El 'Arbitrary' de 'Double' de QuickCheck no genera
-- @NaN@\/@Infinity@, así que la igualdad estricta es correcta aquí.
roundTripsDouble :: Double -> Property
roundTripsDouble d = parseNum (T.pack (show d)) === Just d

-- * Helpers

-- | Decodifica un fixture y aplana la clasificación de pilotos. Un fixture que no
-- decodifica es un error del test, no un fallo del código bajo prueba: por eso
-- aborta con el mensaje de aeson en vez de degradar a @[]@ silenciosamente (que
-- volvería verdes los tests de lista vacía por la razón equivocada).
driverStatsOf :: ByteString -> [HistoricalStat]
driverStatsOf = assembleStats . decodeRoot

-- | Espejo de 'driverStatsOf' para constructores.
constructorStatsOf :: ByteString -> [HistoricalStat]
constructorStatsOf = assembleConstructorStats . decodeRoot

decodeRoot :: ByteString -> Root
decodeRoot raw =
  either (error . ("fixture no decodificable: " <>)) id (eitherDecodeStrict raw)

-- * Fixtures

-- | Envoltura de Ergast (@MRData.StandingsTable.StandingsLists[0]@) alrededor del
-- cuerpo interesante de cada caso. Se declara una sola vez para que los fixtures
-- muestren solo lo que están probando.
envelope :: ByteString -> ByteString
envelope body =
  "{\"MRData\":{\"StandingsTable\":{\"StandingsLists\":\
  \[{\"season\":\"2026\",\"round\":\"13\""
    <> body
    <> "}]}}}"

driverStandings :: ByteString
driverStandings =
  envelope $
    ",\"DriverStandings\":["
      <> "{\"position\":\"1\",\"points\":\"393\",\"wins\":\"9\",\"Driver\":\
         \{\"driverId\":\"max_verstappen\",\"code\":\"VER\",\
         \\"givenName\":\"Max\",\"familyName\":\"Verstappen\"}},"
      <> "{\"position\":\"2\",\"points\":\"331\",\"wins\":\"3\",\"Driver\":\
         \{\"driverId\":\"norris\",\"code\":\"NOR\",\
         \\"givenName\":\"Lando\",\"familyName\":\"Norris\"}}"
      <> "]"

constructorStandings :: ByteString
constructorStandings =
  envelope $
    ",\"ConstructorStandings\":["
      <> "{\"position\":\"1\",\"points\":\"712\",\"wins\":\"12\",\"Constructor\":\
         \{\"constructorId\":\"red_bull\",\"name\":\"Red Bull\"}},"
      <> "{\"position\":\"2\",\"points\":\"640\",\"wins\":\"9\",\"Constructor\":\
         \{\"constructorId\":\"mclaren\",\"name\":\"McLaren\"}}"
      <> "]"

-- | @points@ no parseable: debe sobrevivir el KPI de victorias y solo ese.
unparseablePoints :: ByteString
unparseablePoints =
  envelope $
    ",\"DriverStandings\":[{\"position\":\"5\",\"points\":\"n/a\",\"wins\":\"4\",\
    \\"Driver\":{\"driverId\":\"hamilton\",\"code\":\"HAM\",\
    \\"givenName\":\"Lewis\",\"familyName\":\"Hamilton\"}}]"

-- | Piloto sin @code@ — el caso que tumbaba la lista completa antes del hardening
-- del 2026-07-30.
driverWithoutCode :: ByteString
driverWithoutCode =
  envelope $
    ",\"DriverStandings\":[{\"position\":\"18\",\"points\":\"12\",\"wins\":\"0\",\
    \\"Driver\":{\"driverId\":\"bortoleto\",\
    \\"givenName\":\"Gabriel\",\"familyName\":\"Bortoleto\"}}]"

-- | Entrada sin @wins@: el campo opcional degrada a un KPI menos, no a cero filas.
driverWithoutWins :: ByteString
driverWithoutWins =
  envelope $
    ",\"DriverStandings\":[{\"position\":\"9\",\"points\":\"24\",\
    \\"Driver\":{\"driverId\":\"alonso\",\"code\":\"ALO\",\
    \\"givenName\":\"Fernando\",\"familyName\":\"Alonso\"}}]"

-- | @StandingsList@ sin ninguna de las dos claves: decodifica (ambas son @.:?@ con
-- defecto @[]@ desde el 2026-07-29) y aplana a @[]@. Con @.:@ esto habría lanzado
-- un fallo de parseo y el 'Handler.Historical.Context' degradaría a cache\/dummy.
standingsListWithoutKeys :: ByteString
standingsListWithoutKeys = envelope ""
