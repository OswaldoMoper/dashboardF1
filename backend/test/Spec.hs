-- | Invariantes de la lógica pura de las áreas Historical
-- ('Handler.Historical.Helper'), Telemetry ('Handler.Telemetry.Helper' y la
-- resolución de parámetros de 'Handler.Telemetry.Context'), Comparison
-- ('Handler.Comparison.Helper' y el @resolveParams@ de su 'Context'), Drivers
-- (ídem) y TyreStrategy ('Handler.TyreStrategy.Helper').
--
-- TyreStrategy es la primera de las tres áreas que quedaban sin suite (siguen sin
-- ella 'Handler.Live.Helper' y 'Handler.OpenF1.Helper'), y entra
-- por la puerta de al lado: es también la primera que se prueba __contra dos
-- respuestas a la vez__, porque su función pura cruza @/stints@ con @/drivers@.
--
-- Un caso no encaja en ese reparto y es deliberado: la __coherencia entre los
-- dummies__ de Drivers y Comparison. No prueba una función sino un acuerdo entre
-- dos áreas —que la parrilla de respaldo contenga los coches que la comparación
-- de respaldo pinta—, y sin él nada impide que un cambio en un dummy deje al
-- widget de mañana enseñando una lista que no contiene lo que está dibujando.
--
-- Cubre además __tres__ módulos de @common@ que no son del backend, y por la misma
-- razón: viven allí precisamente para que esta suite los alcance, ya que el
-- paquete @frontend@ no tiene ninguna (2026-08-04).
--
-- * 'Common.Chart' — el escalado del gráfico de comparación.
-- * 'Common.Format' — el formateo de cifras de las tablas de Historical y Telemetry
--   (2026-08-26). Tercero por la misma puerta, y el que más
--   claramente es presentación: sin esta suite, que una celda no muestre
--   @\"1.0e-2\"@ estaría solo revisado a ojo.
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
import           Common.Format               (formatFixed, formatTrimmed, noData)
import           Common.Layout               (canvasSpan, clampToMin, fitsAt,
                                              gridDivisions, minWidthFor,
                                              overlaps, snapTo)
import           Common.Route                (comparisonPathFor, driversParam,
                                              driversPathFor)
import           Common.Types                (DriverEntry (..),
                                              DriverStatus (..),
                                              HistoricalStat (..),
                                              LapComparison (..),
                                              LiveTimingRow (..),
                                              StatEntity (..),
                                              TelemetryPoint (..),
                                              TyreStint (..),
                                              WidgetConfig (..), WidgetId (..),
                                              WidgetType (..), noParams,
                                              statusLabel)
import           Data.Aeson                  (eitherDecodeStrict)
import           Data.ByteString             (ByteString)
import qualified Data.ByteString.Char8       as BC
import           Data.List                   (nub)
import qualified Data.Text                   as T
import qualified Handler.Comparison.Context  as Comparison
import           Handler.Comparison.Helper   (RawComparison, assembleComparison)
import qualified Handler.Drivers.Context     as Drivers
import           Handler.Drivers.Helper      (RawDriver, assembleDrivers)
import           Handler.Historical.Helper   (Root, assembleConstructorStats,
                                              assembleStats, parseNum)
import           Handler.Live.Helper         (Of1Interval, Of1Lap, Of1Position,
                                              Of1Result, assembleRows)
import           Handler.OpenF1.Helper       (Of1Driver)
import qualified Handler.Telemetry.Context   as Telemetry
import           Handler.Telemetry.Helper    (FastF1Point, assemblePoints)
import           Handler.TyreStrategy.Helper (Of1Stint, assembleStints)
import           Outcome                     (Rejection (..), rejectionFor)
import           Test.Hspec
import           Test.Hspec.QuickCheck     (prop)
import           Test.QuickCheck           (Property, (.&&.), (===))

main :: IO ()
main = hspec $ do
  describe "assembleStats" $ do
    it "emite una fila por piloto, en el orden de la clasificación y con la identidad completa" $
      driverStatsOf driverStandings
        `shouldBe`
          [ HistoricalStat DriverStat "VER" "Max" "Verstappen" 393 (Just 9)
          , HistoricalStat DriverStat "NOR" "Lando" "Norris" 331 (Just 3)
          ]

    -- Las dos métricas dejaron de descartarse igual el 2026-08-24: con una fila
    -- por entidad, `points` ilegible no tiene dónde caerse solo.
    it "descarta al piloto entero cuando `points` no parsea, aunque `wins` sí" $
      driverStatsOf unparseablePoints `shouldBe` []

    it "conserva al piloto con hsWins en Nothing cuando `wins` no parsea" $
      driverStatsOf unparseableWins
        `shouldBe` [HistoricalStat DriverStat "HAM" "Lewis" "Hamilton" 183 Nothing]

    it "usa el apellido como código cuando Jolpica omite `code`" $
      driverStatsOf driverWithoutCode
        `shouldBe` [HistoricalStat DriverStat "Bortoleto" "Gabriel" "Bortoleto" 12 (Just 0)]

    it "deja hsWins en Nothing cuando Jolpica no publica `wins`" $
      driverStatsOf driverWithoutWins
        `shouldBe` [HistoricalStat DriverStat "ALO" "Fernando" "Alonso" 24 Nothing]

    it "devuelve [] cuando la respuesta no trae la clave DriverStandings" $
      driverStatsOf standingsListWithoutKeys `shouldBe` []

    it "ignora la clasificación de constructores" $
      driverStatsOf constructorStandings `shouldBe` []

  describe "assembleConstructorStats" $ do
    it "emite una fila por constructor, con `constructorId` en hsCode y `name` en hsFamilyName" $
      constructorStatsOf constructorStandings
        `shouldBe`
          [ HistoricalStat ConstructorStat "red_bull" "" "Red Bull" 712 (Just 12)
          , HistoricalStat ConstructorStat "mclaren" "" "McLaren" 640 (Just 9)
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

  describe "Outcome.rejectionFor" $ do
    -- La parte pura del discriminador 400/503. Los cuerpos son los que el
    -- microservicio emite de verdad, copiados de la medición del 2026-08-14: el
    -- `detail` de FastAPI viaja en UTF-8 y con acentos, que es justo lo que un
    -- `show` del ByteString destrozaría.
    it "un 400 es culpa del cliente y conserva el detail del servicio" $
      rejectionFor 400 "{\"detail\":\"drivers debe ser exactamente dos n\195\186meros de coche\"}"
        `shouldBe` Just (BadRequest "drivers debe ser exactamente dos números de coche")

    it "un 404 es su propio caso y no un 400 con otro texto" $
      rejectionFor 404 "{\"detail\":\"sesi\195\179n no resoluble (2026, 99, R)\"}"
        `shouldBe` Just (NotFound "sesión no resoluble (2026, 99, R)")

    it "un 5xx no es culpa del cliente: vuelve a la escalera de degradado" $ do
      -- La invariante que protege el arreglo de cometer la confusión al revés.
      rejectionFor 500 "{\"detail\":\"boom\"}" `shouldBe` Nothing
      rejectionFor 503 "" `shouldBe` Nothing

    it "un 2xx tampoco se clasifica, aunque traiga detail" $
      rejectionFor 200 "{\"detail\":\"no\"}" `shouldBe` Nothing

    it "un cuerpo sin detail o que no es JSON se sirve entero, sin explotar" $ do
      -- Un mensaje feo del servicio informa más que uno bonito inventado aquí.
      rejectionFor 400 "Bad Request" `shouldBe` Just (BadRequest "Bad Request")
      rejectionFor 400 "{\"error\":\"otra forma\"}"
        `shouldBe` Just (BadRequest "{\"error\":\"otra forma\"}")

    it "un cuerpo vacío cae al respaldo en vez de a un texto en blanco" $ do
      rejectionFor 400 "" `shouldBe` Just (BadRequest "petición mal formada")
      rejectionFor 404 "   " `shouldBe` Just (NotFound "el recurso no existe")

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

  -- Primera cobertura del área TyreStrategy, y la única función del repo que
  -- cruza __dos__ respuestas: los stints traen
  -- `driver_number` y el acrónimo que el widget pinta solo está en `/drivers`.
  --
  -- El caso del `compound: null` __no reproduce dato de hoy__: medido el
  -- 2026-08-25 sobre 2268 stints de 44 sesiones, OpenF1 no emite un solo nulo en
  -- los cuatro campos consumidos. El nulo vive en la sesión __en curso__ (un stint
  -- empezado antes de que se publique su compuesto), que es donde se observó el
  -- 2026-08-19 —1 de 67— y donde no se puede volver a capturar a voluntad. Este
  -- fixture es, por tanto, la única forma de ejercitar la rama
  -- (2026-08-25).
  describe "assembleStints" $ do
    it "cruza los stints con la parrilla y ordena por acrónimo y vuelta de inicio" $
      -- El orden que llega es por piloto y luego por `stint_number`; el que sale
      -- es alfabético por acrónimo. LEC antes que NOR aunque el coche 1 venga
      -- primero en las dos respuestas.
      stintsOf openF1Grid stintArray
        `shouldBe`
          [ TyreStint "LEC" "SOFT" 1 2
          , TyreStint "LEC" "MEDIUM" 22 43
          , TyreStint "NOR" "MEDIUM" 1 2
          , TyreStint "NOR" "SOFT" 3 21
          ]

    it "omite el stint sin compuesto y conserva los demás del mismo piloto" $
      -- La invariante del 2026-08-25, y la diferencia entre omitir un stint y
      -- tumbar el arreglo: con `o .: \"compound\"` sobre Text este fixture no
      -- decodificaba, `stintsOf` moría en el `error` y en producción el área
      -- entera degradaba al dummy con la red viva.
      stintsOf openF1Grid stintWithNullCompound
        `shouldBe`
          [ TyreStint "NOR" "MEDIUM" 1 2
          , TyreStint "NOR" "HARD" 22 47
          ]

    it "trata la clave `compound` ausente igual que el nulo" $
      -- OpenF1 la emite siempre (2268 de 2268), así que esto protege el decode
      -- ante un cambio de contrato, no ante un dato visto. Con `.:?` las dos
      -- formas del no-dato entran por la misma rama.
      stintsOf openF1Grid stintWithoutCompoundKey `shouldBe` []

    it "omite el stint cuyo piloto no aparece en la parrilla" $
      -- Comportamiento vivo desde el 2026-08-11 y hasta ahora sin prueba. Es el otro
      -- descarte que comparte el `Maybe` del bloque `do`.
      stintsOf openF1Grid stintOfUnknownDriver
        `shouldBe` [TyreStint "NOR" "MEDIUM" 1 2]

    it "devuelve [] cuando la parrilla llega vacía, aunque haya stints" $
      -- No es simétrico del anterior por casualidad: sin parrilla no hay acrónimo
      -- que poner en `tsDriver`, así que ningún stint resuelve. Es este [] el que
      -- hace que el Context caiga a cache/dummy en vez de servir una tabla vacía.
      stintsOf emptyArray stintArray `shouldBe` []

    it "devuelve [] sobre una sesión sin stints publicados" $
      stintsOf openF1Grid emptyArray `shouldBe` []

  -- Segunda de las tres áreas que quedaban sin suite (queda
  -- 'Handler.OpenF1.Helper'), y la que más cruza del repo: __cinco__
  -- respuestas donde `assembleStints` cruzaba dos. De ahí que `rowsOf` tome cinco
  -- fixtures.
  --
  -- El motivo son los DNF, y la medición previa corrigió la premisa de partida
  -- antes de escribir esto. Medido sobre la sesión 11353:
  --
  --   * @\/session_result@ trae 6 DNF sobre 22 filas, y __uno de ellos (coche 23)
  --     tiene @position@__ — por eso el estado es campo propio y no la ausencia de
  --     posición.
  --   * @\/position@ publica los __22__ coches, abandonos incluidos, así que la
  --     rama de omisión de `assembleRows` __no se alcanza con dato real__ y solo la
  --     ejercita el fixture de aquí. Es la segunda vez que pasa (la del @compound@
  --     nulo, arriba, es la primera).
  --   * De los 26 nulos de la respuesta (@duration@ ×15, @gap_to_leader@ ×6,
  --     @position@ ×5) __ninguno__ toca el decode, porque 'Of1Result' modela solo
  --     los cuatro campos que se consumen.
  describe "assembleRows" $ do
    it "cruza las cinco respuestas y ordena por posición" $
      -- El orden que llega es el de `/drivers` (coche 1 primero); el que sale es
      -- por posición, así que LEC (P1) va antes que NOR (P2). Y de las dos
      -- muestras por coche de `/position` e `/intervals` se toma la última por
      -- `date`, no la primera.
      rowsOf openF1Grid positionArray intervalArray lapArray resultArray
        `shouldBe`
          [ LiveTimingRow 1 "LEC" "Ferrari" "LEADER" "-" "1:15.265" Running
          , LiveTimingRow 2 "NOR" "McLaren" "+2.310" "+2.310" "1:16.001" Running
          ]

    it "marca el DNF que sí trae posición, y la fila sigue en la tabla" $
      -- El caso medido del coche 23, y el que justifica que 'ltStatus' exista: la
      -- fila __no__ desaparece ni cambia de sitio, solo gana la marca. Sus gap e
      -- intervalo siguen siendo los de su última muestra, que es exactamente el
      -- dato engañoso que la marca contextualiza.
      rowsOf openF1Grid positionArray intervalArray lapArray resultWithDnf
        `shouldBe`
          [ LiveTimingRow 1 "LEC" "Ferrari" "LEADER" "-" "1:15.265" Running
          , LiveTimingRow 2 "NOR" "McLaren" "+2.310" "+2.310" "1:16.001" Dnf
          ]

    it "sirve la tabla entera como Running si `/session_result` llega vacía" $
      -- Degradado __parcial__, y es la única de las cinco respuestas cuya ausencia
      -- no pierde filas: sin clasificación no hay marcas, pero la tabla sin marcas
      -- sigue siendo la tabla. No lo decide `assembleRows` sino el `maybe Running`
      -- del cruce.
      map ltStatus (rowsOf openF1Grid positionArray intervalArray lapArray emptyArray)
        `shouldBe` [Running, Running]

    it "trata las tres banderas ausentes como Running en vez de tumbar el decode" $
      -- OpenF1 las emite siempre (22 de 22 en la 11353), así que esto protege el
      -- decode ante un cambio de contrato, no ante un dato visto. Con `.:` este
      -- fixture no decodificaría, `rowsOf` moriría en el `error` y en producción
      -- `/api/live` entera degradaría al dummy con la red viva.
      map ltStatus (rowsOf openF1Grid positionArray intervalArray lapArray resultWithoutFlagKeys)
        `shouldBe` [Running, Running]

    it "da DSQ cuando la descalificación y el abandono llegan juntos" $
      -- La prioridad de 'statusOf', que es una decisión y no un detalle: las tres
      -- banderas son independientes en el contrato y nada impide que lleguen dos.
      -- No se ha observado el caso; se fija para que no lo decida el orden de los
      -- guardas por accidente.
      map ltStatus (rowsOf openF1Grid positionArray intervalArray lapArray resultDsqAndDnf)
        `shouldBe` [Running, Dsq]

    it "da DNS al piloto que no tomó la salida" $
      -- La tercera bandera. Cero casos en las cuatro sesiones medidas, así que el
      -- fixture es la única forma de ejercitarla.
      map ltStatus (rowsOf openF1Grid positionArray intervalArray lapArray resultWithDns)
        `shouldBe` [Running, Dns]

    it "omite al piloto sin posición aunque tenga intervalo, vuelta y estado" $
      -- La rama que se creía culpable de hacer desaparecer a los abandonos, y que
      -- la medición del 2026-08-27 desmintió: `/position` publica los 22 coches. Se
      -- prueba aquí porque el dato de hoy no la alcanza y vive para la sesión __en
      -- curso__, donde un coche puede no tener posición publicada todavía.
      rowsOf openF1Grid positionOfLecOnly intervalArray lapArray resultWithDnf
        `shouldBe` [LiveTimingRow 1 "LEC" "Ferrari" "LEADER" "-" "1:15.265" Running]

    it "devuelve [] cuando la parrilla llega vacía, aunque haya posiciones" $
      -- Simétrico del caso de 'assembleStints': la unidad de la fila es el piloto
      -- de `/drivers`, así que sin parrilla no hay nada que ensamblar. Es este []
      -- el que hace que el Context caiga a cache/dummy.
      rowsOf emptyArray positionArray intervalArray lapArray resultArray `shouldBe` []

    it "pone `-` en el gap nulo del piloto que no es líder" $
      -- La rama `gapText Null`, viva desde el 2026-08-04 y hasta ahora sin prueba. Los
      -- 6 nulos de `gap_to_leader` medidos en la 11353 son de abandonos, así que
      -- este caso y el del DNF describen la misma fila desde dos lados.
      map (\r -> (ltGap r, ltInterval r))
          (rowsOf openF1Grid positionArray intervalWithNullGap lapArray resultArray)
        `shouldBe` [("LEADER", "-"), ("-", "-")]

    it "trata el gap ausente igual que el nulo en vez de tumbar el arreglo" $
      -- El endurecimiento del 2026-08-27, y el sexto no-dato por esta puerta.
      -- Con `o .: \"gap_to_leader\"` este fixture __no decodifica__ y se pierde la
      -- tabla entera, no solo la celda: OpenF1 la emite hoy siempre, así que la
      -- prueba es del contrato y no de un dato visto.
      map (\r -> (ltGap r, ltInterval r))
          (rowsOf openF1Grid positionArray intervalWithoutGapKeys lapArray resultArray)
        `shouldBe` [("LEADER", "-"), ("-", "-")]

    it "ignora las vueltas sin cronometrar al elegir la última" $
      -- `/laps` publica `lap_duration: null` en las out/in laps, y la última vuelta
      -- del piloto no es la última fila sino la última __cronometrada__. Sin el
      -- filtro, NOR mostraría la raya de una in-lap teniendo tiempo de la anterior.
      map ltLastLap (rowsOf openF1Grid positionArray intervalArray lapWithNullDuration resultArray)
        `shouldBe` ["1:15.265", "1:16.001"]

    it "pone `-` en la última vuelta del piloto sin ninguna cronometrada" $
      -- El coche que abandonó en la vuelta 0 (el 3 de la 11353): está en la
      -- parrilla y en `/position`, pero no tiene una sola vuelta buena.
      map ltLastLap (rowsOf openF1Grid positionArray intervalArray emptyArray resultArray)
        `shouldBe` ["-", "-"]

  -- Vive en `common` y no en el widget justamente para poder probarse aquí: el
  -- paquete `frontend` no tiene suite, así que sin esta mudanza la única cobertura
  -- de las etiquetas sería mirar la página.
  describe "statusLabel" $ do
    it "da la sigla de las tres marcas" $
      map statusLabel [Dnf, Dns, Dsq] `shouldBe` ["DNF", "DNS", "DSQ"]

    it "deja en blanco al piloto sin incidencia, y no la raya de `noData`" $
      -- La raya significa «nadie dio esta cifra»; aquí el estado __se sabe__ y es
      -- que no hay nada que señalar. En blanco, para que las tres marcas destaquen
      -- en una columna de 22 filas.
      statusLabel Running `shouldBe` ""

    it "no repite etiqueta entre estados distintos" $
      -- Dos estados con la misma sigla serían indistinguibles en la tabla, que es
      -- el defecto que este módulo existe para cerrar.
      let labels = map statusLabel [Running, Dnf, Dns, Dsq]
       in length (nub labels) `shouldBe` length labels

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
      let xs = map fst (deltaPoints [0.0, -0.048, 0.081, 0.167])
      head xs `shouldBe` chartPad
      last xs `shouldBe` chartWidth - chartPad

    it "emite `points` con coordenadas enteras, sin notación científica" $
      deltaPolyline [0, 0, 0] `shouldBe` "10,100 300,100 590,100"

    prop "ninguna coordenada se sale del viewBox" staysInsideViewBox

  -- El formateo de cifras vive en `common` por la misma razón que el escalado del
  -- gráfico: es lógica de presentación de dos widgets y el paquete `frontend` no
  -- tiene suite (2026-08-04 y 2026-08-26). Los casos son los
  -- que motivaron el módulo, medidos contra los endpoints el 2026-08-26, más los
  -- límites del recorte.
  describe "Common.Format" $ do
    it "quita el `.0` que sobra en los puntos de la clasificación" $ do
      formatTrimmed 1 393.0 `shouldBe` "393"
      formatTrimmed 1 712.0 `shouldBe` "712"

    it "conserva el medio punto, que es el motivo de que los puntos sean Double" $
      formatTrimmed 1 393.5 `shouldBe` "393.5"

    it "no emite notación científica, que es lo que `show` hacía con `throttle`" $ do
      -- `show (1.0e-2 :: Double)` == "1.0e-2", y la respuesta real de
      -- /api/telemetry trae ese valor: la celda mostraba la cadena literal.
      formatFixed 2 1.0e-2 `shouldBe` "0.01"
      formatFixed 2 3.0e-2 `shouldBe` "0.03"

    it "acorta la distancia de 17 dígitos que ensanchaba la tabla de telemetría" $
      -- El `overflow-x` de la tabla de telemetría, en su causa medida.
      formatFixed 1 5.936944444444445 `shouldBe` "5.9"

    it "redondea half-to-even, que es lo que `showFFloat` de base hace" $ do
      -- Medido, no supuesto: 1.5 sube pero 2.5 NO. Un test escrito de memoria
      -- contra el redondeo "de colegio" fallaría aquí, y es la razón de fijarlo.
      formatFixed 0 1.5 `shouldBe` "2"
      formatFixed 0 2.5 `shouldBe` "2"
      formatFixed 0 0.5 `shouldBe` "0"
      formatFixed 0 (-1.5) `shouldBe` "-2"

    it "con 0 decimales no deja el punto colgando" $ do
      formatFixed 0 393.0 `shouldBe` "393"
      formatTrimmed 0 393.0 `shouldBe` "393"

    it "protege los ceros de la parte entera del recorte" $ do
      -- El fallo obvio de implementar el recorte con un solo `dropWhileEnd '0'`.
      formatTrimmed 2 100.0 `shouldBe` "100"
      formatTrimmed 2 1000.0 `shouldBe` "1000"
      formatTrimmed 2 10.5 `shouldBe` "10.5"

    it "el cero es `0` y el cero negativo también" $ do
      formatFixed 2 0.0 `shouldBe` "0.00"
      formatTrimmed 2 0.0 `shouldBe` "0"
      formatTrimmed 2 (-0.0) `shouldBe` "0"

    it "los decimales negativos se tratan como cero, no como error" $
      formatFixed (-3) 393.4 `shouldBe` "393"

    it "el no-dato da la raya y no una palabra inglesa en una celda de cifras" $ do
      -- Quinto no-dato por esta clase de puerta; el NaN de 2026-07-31 venía de
      -- FastF1, que es la fuente de TelemetryPoint.
      formatFixed 1 (0 / 0) `shouldBe` noData
      formatFixed 1 (1 / 0) `shouldBe` noData
      formatTrimmed 1 (-1 / 0) `shouldBe` noData

    it "`brake` es un booleano metido en un Double y se lee como 0 o 1" $ do
      -- Medido: los 71 puntos reales traen solo esos dos valores.
      formatFixed 0 0.0 `shouldBe` "0"
      formatFixed 0 1.0 `shouldBe` "1"

    prop "formatFixed nunca emite notación científica" neverScientific
    prop "formatTrimmed no deja cola de ceros ni punto suelto" trimLeavesNoTail

  -- La aritmética del lienzo libre (2026-09-03), cuarto
  -- módulo de `common` que llega aquí por la puerta del 2026-08-04: el paquete
  -- `frontend` no tiene suite. Aprieta más que los tres anteriores, porque su
  -- consumidor —`Pages.Dashboard`— solo compila bajo GHCJS, así que un error suyo
  -- no aparecería hasta el build completo.
  describe "snapTo" $ do
    it "pega a la celda más cercana, y con 24 divisiones el paso es 5 exacto" $ do
      snapTo gridDivisions 0 `shouldBe` 0
      snapTo gridDivisions 2 `shouldBe` 0
      snapTo gridDivisions 3 `shouldBe` 5
      snapTo gridDivisions 63 `shouldBe` 65
      snapTo gridDivisions canvasSpan `shouldBe` canvasSpan

    it "recorta al lienzo la coordenada que se sale por cualquiera de los dos lados" $ do
      snapTo gridDivisions (-40) `shouldBe` 0
      snapTo gridDivisions 500 `shouldBe` canvasSpan

    -- El imán apagado no es un error ni pide un camino aparte en el consumidor:
    -- es el estado que el interruptor del 2026-09-03 tiene que poder producir.
    it "con divisiones <= 0 el imán está apagado y solo recorta" $ do
      snapTo 0 63 `shouldBe` 63
      snapTo (-1) 63 `shouldBe` 63
      snapTo 0 500 `shouldBe` canvasSpan

    it "las proporciones que el 2026-09-04 promete caen en celda" $ do
      -- Mitad, tercio, cuarto y sexto. El quinto (24) es exacto como número pero
      -- NO cae en celda, que es el resto vivo del riesgo «24 no divide entre 5».
      map (snapTo gridDivisions) [60, 40, 30, 20] `shouldBe` [60, 40, 30, 20]
      snapTo gridDivisions 24 `shouldBe` 25

    prop "es idempotente: pegar algo ya pegado no lo mueve" snapIsIdempotent
    prop "el resultado nunca sale del lienzo" snapStaysInCanvas

  describe "clampToMin" $ do
    it "sube al mínimo el widget demasiado estrecho para su contenido" $
      wcW (clampToMin (rect LiveTiming (0, 0, 12, 40))) `shouldBe` minWidthFor LiveTiming

    it "deja intacto al que ya cumple, sin redondear ni pegar a la rejilla" $
      clampToMin (rect Telemetry (7, 3, 63, 41)) `shouldBe` rect Telemetry (7, 3, 63, 41)

    -- El caso que fija el reparto del 2026-09-04 (c). Si esta función moviera el
    -- widget, `fitsAt` no tendría nunca nada que decir sobre un layout saneado y
    -- la marca visible no aparecería jamás.
    it "no mueve nada nunca, ni cuando el widget se sale por la derecha" $ do
      let w = clampToMin (rect LiveTiming (100, 10, 45, 40))
      wcX w `shouldBe` 100
      wcY w `shouldBe` 10
      wcH w `shouldBe` 40

    it "tampoco recorta al que se sale: ensanchar es todo lo que hace" $
      wcW (clampToMin (rect Custom (0, 0, 200, 10))) `shouldBe` 200

    prop "sube siempre al mínimo del tipo, sea cual sea la entrada" clampReachesMin

  describe "fitsAt" $ do
    it "acepta al widget que cabe donde dice estar" $
      fitsAt (rect LiveTiming (0, 0, 60, 90)) `shouldBe` True

    it "rechaza al que se sale por la derecha, que es lo que enciende la marca" $
      fitsAt (rect LiveTiming (100, 0, 55, 40)) `shouldBe` False

    it "rechaza al que baja de su ancho mínimo" $
      fitsAt (rect LiveTiming (0, 0, 20, 40)) `shouldBe` False

    it "rechaza la coordenada negativa" $
      fitsAt (rect LiveTiming (-5, 0, 60, 40)) `shouldBe` False

    -- Deliberado, no descuido: por el 2026-09-03 (d) encoger el alto se resuelve
    -- con el scroll vertical que la tarjeta tiene desde el 2026-08-21, así que a
    -- lo alto no hay nada que avisar.
    it "no mira el eje vertical: un widget que se sale por abajo sí cabe" $
      fitsAt (rect LiveTiming (0, 100, 60, 90)) `shouldBe` True

  describe "overlaps" $ do
    it "dos widgets separados no se enciman" $
      overlaps (rect LiveTiming (0, 0, 50, 50)) (rect Telemetry (60, 60, 50, 50))
        `shouldBe` False

    -- El caso que el grupo acoplado del 2026-09-03 (b) produce constantemente:
    -- dentro de un grupo el borde entre dos miembros ES un separador compartido.
    it "el borde compartido no es solape" $ do
      overlaps (rect LiveTiming (0, 0, 60, 90)) (rect Telemetry (60, 0, 60, 35))
        `shouldBe` False
      overlaps (rect Telemetry (60, 0, 60, 35)) (rect Telemetry (60, 35, 60, 35))
        `shouldBe` False

    it "un solo píxel de invasión ya es solape" $
      overlaps (rect LiveTiming (0, 0, 61, 90)) (rect Telemetry (60, 0, 60, 35))
        `shouldBe` True

    it "un widget contenido en otro sí solapa, y no es un caso límite que esconder" $
      overlaps (rect LiveTiming (0, 0, 120, 120)) (rect Custom (10, 10, 20, 20))
        `shouldBe` True

    it "un widget solapa consigo mismo" $
      overlaps (rect LiveTiming (0, 0, 60, 90)) (rect LiveTiming (0, 0, 60, 90))
        `shouldBe` True

    prop "es simétrica" overlapIsSymmetric

  -- __El caso que más vale de todo el bloque.__ Los siete rectángulos de
  -- `Pages.Dashboard` están escritos a mano y un typo NO lo caza el compilador —
  -- mismo riesgo que los `WidgetId` literales del 2026-09-01, con la misma
  -- consecuencia: se nota al mirar la página, no al compilar.
  --
  -- __Los layouts son una COPIA__ y esa es su debilidad: `frontend` no está en
  -- `cabal.project`, así que la suite no puede importar los de verdad. Si alguien
  -- toca las coordenadas de `Pages.Dashboard` y no toca estas, el test seguirá
  -- verde midiendo un layout que ya no existe. Mientras sea copia, hay que
  -- cambiar los dos sitios.
  describe "los layouts fijos de Pages.Dashboard" $ do
    it "los siete widgets caben donde dicen estar" $
      filter (not . fitsAt) (raceOverviewFixture <> qualyFixture) `shouldBe` []

    it "clampToMin no cambia ninguno: los siete respetan ya su ancho mínimo" $
      map clampToMin (raceOverviewFixture <> qualyFixture)
        `shouldBe` (raceOverviewFixture <> qualyFixture)

    it "ningún par de Race Overview se encima" $
      [ (widgetId a, widgetId b)
      | (i, a) <- zip [0 :: Int ..] raceOverviewFixture
      , (j, b) <- zip [0 :: Int ..] raceOverviewFixture
      , i < j
      , overlaps a b
      ] `shouldBe` []

    -- El hueco de 60,85 a 120,90 es deliberado (los huecos son legales desde el
    -- 2026-09-03) y existe para comprobar al encender el render que el lienzo NO
    -- lo rellena solo. Si desaparece de `Pages.Dashboard`, esa comprobación se
    -- pierde en silencio.
    it "Race Overview deja libre el hueco de debajo de lap-comparison" $
      filter (overlaps (rect Custom (60, 85, 60, 5))) raceOverviewFixture
        `shouldBe` []

    it "las coordenadas caen todas en celda del imán" $
      let coords w = [wcX w, wcY w, wcW w, wcH w]
       in filter ((/= 0) . (`mod` 5)) (concatMap coords (raceOverviewFixture <> qualyFixture))
            `shouldBe` []

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

-- | El invariante que hace usable al imán, y el que no se ve mirando: pegar algo
-- ya pegado no lo mueve. Sin él, arrastrar dos veces desplazaría el widget sin
-- que el usuario lo pida.
--
-- Va sobre __cualquier__ número de divisiones y no solo sobre las que dividen a
-- 120, porque el doble redondeo —a celda, y de vuelta a unidades— es justamente
-- donde podría perderse: 24 no divide entre 5 ni entre 7 (riesgo escrito el
-- 2026-09-03), así que esas rejillas tienen paso no entero.
snapIsIdempotent :: Int -> Int -> Property
snapIsIdempotent d v = snapTo d (snapTo d v) === snapTo d v

-- | El imán nunca escupe una coordenada fuera del lienzo, ni siquiera partiendo
-- de una que ya lo estaba.
snapStaysInCanvas :: Int -> Int -> Property
snapStaysInCanvas d v = r >= 0 .&&. r <= canvasSpan
  where r = snapTo d v

-- | Tras 'clampToMin' el ancho cumple el mínimo del tipo, venga como venga la
-- entrada. Es la garantía entera de la función; lo que NO garantiza —que el
-- widget quepa— es de 'fitsAt' (2026-09-04 c).
clampReachesMin :: Int -> Int -> Int -> Int -> Bool
clampReachesMin x y w h =
  wcW (clampToMin r) >= minWidthFor (widgetType r)
  where r = rect LiveTiming (x, y, w, h)

-- | Que A se encime con B y que B se encime con A son la misma pregunta. Si no lo
-- fueran, el resultado dependería del orden de la lista de widgets — que es
-- exactamente lo que el lienzo libre dejó de significar.
overlapIsSymmetric :: Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Property
overlapIsSymmetric ax ay aw ah bx by bw bh = overlaps a b === overlaps b a
  where
    a = rect LiveTiming (ax, ay, aw, ah)
    b = rect Telemetry (bx, by, bw, bh)

-- * Helpers

-- | 'WidgetConfig' de usar y tirar con un rectángulo dado. El 'WidgetId' se
-- deriva del tipo y de la posición porque aquí no se prueba la identidad; para
-- los layouts fijos, 'rectNamed' pone el id de verdad.
rect :: WidgetType -> (Int, Int, Int, Int) -> WidgetConfig
rect = rectNamed "w"

-- | Espejo de 'rect' con el 'WidgetId' explícito, para que los fallos del bloque
-- de los layouts fijos digan __qué widget__ y no «el tercero».
rectNamed :: T.Text -> WidgetType -> (Int, Int, Int, Int) -> WidgetConfig
rectNamed wid wt (x, y, w, h) = WidgetConfig
  { widgetId      = WidgetId wid
  , widgetType    = wt
  , params        = noParams
  , widgetVisible = True
  , widgetGroup   = Nothing
  , wcX           = x
  , wcY           = y
  , wcW           = w
  , wcH           = h
  }

-- | __Copia__ de @Pages.Dashboard.raceOverview@, y no el valor de verdad: el
-- paquete @frontend@ no está en @cabal.project@ y solo se construye con GHCJS, así
-- que esta suite no puede importarlo.
--
-- __Es deuda, y conviene decirlo aquí donde se ve:__ si las coordenadas cambian
-- allí y no aquí, estos casos siguen verdes midiendo un layout que ya no existe.
-- Se acepta porque la alternativa —no probarlos— deja los siete rectángulos
-- escritos a mano sin nada que cace un typo, que es el riesgo que este bloque
-- existe para cubrir.
raceOverviewFixture :: [WidgetConfig]
raceOverviewFixture =
  [ rectNamed "live-timing"       LiveTiming       (  0,  0, 60, 90)
  , rectNamed "telemetry"         Telemetry        ( 60,  0, 60, 35)
  , rectNamed "telemetry-2"       Telemetry        ( 60, 35, 60, 35)
  , rectNamed "lap-comparison"    LapComparison    ( 60, 70, 60, 15)
  , rectNamed "driver-stats"      HistoricalStats  (  0, 90, 60, 30)
  , rectNamed "constructor-stats" ConstructorStats ( 60, 90, 60, 30)
  ]

-- | Copia de @Pages.Dashboard.qualy@, con la misma advertencia que
-- 'raceOverviewFixture'. Es el caso límite del rectángulo: el lienzo entero.
qualyFixture :: [WidgetConfig]
qualyFixture = [rectNamed "qualy-live-timing" LiveTiming (0, 0, 120, 120)]

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

-- | Espejo de 'driversOf' para el área TyreStrategy, con __dos__ fixtures en vez
-- de uno: 'assembleStints' es la única función pura del repo que cruza dos
-- respuestas, así que el par decode + ensamblado hay que cerrarlo por los dos
-- lados. Que el fallo de un fixture aborte (mismo criterio que 'decodeRoot') es lo
-- que hace visible la regresión que esta suite existe para impedir: con
-- @o .: \"compound\"@ el fixture del nulo __no decodifica__, y degradarlo a @[]@
-- pondría verde el caso por la razón contraria a la que se está probando.
stintsOf :: ByteString -> ByteString -> [TyreStint]
stintsOf grid stints = assembleStints (decodeOf1Drivers grid) (decodeStints stints)

decodeOf1Drivers :: ByteString -> [Of1Driver]
decodeOf1Drivers raw =
  either (error . ("fixture no decodificable: " <>)) id (eitherDecodeStrict raw)

decodeStints :: ByteString -> [Of1Stint]
decodeStints raw =
  either (error . ("fixture no decodificable: " <>)) id (eitherDecodeStrict raw)

-- | Espejo de 'stintsOf' para el área Live, con __cinco__ fixtures: 'assembleRows'
-- es la función del repo que más respuestas cruza. El criterio de abortar ante un
-- fixture no decodificable es el mismo de 'stintsOf' y por la misma razón, que aquí
-- se cobra dos veces: con @o .: \"gap_to_leader\"@ el fixture de la clave ausente
-- __no decodifica__, y con @o .: \"dnf\"@ tampoco el de las banderas ausentes.
-- Degradar cualquiera de los dos a @[]@ pondría verde el caso por la razón
-- contraria a la que se prueba.
rowsOf
  :: ByteString  -- ^ @\/drivers@
  -> ByteString  -- ^ @\/position@
  -> ByteString  -- ^ @\/intervals@
  -> ByteString  -- ^ @\/laps@
  -> ByteString  -- ^ @\/session_result@
  -> [LiveTimingRow]
rowsOf grid positions intervals laps results =
  assembleRows
    (decodeOf1Drivers grid)
    (decodePositions positions)
    (decodeIntervals intervals)
    (decodeLaps laps)
    (decodeResults results)

decodePositions :: ByteString -> [Of1Position]
decodePositions raw =
  either (error . ("fixture no decodificable: " <>)) id (eitherDecodeStrict raw)

decodeIntervals :: ByteString -> [Of1Interval]
decodeIntervals raw =
  either (error . ("fixture no decodificable: " <>)) id (eitherDecodeStrict raw)

decodeLaps :: ByteString -> [Of1Lap]
decodeLaps raw =
  either (error . ("fixture no decodificable: " <>)) id (eitherDecodeStrict raw)

decodeResults :: ByteString -> [Of1Result]
decodeResults raw =
  either (error . ("fixture no decodificable: " <>)) id (eitherDecodeStrict raw)

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

-- | @points@ no parseable con @wins@ bueno: desde 2026-08-24 cae la entrada
-- entera. La métrica obligatoria no tiene dónde degradar cuando la fila es la
-- entidad y no el KPI.
unparseablePoints :: ByteString
unparseablePoints =
  envelope $
    ",\"DriverStandings\":[{\"position\":\"5\",\"points\":\"n/a\",\"wins\":\"4\",\
    \\"Driver\":{\"driverId\":\"hamilton\",\"code\":\"HAM\",\
    \\"givenName\":\"Lewis\",\"familyName\":\"Hamilton\"}}]"

-- | El caso simétrico del anterior y el que justifica el 'Maybe' de @hsWins@:
-- @wins@ no parseable no se lleva por delante los puntos del piloto.
unparseableWins :: ByteString
unparseableWins =
  envelope $
    ",\"DriverStandings\":[{\"position\":\"5\",\"points\":\"183\",\"wins\":\"n/a\",\
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

-- | Entrada sin @wins@: el campo opcional degrada a 'Nothing' en su columna, no a
-- cero filas.
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

-- | Recorte de @GET \/drivers@ de __OpenF1__ (no de FastF1: es el otro
-- @\/drivers@, y de ahí el nombre) para la sesión 11353, con los dos coches que
-- los fixtures de stints usan. Lleva @broadcast_name@ y @team_colour@ a propósito,
-- que 'Of1Driver' no modela: la respuesta real trae once claves y el decode tiene
-- que ignorar las ocho que no consume.
openF1Grid :: ByteString
openF1Grid =
  "[{\"driver_number\":1,\"name_acronym\":\"NOR\",\"team_name\":\"McLaren\",\
  \\"broadcast_name\":\"L NORRIS\",\"team_colour\":\"F47600\"},\
  \{\"driver_number\":16,\"name_acronym\":\"LEC\",\"team_name\":\"Ferrari\",\
  \\"broadcast_name\":\"C LECLERC\",\"team_colour\":\"ED1131\"}]"

-- | Recorte de @GET \/stints@ de OpenF1 (sesión 11353, 2026-08-25): dos stints de
-- cada coche, __intercalados__ para que el orden de salida no pueda venir de
-- conservar el de entrada. Las ocho claves son las que OpenF1 emite; el tipo
-- consume cuatro.
stintArray :: ByteString
stintArray =
  "[" <> stint 1 1 1 2 "\"MEDIUM\""
    <> "," <> stint 16 1 1 2 "\"SOFT\""
    <> "," <> stint 1 2 3 21 "\"SOFT\""
    <> "," <> stint 16 3 22 43 "\"MEDIUM\""
    <> "]"

-- | Los tres stints reales del coche 1 con el compuesto del __segundo__ en
-- @null@. Es el fixture del 2026-08-25: el del medio se omite y los otros dos
-- sobreviven. Con @o .: \"compound\"@ sobre 'Text' no decodifica, que es
-- exactamente lo que hacía degradar @\/api\/tyre-strategy@ entera.
stintWithNullCompound :: ByteString
stintWithNullCompound =
  "[" <> stint 1 1 1 2 "\"MEDIUM\""
    <> "," <> stint 1 2 3 21 "null"
    <> "," <> stint 1 3 22 47 "\"HARD\""
    <> "]"

-- | La clave @compound@ __ausente__, no nula. OpenF1 la emite siempre (2268 de
-- 2268 medidos), así que esto protege el decode ante un cambio de contrato: con
-- @.:?@ las dos formas del no-dato entran por la misma rama y ninguna de las dos
-- tumba el arreglo.
stintWithoutCompoundKey :: ByteString
stintWithoutCompoundKey =
  "[{\"meeting_key\":1292,\"session_key\":11353,\"stint_number\":1,\
  \\"driver_number\":1,\"lap_start\":1,\"lap_end\":2,\"tyre_age_at_start\":0}]"

-- | Un stint del coche 1 y otro de un coche que no está en 'openF1Grid'. El 99 no
-- es arbitrario en su forma: un sustituto o un tercer coche en libres produce
-- exactamente esto cuando las dos respuestas no se piden en el mismo instante.
stintOfUnknownDriver :: ByteString
stintOfUnknownDriver =
  "[" <> stint 1 1 1 2 "\"MEDIUM\""
    <> "," <> stint 99 1 1 30 "\"HARD\""
    <> "]"

-- | Un objeto de @\/stints@ con las ocho claves de OpenF1. El compuesto entra
-- __ya serializado__ (@\"\\\"SOFT\\\"\"@ o @\"null\"@) porque es el campo cuya
-- forma se está probando: pasarlo como 'Text' impediría escribir el caso del nulo,
-- que es el motivo de este bloque.
stint :: Int -> Int -> Int -> Int -> ByteString -> ByteString
stint number stintNumber lapStart lapEnd compound =
  "{\"meeting_key\":1292,\"session_key\":11353"
    <> ",\"stint_number\":" <> num stintNumber
    <> ",\"driver_number\":" <> num number
    <> ",\"lap_start\":" <> num lapStart
    <> ",\"lap_end\":" <> num lapEnd
    <> ",\"compound\":" <> compound
    <> ",\"tyre_age_at_start\":0}"
  where
    num = BC.pack . show

-- ** Fixtures del área Live
--
-- Los cinco endpoints de 'assembleRows', con la forma real de la sesión 11353
-- medida el 2026-08-27. Los tres primeros son series temporales: llevan __dos__
-- muestras por coche a propósito, para que los casos ejerciten 'latestByDriver' y
-- no solo el cruce. Y la parrilla es 'openF1Grid' (coches 1\/NOR y 16\/LEC), que ya
-- existía para los stints: el coche 16 va en P1 y el 1 en P2 justamente para que
-- el orden de salida no coincida con el de llegada.

-- | Un objeto de @\/position@ con las cinco claves de OpenF1.
position :: Int -> Int -> ByteString -> ByteString
position number pos date =
  "{\"date\":\"" <> date <> "\",\"session_key\":11353"
    <> ",\"driver_number\":" <> BC.pack (show number)
    <> ",\"position\":" <> BC.pack (show pos)
    <> ",\"meeting_key\":1292}"

-- | Un objeto de @\/intervals@ con las seis claves. Gap e intervalo entran __ya
-- serializados__ por el mismo motivo que el compuesto en 'stint': su forma es lo
-- que se prueba, y OpenF1 los emite como número, cadena (@\"+1 LAP\"@) o @null@.
interval :: Int -> ByteString -> ByteString -> ByteString -> ByteString
interval number gap intv date =
  "{\"date\":\"" <> date <> "\",\"session_key\":11353"
    <> ",\"gap_to_leader\":" <> gap
    <> ",\"interval\":" <> intv
    <> ",\"driver_number\":" <> BC.pack (show number)
    <> ",\"meeting_key\":1292}"

-- | Igual que 'interval' pero __sin las dos claves de gap__, que es el fixture del
-- endurecimiento: OpenF1 las emite siempre, así que esta forma no se ha observado y
-- solo se puede construir a mano.
intervalNoGap :: Int -> ByteString -> ByteString
intervalNoGap number date =
  "{\"date\":\"" <> date <> "\",\"session_key\":11353"
    <> ",\"driver_number\":" <> BC.pack (show number)
    <> ",\"meeting_key\":1292}"

-- | Un objeto de @\/laps@ recortado a las claves que 'Of1Lap' consume más
-- @date_start@. La duración entra serializada para poder escribir el @null@ de las
-- out\/in laps, que es la rama del filtro de 'assembleRows'.
lap :: Int -> Int -> ByteString -> ByteString
lap number lapNum duration =
  "{\"meeting_key\":1292,\"session_key\":11353"
    <> ",\"driver_number\":" <> BC.pack (show number)
    <> ",\"lap_number\":" <> BC.pack (show lapNum)
    <> ",\"date_start\":\"2026-08-23T13:03:28.567000+00:00\""
    <> ",\"i1_speed\":290,\"is_pit_out_lap\":false"
    <> ",\"lap_duration\":" <> duration
    <> ",\"st_speed\":208}"

-- | Un objeto de @\/session_result@ con las __diez__ claves reales, de las que
-- 'Of1Result' consume cuatro. Lleva los seis campos que no modela —@position@,
-- @duration@ y @gap_to_leader@ entre ellos, los tres que la respuesta trae nulos—
-- porque el decode tiene que ignorarlos: es la misma razón por la que 'openF1Grid'
-- lleva @broadcast_name@.
result :: Int -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString
result number pos dnf dns dsq =
  "{\"position\":" <> pos
    <> ",\"driver_number\":" <> BC.pack (show number)
    <> ",\"number_of_laps\":72,\"points\":25.0"
    <> ",\"dnf\":" <> dnf
    <> ",\"dns\":" <> dns
    <> ",\"dsq\":" <> dsq
    <> ",\"duration\":7484.859,\"gap_to_leader\":0"
    <> ",\"meeting_key\":1292,\"session_key\":11353}"

-- | Igual que 'result' pero __sin las tres banderas__. Protege el decode ante un
-- cambio de contrato: OpenF1 las emite en las 22 filas medidas.
resultNoFlags :: Int -> ByteString -> ByteString
resultNoFlags number pos =
  "{\"position\":" <> pos
    <> ",\"driver_number\":" <> BC.pack (show number)
    <> ",\"number_of_laps\":72,\"points\":25.0"
    <> ",\"duration\":7484.859,\"gap_to_leader\":0"
    <> ",\"meeting_key\":1292,\"session_key\":11353}"

-- | Dos coches con dos muestras cada uno. La segunda muestra de cada uno es la que
-- gana por @date@, y le da al 16 la P1 y al 1 la P2 — invertidas respecto a la
-- primera, para que un caso que ignore 'latestByDriver' falle en vez de coincidir.
positionArray :: ByteString
positionArray =
  "[" <> position 1 1 "2026-08-23T12:06:50.962000+00:00"
    <> "," <> position 16 2 "2026-08-23T12:06:51.100000+00:00"
    <> "," <> position 1 2 "2026-08-23T13:20:10.000000+00:00"
    <> "," <> position 16 1 "2026-08-23T13:20:11.000000+00:00"
    <> "]"

-- | Solo el coche 16 tiene posición. El 1 está en la parrilla, en @\/intervals@, en
-- @\/laps@ y en la clasificación, así que es la rama de omisión aislada.
positionOfLecOnly :: ByteString
positionOfLecOnly =
  "[" <> position 16 1 "2026-08-23T13:20:11.000000+00:00" <> "]"

-- | Gaps del coche 1 (P2): la última muestra da @+2.310@. El 16 es líder, así que
-- 'assembleRows' le pone @"LEADER"@ y @"-"@ ignorando sus valores — de ahí que sus
-- números sean deliberadamente absurdos.
intervalArray :: ByteString
intervalArray =
  "[" <> interval 1 "0.0" "0.0" "2026-08-23T12:06:46.696000+00:00"
    <> "," <> interval 16 "9.999" "9.999" "2026-08-23T12:06:47.000000+00:00"
    <> "," <> interval 1 "2.31" "2.31" "2026-08-23T13:20:09.000000+00:00"
    <> "," <> interval 16 "0.0" "0.0" "2026-08-23T13:20:10.000000+00:00"
    <> "]"

-- | Los dos campos de gap a @null@ en la última muestra del coche 1. Es la forma
-- que las 6 filas nulas de la 11353 traen, y todas son de abandonos.
intervalWithNullGap :: ByteString
intervalWithNullGap =
  "[" <> interval 1 "2.31" "2.31" "2026-08-23T12:06:46.696000+00:00"
    <> "," <> interval 1 "null" "null" "2026-08-23T13:20:09.000000+00:00"
    <> "," <> interval 16 "0.0" "0.0" "2026-08-23T13:20:10.000000+00:00"
    <> "]"

-- | Las dos claves de gap __ausentes__ en el objeto del coche 1.
intervalWithoutGapKeys :: ByteString
intervalWithoutGapKeys =
  "[" <> intervalNoGap 1 "2026-08-23T13:20:09.000000+00:00"
    <> "," <> interval 16 "0.0" "0.0" "2026-08-23T13:20:10.000000+00:00"
    <> "]"

-- | Dos vueltas cronometradas por coche; gana la de número mayor.
lapArray :: ByteString
lapArray =
  "[" <> lap 1 1 "84.57"
    <> "," <> lap 16 1 "84.9"
    <> "," <> lap 1 2 "76.001"
    <> "," <> lap 16 2 "75.265"
    <> "]"

-- | La última vuelta de cada coche llega con @lap_duration: null@ (una in-lap), así
-- que la buena es la anterior. Sin el filtro de 'assembleRows' los dos mostrarían
-- la raya teniendo tiempo.
lapWithNullDuration :: ByteString
lapWithNullDuration =
  "[" <> lap 1 2 "76.001"
    <> "," <> lap 16 2 "75.265"
    <> "," <> lap 1 3 "null"
    <> "," <> lap 16 3 "null"
    <> "]"

-- | Clasificación sin incidencias: los dos coches con las tres banderas en @false@.
resultArray :: ByteString
resultArray =
  "[" <> result 16 "1" "false" "false" "false"
    <> "," <> result 1 "2" "false" "false" "false"
    <> "]"

-- | El caso medido del coche 23 de la 11353, trasplantado al coche 1: @dnf: true@
-- __con__ @position@. Es el que hace que 'ltStatus' tenga que ser campo propio.
resultWithDnf :: ByteString
resultWithDnf =
  "[" <> result 16 "1" "false" "false" "false"
    <> "," <> result 1 "2" "true" "false" "false"
    <> "]"

-- | El coche 1 con abandono __y__ descalificación. No se ha observado; fija la
-- prioridad de 'statusOf' para que no la decida el orden de los guardas.
resultDsqAndDnf :: ByteString
resultDsqAndDnf =
  "[" <> result 16 "1" "false" "false" "false"
    <> "," <> result 1 "2" "true" "false" "true"
    <> "]"

-- | El coche 1 sin tomar la salida. Cero casos en las cuatro sesiones medidas.
resultWithDns :: ByteString
resultWithDns =
  "[" <> result 16 "1" "false" "false" "false"
    <> "," <> result 1 "null" "false" "true" "false"
    <> "]"

-- | Las tres banderas ausentes en los dos objetos. Con @.:@ este fixture no
-- decodifica y se pierde la tabla entera.
resultWithoutFlagKeys :: ByteString
resultWithoutFlagKeys =
  "[" <> resultNoFlags 16 "1"
    <> "," <> resultNoFlags 1 "2"
    <> "]"

-- | La propiedad que 'show' __no__ cumple y que motiva el módulo: una cifra
-- formateada no lleva nunca @e@, porque una celda que dice @1.0e-2@ no comunica una
-- magnitud. El 'Arbitrary' de 'Double' de QuickCheck no genera
-- @NaN@\/@Infinity@ (ver 'roundTripsDouble'), así que todos los casos generados
-- caen en la rama finita, que es justo la que tiene que cumplirla.
neverScientific :: Int -> Double -> Property
neverScientific decimals x =
  T.all (/= 'e') formatted .&&. T.all (/= 'E') formatted
  where
    formatted = formatFixed (decimals `mod` 7) x

-- | El recorte deja una cifra en forma canónica: si queda punto, no puede haber un
-- cero justo antes del final, y el punto no puede ser el último carácter. Cubre de
-- una vez los dos fallos posibles del @dropWhileEnd@ —quedarse corto y pasarse—
-- sobre cualquier magnitud, incluidas las que ningún caso de arriba enumera.
trimLeavesNoTail :: Int -> Double -> Property
trimLeavesNoTail decimals x =
  not (T.isSuffixOf "." trimmed) .&&. not (hasDot && T.isSuffixOf "0" trimmed)
  where
    trimmed = formatTrimmed (decimals `mod` 7) x
    hasDot  = T.any (== '.') trimmed
