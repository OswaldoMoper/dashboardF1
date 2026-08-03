-- | Invariantes de la lógica pura de las áreas Historical
-- ('Handler.Historical.Helper'), Telemetry ('Handler.Telemetry.Helper' y la
-- resolución de parámetros de 'Handler.Telemetry.Context') y Comparison
-- ('Handler.Comparison.Helper' y el @resolveParams@ de su 'Context').
--
-- Los fixtures son recortes reales de la respuesta de cada servicio en
-- 'ByteString' y se decodifican con 'eitherDecodeStrict', así que cada caso
-- ejercita __el 'FromJSON' y la función de ensamblado juntos__: los dos son la
-- unidad que el @Context@ del área consume, y separarlos dejaría sin cubrir
-- precisamente los campos opcionales, que viven en el decode.
module Main (main) where

import           Common.Types                (HistoricalStat (..),
                                              LapComparison (..),
                                              StatEntity (..),
                                              TelemetryPoint (..))
import           Data.Aeson                  (eitherDecodeStrict)
import           Data.ByteString             (ByteString)
import qualified Data.Text                   as T
import qualified Handler.Comparison.Context  as Comparison
import           Handler.Comparison.Helper   (RawComparison, assembleComparison)
import           Handler.Historical.Helper   (Root, assembleConstructorStats,
                                              assembleStats, parseNum)
import qualified Handler.Telemetry.Context   as Telemetry
import           Handler.Telemetry.Helper    (FastF1Point, assemblePoints)
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

  describe "assemblePoints" $ do
    it "mapea cada muestra conservando las ocho magnitudes, el orden y los bloques por piloto" $
      pointsOf telemetryArray
        `shouldBe`
          [ TelemetryPoint "VER" 0.0 0 312.5 1.0 0.0 8 11800
          , TelemetryPoint "VER" 0.5 42 298.1 0.0 0.6 7 10500
          , TelemetryPoint "NOR" 0.0 0 309.8 1.0 0.0 8 11650
          ]

    it "descarta solo la muestra sin canal de coche, no la vuelta de los demás" $
      pointsOf sampleWithoutBrake
        `shouldBe`
          [ TelemetryPoint "VER" 0.0 0 312.5 1.0 0.0 8 11800
          , TelemetryPoint "NOR" 0.0 0 309.8 1.0 0.0 8 11650
          ]

    it "descarta la muestra sin ningún canal de coche en vez de inventar ceros" $
      pointsOf sampleWithoutCarData `shouldBe` []

    it "devuelve [] sobre un arreglo vacío (sesión sin telemetría publicada)" $
      pointsOf emptyArray `shouldBe` []

  describe "Telemetry.resolveParams" $ do
    it "sin parámetros aplica los defaults, que es el comportamiento previo a que existieran" $
      Telemetry.resolveParams Nothing Nothing `shouldBe` ("latest", "all")

    it "respeta el parámetro presente y deja el ausente en su defecto" $ do
      Telemetry.resolveParams (Just "2026-13-R") Nothing `shouldBe` ("2026-13-R", "all")
      Telemetry.resolveParams Nothing (Just "1,4") `shouldBe` ("latest", "1,4")

  describe "assembleComparison" $ do
    it "mapea las cinco claves del objeto conservando el orden de la serie del delta" $
      comparisonOf comparisonObject
        `shouldBe`
          MkLapComparison
            { lcDriverA = "VER"
            , lcDriverB = "LEC"
            , lcLapA = "1:29.345"
            , lcLapB = "1:29.512"
            , lcDelta = [0.0, -0.048, 0.081, 0.167]
            }

    it "decodifica la sesión sin vueltas comparables en vez de fallar el parseo" $
      -- Es este objeto el que hace que el criterio de fallo del Context sea
      -- `null . lcDelta`: llega bien formado, así que el `try` no lo ve, y sin
      -- delta no hay nada que dibujar.
      comparisonOf comparisonWithoutDelta
        `shouldBe`
          MkLapComparison
            { lcDriverA = "VER"
            , lcDriverB = "LEC"
            , lcLapA = ""
            , lcLapB = ""
            , lcDelta = []
            }

    it "trata la clave lcDelta ausente igual que la serie vacía" $
      lcDelta (comparisonOf comparisonWithoutDeltaKey) `shouldBe` []

  describe "Comparison.resolveParams" $ do
    it "sin parámetros compara los dos coches del dummy, en números y no en acrónimos" $
      Comparison.resolveParams Nothing Nothing `shouldBe` ("latest", "1,16")

    it "respeta el parámetro presente y deja el ausente en su defecto" $ do
      Comparison.resolveParams (Just "2026-13-Q") Nothing `shouldBe` ("2026-13-Q", "1,16")
      Comparison.resolveParams Nothing (Just "44,63") `shouldBe` ("latest", "44,63")

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

-- | Espejo de 'driverStatsOf' para el área Telemetry: decodifica el arreglo plano
-- que emite el microservicio y le aplica el mapeo puro, para que cada caso
-- ejercite el 'FromJSON' y 'assemblePoints' __juntos__.
pointsOf :: ByteString -> [TelemetryPoint]
pointsOf = assemblePoints . decodePoints

decodePoints :: ByteString -> [FastF1Point]
decodePoints raw =
  either (error . ("fixture no decodificable: " <>)) id (eitherDecodeStrict raw)

-- | Espejo de 'pointsOf' para el área Comparison. Aquí el par decode + ensamblado
-- importa __más__ que en las otras dos: el criterio del área vive precisamente en
-- que el objeto sin delta __decodifique__ (@.:? … .!= []@) para que el @Context@
-- pueda tratarlo como fallo. Probar 'assembleComparison' sobre un
-- 'RawComparison' construido a mano no cubriría eso.
comparisonOf :: ByteString -> LapComparison
comparisonOf = assembleComparison . decodeComparison

decodeComparison :: ByteString -> RawComparison
decodeComparison raw =
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

-- | Recorte del arreglo de @telemetry-service@: dos muestras de un piloto y una
-- de otro, con las ocho claves. Sin envoltura —a diferencia de Ergast, el
-- microservicio devuelve el arreglo desnudo—, así que 'envelope' no se reusa.
telemetryArray :: ByteString
telemetryArray =
  "[{\"tpDriver\":\"VER\",\"tpSessionTime\":0.0,\"tpDistance\":0.0,\
  \\"tpSpeed\":312.5,\"tpThrottle\":1.0,\"tpBrake\":0.0,\
  \\"tpGear\":8,\"tpRpm\":11800},\
  \{\"tpDriver\":\"VER\",\"tpSessionTime\":0.5,\"tpDistance\":42.0,\
  \\"tpSpeed\":298.1,\"tpThrottle\":0.0,\"tpBrake\":0.6,\
  \\"tpGear\":7,\"tpRpm\":10500},\
  \{\"tpDriver\":\"NOR\",\"tpSessionTime\":0.0,\"tpDistance\":0.0,\
  \\"tpSpeed\":309.8,\"tpThrottle\":1.0,\"tpBrake\":0.0,\
  \\"tpGear\":8,\"tpRpm\":11650}]"

-- | La muestra de en medio llega con @tpBrake@ en @null@ (FastF1 no midió el
-- canal). Con @.:@ una sola lectura ausente tumbaba el decode del arreglo
-- __completo__ y degradaba @/api/telemetry@ a cache\/dummy, perdiendo también la
-- vuelta de los demás pilotos.
sampleWithoutBrake :: ByteString
sampleWithoutBrake =
  "[{\"tpDriver\":\"VER\",\"tpSessionTime\":0.0,\"tpDistance\":0.0,\
  \\"tpSpeed\":312.5,\"tpThrottle\":1.0,\"tpBrake\":0.0,\
  \\"tpGear\":8,\"tpRpm\":11800},\
  \{\"tpDriver\":\"VER\",\"tpSessionTime\":0.5,\"tpDistance\":42.0,\
  \\"tpSpeed\":298.1,\"tpThrottle\":0.0,\"tpBrake\":null,\
  \\"tpGear\":7,\"tpRpm\":10500},\
  \{\"tpDriver\":\"NOR\",\"tpSessionTime\":0.0,\"tpDistance\":0.0,\
  \\"tpSpeed\":309.8,\"tpThrottle\":1.0,\"tpBrake\":0.0,\
  \\"tpGear\":8,\"tpRpm\":11650}]"

-- | Muestra con solo los cuatro campos obligatorios (traza de posición sin
-- canales de coche): decodifica y se descarta, en vez de publicar un frenazo y un
-- punto muerto que FastF1 nunca midió.
sampleWithoutCarData :: ByteString
sampleWithoutCarData =
  "[{\"tpDriver\":\"VER\",\"tpSessionTime\":0.5,\"tpDistance\":42.0,\
  \\"tpSpeed\":298.1}]"

-- | Sesión sin telemetría publicada. Es este @[]@ el que hace que el
-- 'Handler.Telemetry.Context' caiga a cache\/dummy en vez de servir una tabla
-- vacía.
emptyArray :: ByteString
emptyArray = "[]"

-- | Recorte de @GET \/fastf1\/comparison\/{session_key}?drivers=1,16@: __un
-- objeto__, no un arreglo, con las cinco claves. Es la única respuesta del repo
-- que no es una colección, y de ahí que el área necesite su propio criterio de
-- fallo.
comparisonObject :: ByteString
comparisonObject =
  "{\"lcDriverA\":\"VER\",\"lcDriverB\":\"LEC\",\
  \\"lcLapA\":\"1:29.345\",\"lcLapB\":\"1:29.512\",\
  \\"lcDelta\":[0.0,-0.048,0.081,0.167]}"

-- | Sesión sin vueltas comparables: el servicio emite el objeto completo con
-- @lcDelta@ vacío y los tiempos en @\"\"@ en vez de un error, porque degradar es
-- trabajo del backend (2026-07-31).
comparisonWithoutDelta :: ByteString
comparisonWithoutDelta =
  "{\"lcDriverA\":\"VER\",\"lcDriverB\":\"LEC\",\
  \\"lcLapA\":\"\",\"lcLapB\":\"\",\"lcDelta\":[]}"

-- | La clave @lcDelta@ __ausente__, no vacía. El servicio de hoy siempre la emite,
-- así que este caso protege contra un cambio futuro del contrato: con @.:@ tumbaría
-- el decode del objeto completo y el degradado ocurriría por excepción de parseo en
-- vez de por el criterio del 'Handler.Comparison.Context'.
comparisonWithoutDeltaKey :: ByteString
comparisonWithoutDeltaKey =
  "{\"lcDriverA\":\"VER\",\"lcDriverB\":\"LEC\",\
  \\"lcLapA\":\"1:29.345\",\"lcLapB\":\"1:29.512\"}"
