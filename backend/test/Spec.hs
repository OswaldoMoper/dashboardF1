-- | Invariantes de la lógica pura de las áreas Historical
-- ('Handler.Historical.Helper'), Telemetry ('Handler.Telemetry.Helper' y la
-- resolución de parámetros de 'Handler.Telemetry.Context'), Comparison
-- ('Handler.Comparison.Helper' y el @resolveParams@ de su 'Context') y Drivers
-- (ídem).
--
-- Un caso no encaja en ese reparto y es deliberado: la __coherencia entre los
-- dummies__ de Drivers y Comparison. No prueba una función sino un acuerdo entre
-- dos áreas —que la parrilla de respaldo contenga los coches que la comparación
-- de respaldo pinta—, y sin él nada impide que un cambio en un dummy deje al
-- widget de mañana enseñando una lista que no contiene lo que está dibujando.
--
-- Cubre además dos módulos de @common@ que no son del backend, y por la misma
-- razón: viven allí precisamente para que esta suite los alcance, ya que el
-- paquete @frontend@ no tiene ninguna (2026-08-04).
--
-- * 'Common.Chart' — el escalado del gráfico de comparación.
-- * 'Common.Route.driversParam' — la validación de los números de coche que el
--   widget de comparación teclea (2026-08-05). Es lógica de
--   __widget__ probada aquí: sin esto, lo único que impide mandar un acrónimo a
--   un endpoint que lo absorbe en silencio estaría solo revisado a ojo.
--
-- Los fixtures son recortes reales de la respuesta de cada servicio en
-- 'ByteString' y se decodifican con 'eitherDecodeStrict', así que cada caso
-- ejercita __el 'FromJSON' y la función de ensamblado juntos__: los dos son la
-- unidad que el @Context@ del área consume, y separarlos dejaría sin cubrir
-- precisamente los campos opcionales, que viven en el decode.
module Main (main) where

import           Common.Chart                (chartHeight, chartPad, chartWidth,
                                              deltaPoints, deltaPolyline,
                                              deltaRange, zeroLineY)
import           Common.Route                (comparisonPathFor, driversParam,
                                              driversPathFor)
import           Common.Types                (DriverEntry (..),
                                              HistoricalStat (..),
                                              LapComparison (..),
                                              StatEntity (..),
                                              TelemetryPoint (..))
import           Data.Aeson                  (eitherDecodeStrict)
import           Data.ByteString             (ByteString)
import qualified Data.Text                   as T
import qualified Handler.Comparison.Context  as Comparison
import           Handler.Comparison.Helper   (RawComparison, assembleComparison)
import qualified Handler.Drivers.Context     as Drivers
import           Handler.Drivers.Helper      (RawDriver, assembleDrivers)
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
    it "mapea las siete claves del objeto conservando el orden de la serie del delta" $
      comparisonOf comparisonObject
        `shouldBe`
          MkLapComparison
            { lcDriverA = "VER"
            , lcDriverB = "LEC"
            , lcCarA = "1"
            , lcCarB = "16"
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
            , lcCarA = "1"
            , lcCarB = "16"
            , lcLapA = ""
            , lcLapB = ""
            , lcDelta = []
            }

    it "trata la clave lcDelta ausente igual que la serie vacía" $
      lcDelta (comparisonOf comparisonWithoutDeltaKey) `shouldBe` []

    it "decodifica la respuesta de un servicio sin números de coche en vez de tumbar el objeto" $ do
      -- El caso del microservicio viejo todavía en pie: con `.:` la comparación
      -- entera caería al dummy en silencio. Se pierde el viaje de vuelta, no la
      -- comparación.
      let old = comparisonOf comparisonWithoutCars
      (lcCarA old, lcCarB old) `shouldBe` ("", "")
      lcDriverA old `shouldBe` "VER"
      lcDelta old `shouldBe` [0.0, -0.048, 0.081, 0.167]

  describe "Comparison.resolveParams" $ do
    it "sin parámetros compara los dos coches del dummy, en números y no en acrónimos" $
      Comparison.resolveParams Nothing Nothing `shouldBe` ("latest", "1,16")

    it "respeta el parámetro presente y deja el ausente en su defecto" $ do
      Comparison.resolveParams (Just "2026-13-Q") Nothing `shouldBe` ("2026-13-Q", "1,16")
      Comparison.resolveParams Nothing (Just "44,63") `shouldBe` ("latest", "44,63")

  describe "assembleDrivers" $ do
    it "mapea la parrilla conservando el orden que le da FastF1, no el numérico" $
      -- El orden de una carrera cargada es el de clasificación (1, 3, 12, 16…),
      -- y es información que solo el servicio tiene. Ordenar para presentar es
      -- del widget; aquí reordenar la destruiría.
      driversOf driverGrid
        `shouldBe`
          [ MkDriverEntry "1" "NOR" "McLaren"
          , MkDriverEntry "3" "VER" "Red Bull Racing"
          , MkDriverEntry "16" "LEC" "Ferrari"
          ]

    it "deja pasar el coche cuyo acrónimo no resuelve, con deCode repitiendo el número" $
      -- El fallback de `_driver_label` en el microservicio. Filtrarlo daría una
      -- parrilla incompleta sin decirlo: el coche está en la sesión aunque no se
      -- sepa quién lo lleva.
      driversOf gridWithUnresolvedCode
        `shouldBe`
          [ MkDriverEntry "1" "NOR" "McLaren"
          , MkDriverEntry "44" "44" ""
          ]

    it "decodifica la parrilla de un servicio sin equipo en vez de tumbar la lista" $ do
      -- El caso del microservicio viejo todavía en pie, igual que el de los
      -- números de coche en Comparison: con `.:` toda la parrilla caería al
      -- dummy en silencio. Se pierde la decoración, no la traducción.
      let old = driversOf gridWithoutTeam
      map deTeam old `shouldBe` ["", ""]
      map deCode old `shouldBe` ["NOR", "LEC"]

    it "devuelve [] sobre una sesión sin parrilla publicada" $
      -- Es este [] el que hace que el criterio de fallo del Context vuelva a ser
      -- el simple, a diferencia del `null . lcDelta` de Comparison.
      driversOf emptyArray `shouldBe` []

  describe "Drivers.resolveParams" $ do
    it "sin parámetro consulta la última carrera, como los otros dos endpoints" $
      Drivers.resolveParams Nothing `shouldBe` "latest"

    it "respeta la sesión presente" $
      Drivers.resolveParams (Just "2026-13-Q") `shouldBe` "2026-13-Q"

  describe "driversPathFor" $ do
    it "sin sesión da el path desnudo, que es el caso normal del widget" $
      driversPathFor Nothing `shouldBe` "/api/drivers"

    it "con sesión la pone en el query, y no hay segundo parámetro que omitir" $
      driversPathFor (Just "2026-13-R") `shouldBe` "/api/drivers?session=2026-13-R"

  -- La coherencia entre los dos respaldos de FastF1. No es cosmética: los dos
  -- widgets se miran a la vez, así que un coche que el de comparación pinta y el
  -- selector no lista sería una contradicción visible con el servicio apagado.
  describe "los dummies de Drivers y Comparison" $ do
    it "la parrilla de respaldo contiene los dos coches que la comparación de respaldo pinta" $ do
      let numbers = map deNumber Drivers.dummy
      lcCarA Comparison.dummy `shouldSatisfy` (`elem` numbers)
      lcCarB Comparison.dummy `shouldSatisfy` (`elem` numbers)

    it "y les da el mismo acrónimo que la parrilla, no uno distinto para el mismo coche" $ do
      -- La mitad que faltaba, y la que se había desincronizado: el dummy de
      -- comparación decía que el coche 1 era VER desde la Fase 1, y la primera
      -- parrilla real (2026-08-06) mostró que es NOR. Contener el número no basta
      -- si las dos áreas lo nombran distinto.
      codeOfCar (lcCarA Comparison.dummy) `shouldBe` Just (lcDriverA Comparison.dummy)
      codeOfCar (lcCarB Comparison.dummy) `shouldBe` Just (lcDriverB Comparison.dummy)

  -- Lógica del __widget__, probada aquí porque `frontend` no tiene suite
  -- (2026-08-04). Es lo único que impide que un acrónimo
  -- tecleado salga hacia un endpoint que responde 200 con el dummy.
  describe "driversParam" $ do
    it "une dos números de coche en el valor que espera el query" $
      driversParam "1" "16" `shouldBe` Just "1,16"

    it "recorta los espacios, que son descuido de tecleo y no intención" $
      driversParam "  1 " "16  " `shouldBe` Just "1,16"

    it "rechaza el acrónimo, que es el fallo silencioso que esta función existe para cerrar" $ do
      driversParam "VER" "LEC" `shouldBe` Nothing
      driversParam "1" "LEC" `shouldBe` Nothing

    it "rechaza el campo vacío o en blanco en cualquiera de los dos lados" $ do
      driversParam "" "16" `shouldBe` Nothing
      driversParam "1" "   " `shouldBe` Nothing

    it "acepta un coche contra sí mismo: es legal en la API y da el delta plano" $
      driversParam "1" "1" `shouldBe` Just "1,1"

    -- El `Just` intermedio no es ruido: `comparisonPathFor` ya acepta `Maybe`, y
    -- pasarle el `Nothing` de una entrada inválida daría el path __sin__ query —
    -- es decir, la comparación por defecto presentada como la que se pidió. El
    -- widget tiene que quedarse en el `Maybe` de fuera y no disparar nada.
    it "compone con comparisonPathFor, que es su único uso" $
      fmap (comparisonPathFor Nothing . Just) (driversParam "44" "63")
        `shouldBe` Just "/api/comparison?drivers=44,63"

  -- El escalado del gráfico vive en `common` y no en `Widgets.Comparison`
  -- justamente para llegar hasta aquí: el paquete `frontend` no tiene suite
  -- (2026-08-04). Los dos primeros casos son las dos
  -- divisiones por cero reales del módulo.
  describe "Common.Chart" $ do
    it "la serie vacía no produce puntos ni atributo, en vez de dividir por cero" $ do
      deltaPoints [] `shouldBe` []
      deltaPolyline [] `shouldBe` ""

    it "una serie constante no degenera el rango (una vuelta contra sí misma)" $ do
      deltaRange [0, 0, 0] `shouldBe` (-1, 1)
      map snd (deltaPoints [0, 0, 0]) `shouldBe` replicate 3 (chartHeight / 2)

    it "el eje incluye el cero aunque la serie no lo cruce" $ do
      deltaRange [0.1, 0.2, 0.3] `shouldBe` (0, 0.3)
      deltaRange [-0.3, -0.2, -0.1] `shouldBe` (-0.3, 0)

    it "la línea del cero se apoya en el borde cuando la serie no cambia de signo" $ do
      zeroLineY [0.1, 0.2, 0.3] `shouldBe` chartHeight - chartPad
      zeroLineY [-0.3, -0.2, -0.1] `shouldBe` chartPad

    it "un solo punto va al centro horizontal y no divide por cero" $
      map fst (deltaPoints [0.5]) `shouldBe` [chartWidth / 2]

    it "la serie del dummy ocupa el ancho útil de extremo a extremo" $ do
      let xs = map fst (deltaPoints [0.0, -0.05, 0.08, 0.12, 0.167])
      head xs `shouldBe` chartPad
      last xs `shouldBe` chartWidth - chartPad

    it "emite `points` con coordenadas enteras, sin notación científica" $
      deltaPolyline [0, 0, 0] `shouldBe` "10,100 300,100 590,100"

    prop "ninguna coordenada se sale del viewBox" staysInsideViewBox

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

-- | El invariante que hace segura la función: sea cual sea la serie, todo punto
-- cae dentro del lienzo. Cubre de golpe las dos divisiones por cero y los
-- desbordamientos de escala que ningún caso concreto va a adivinar.
--
-- El 'Arbitrary' de 'Double' de QuickCheck no genera @NaN@\/@Infinity@ (mismo
-- supuesto que 'roundTripsDouble'), así que la serie generada es siempre finita —
-- que es también lo que garantiza el @_num@ del microservicio.
staysInsideViewBox :: [Double] -> Bool
staysInsideViewBox xs = all inside (deltaPoints xs)
  where
    inside (x, y) =
      x >= 0 && x <= chartWidth && y >= chartPad && y <= chartHeight - chartPad

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

-- | Espejo de 'pointsOf' para el área Drivers. El par importa por la misma razón
-- que en Comparison: el criterio del área vive en que la sesión sin parrilla
-- __decodifique__ como @[]@ para que el @Context@ la trate como fallo, y en que
-- el equipo ausente (@.:? … .!= \"\"@) no tumbe la lista entera.
driversOf :: ByteString -> [DriverEntry]
driversOf = assembleDrivers . decodeDrivers

-- | El acrónimo que la parrilla de respaldo le da a un número de coche, o
-- 'Nothing' si ese coche no está en ella. Une los dos dummies de FastF1 sin que
-- ninguno de los dos módulos tenga que conocer al otro.
codeOfCar :: T.Text -> Maybe T.Text
codeOfCar number =
  case filter ((== number) . deNumber) Drivers.dummy of
    (entry : _) -> Just (deCode entry)
    []          -> Nothing

decodeDrivers :: ByteString -> [RawDriver]
decodeDrivers raw =
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
  \\"lcCarA\":\"1\",\"lcCarB\":\"16\",\
  \\"lcLapA\":\"1:29.345\",\"lcLapB\":\"1:29.512\",\
  \\"lcDelta\":[0.0,-0.048,0.081,0.167]}"

-- | Sesión sin vueltas comparables: el servicio emite el objeto completo con
-- @lcDelta@ vacío y los tiempos en @\"\"@ en vez de un error, porque degradar es
-- trabajo del backend (2026-07-31).
-- Los números de coche __sí__ están aquí: el servicio los conoce antes de mirar
-- las vueltas (son la entrada del query), así que una sesión sin vueltas
-- comparables sigue sabiendo de qué dos coches habla.
comparisonWithoutDelta :: ByteString
comparisonWithoutDelta =
  "{\"lcDriverA\":\"VER\",\"lcDriverB\":\"LEC\",\
  \\"lcCarA\":\"1\",\"lcCarB\":\"16\",\
  \\"lcLapA\":\"\",\"lcLapB\":\"\",\"lcDelta\":[]}"

-- | La clave @lcDelta@ __ausente__, no vacía. El servicio de hoy siempre la emite,
-- así que este caso protege contra un cambio futuro del contrato: con @.:@ tumbaría
-- el decode del objeto completo y el degradado ocurriría por excepción de parseo en
-- vez de por el criterio del 'Handler.Comparison.Context'.
comparisonWithoutDeltaKey :: ByteString
comparisonWithoutDeltaKey =
  "{\"lcDriverA\":\"VER\",\"lcDriverB\":\"LEC\",\
  \\"lcCarA\":\"1\",\"lcCarB\":\"16\",\
  \\"lcLapA\":\"1:29.345\",\"lcLapB\":\"1:29.512\"}"

-- | La respuesta de un microservicio __anterior__ a los números de coche: sin
-- @lcCarA@\/@lcCarB@. No es un caso hipotético — el servicio corre en un @venv@
-- arrancado a mano y no se despliega con el backend, así que un @uvicorn@ viejo
-- todavía en pie emite exactamente esto. Con @.:@ tumbaría el objeto completo y
-- __toda__ comparación caería al dummy en silencio; con @.:?@ llega la
-- comparación entera y solo falta el viaje de vuelta
-- (2026-08-05).
comparisonWithoutCars :: ByteString
comparisonWithoutCars =
  "{\"lcDriverA\":\"VER\",\"lcDriverB\":\"LEC\",\
  \\"lcLapA\":\"1:29.345\",\"lcLapB\":\"1:29.512\",\
  \\"lcDelta\":[0.0,-0.048,0.081,0.167]}"

-- | Recorte de @GET \/fastf1\/drivers\/{session_key}@ — los tres primeros coches
-- de la parrilla real de la sesión del 2026-08-06, en el orden que los da
-- FastF1. Ese orden (1, 3, 16, …) no es el numérico ni el del campeonato: en una
-- carrera cargada es el de clasificación, y es lo que el mapeo tiene que
-- preservar.
driverGrid :: ByteString
driverGrid =
  "[{\"deNumber\":\"1\",\"deCode\":\"NOR\",\"deTeam\":\"McLaren\"},\
  \{\"deNumber\":\"3\",\"deCode\":\"VER\",\"deTeam\":\"Red Bull Racing\"},\
  \{\"deNumber\":\"16\",\"deCode\":\"LEC\",\"deTeam\":\"Ferrari\"}]"

-- | Un coche cuyo acrónimo FastF1 no resuelve: @_driver_label@ cae al número y
-- el equipo sale vacío. No se dio en la parrilla del 2026-08-06 —los 22
-- resolvieron—, pero es el caso que el fallback existe para cubrir, y el que
-- decide si el mapeo filtra o deja pasar.
gridWithUnresolvedCode :: ByteString
gridWithUnresolvedCode =
  "[{\"deNumber\":\"1\",\"deCode\":\"NOR\",\"deTeam\":\"McLaren\"},\
  \{\"deNumber\":\"44\",\"deCode\":\"44\",\"deTeam\":\"\"}]"

-- | La respuesta de un microservicio __anterior__ al equipo: sin @deTeam@.
-- Mismo caso que 'comparisonWithoutCars' y por el mismo motivo — el servicio
-- corre en un @venv@ arrancado a mano y no se despliega con el backend
-- (2026-07-31), así que un @uvicorn@ viejo en pie emite
-- exactamente esto. Con @.:@ tumbaría la lista completa y la parrilla entera
-- caería al dummy en silencio.
gridWithoutTeam :: ByteString
gridWithoutTeam =
  "[{\"deNumber\":\"1\",\"deCode\":\"NOR\"},\
  \{\"deNumber\":\"16\",\"deCode\":\"LEC\"}]"
