-- | Invariantes de la lógica pura de las áreas Historical
-- ('Handler.Historical.Helper'), Telemetry ('Handler.Telemetry.Helper', con la
-- resolución de parámetros), Comparison ('Handler.Comparison.Helper', ídem),
-- Drivers (ídem), TyreStrategy ('Handler.TyreStrategy.Helper'), Live
-- ('Handler.Live.Helper' y las cabeceras de procedencia de 'Handler.Live') y los
-- tipos crudos compartidos de OpenF1 ('Handler.OpenF1.Helper'). Con el último no
-- queda ninguna función pura del backend sin cubrir.
--
-- TyreStrategy es la primera área que se prueba __contra dos respuestas a la vez__,
-- porque su función pura cruza @/stints@ con @/drivers@; `assembleRows` sube esa
-- escalera a cinco, y de ahí que los helpers de la suite crezcan en número de
-- fixtures y no en número de formas.
--
-- Un caso no encaja en ese reparto y es deliberado: la __coherencia entre los
-- dummies__ de Drivers y Comparison. No prueba una función sino un acuerdo entre
-- dos áreas —que la parrilla de respaldo contenga los coches que la comparación
-- de respaldo pinta—, y sin él nada impide que un cambio en un dummy deje al
-- widget de mañana enseñando una lista que no contiene lo que está dibujando.
--
-- Cubre además __cinco__ módulos de @common@ que no son del backend, y por la misma
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
-- * 'Common.Layout' — la aritmética del lienzo y la traducción del rectángulo a
--   CSS (2026-09-07), más los seis rectángulos de los
--   layouts fijos, que son una __copia__ de @Pages.Dashboard@ porque @frontend@ no
--   está en @cabal.project@ y la suite no puede importarlo.
-- * 'Common.Origin' — la procedencia del dato que viaja en cabecera
--   (2026-09-06). Quinto por la misma puerta, y el más
--   claramente repartido entre los dos extremos: el backend escribe la etiqueta y
--   el widget la lee, así que el ida y vuelta solo se puede probar donde los dos
--   lados están a la vez, que es aquí.
--
-- Los fixtures son recortes reales de la respuesta de cada servicio en
-- 'ByteString' y se decodifican con 'eitherDecodeStrict', así que cada caso
-- ejercita __el 'FromJSON' y la función de ensamblado juntos__: los dos son la
-- unidad que el @Context@ del área consume, y separarlos dejaría sin cubrir
-- precisamente los campos opcionales, que viven en el decode.
module Main (main) where

import           App                         (ScheduledSession (..))
import           Common.Carry                (Board (..), Carry (..), Grip (..),
                                              Hand (..), Held (..), Scene (..),
                                              boardOf, heldStyle,
                                              magnetDivisions, scene, stepBoard)
import           Common.Chart                (SectorPace (..), SectorSpan (..),
                                              axisPoints, axisPolyline,
                                              axisRange, axisTicks, axisZeroY,
                                              chartHeight, chartPad, chartWidth,
                                              deltaPoints, deltaPolyline,
                                              deltaRange, frontierCells,
                                              frontierCellsAt, sectorPace,
                                              sectorSpans, zeroLineY)
import           Common.Columns              (LiveColumn (..), canClose,
                                              liveColumnClass, liveColumnLabel,
                                              liveColumnsInOrder, menuColumns,
                                              shownColumns, toggleColumn)
import           Common.Comparison           (Axis (..), Baseline (..),
                                              ChartType (..), LapGeometry (..),
                                              Pair (..), anchored, axesInOrder,
                                              axisFromKey, axisKey, axisLabel,
                                              axisNotice, axisXs, baseIndex,
                                              baselineFromKey, baselineKey,
                                              baselineLabel, baselineRole,
                                              baselinesInOrder,
                                              chartTypeFromKey, chartTypeKey,
                                              chartTypeLabel, chartTypeReady,
                                              chartTypeTraces,
                                              chartTypesInOrder, defaultAxis,
                                              defaultChartType, deltaFormula,
                                              deltasAgainst, lapShown,
                                              missingReference, noLapFor,
                                              pairWith)
import           Common.ComparisonCard       (CardControl (..), CardLayout (..),
                                              ChartMode (..), Side (..),
                                              carSelectWidth, cardLayout,
                                              columnGap, controlMaxWidth,
                                              controlWidth, curveInset,
                                              defaultControl,
                                              defaultControlSide, defaultMode,
                                              insideAxisLabels, modeEnabled,
                                              modeFromKey, modeKey, modeLabel,
                                              modeOption, modesInOrder,
                                              otherSide, rowHeight, rowTitle,
                                              shownMode, showsNames,
                                              showsValues, singleRowHeight,
                                              tracesInset, valueHeight,
                                              valueWidth, valuesFit,
                                              valuesFitMeasured, valuesRowFits,
                                              valuesRowHeight, vsBeside)
import           Common.Format               (ClockForm (..), formatClock,
                                              formatCountdown, formatDelta,
                                              formatFixed, formatTrimmed,
                                              noData)
import           Common.Layout               (canvasSpan, clampToMin, fitsAt,
                                              gridDivisions, minHeightFor,
                                              minWidthFor, overlaps, slotStyle,
                                              snapTo, spanCss, touchesTopRight)
import           Common.Origin               (Origin (..), Source (..),
                                              Sourced (..), fetchedAtHeader,
                                              originFrom, originHeader,
                                              originLabel, originNotice,
                                              sourceFrom, sourceHeader,
                                              sourceLabel, sourceName,
                                              sourcedFrom, sourcedHeaders)
import           Common.Push                 (Drag (..), applyDrag)
import           Common.Route                (comparisonPathFor, driversParam,
                                              driversPathFor)
import           Common.Saved                (Restored (..), atFactory,
                                              factoryControls, restoreLayout,
                                              sameShown, saveLayout, savedKey,
                                              unfitNote)
import           Common.Shown                (Arrivals, Indicator (..),
                                              Kept (..), Poll (..),
                                              PollEvent (..), canRequest,
                                              delayDefaultSeconds, delayFromUrl,
                                              delayMaxSeconds, delayNote,
                                              delayWait, delayWaitLabel,
                                              delayedPoll, delayedShown,
                                              fetchedAtLabel, indicatorClass,
                                              indicatorFrom, indicatorTooltip,
                                              keepLast, keptNothing, landed,
                                              liveRefreshSeconds, pollIdle,
                                              pollStep, readDelay,
                                              recordArrival, shownAge)
import           Common.Traces               (Channel (..), TraceLayout (..),
                                              TracePiece (..), TraceRows (..),
                                              axisEnd, axisEndLabel, boundaryXs,
                                              channelCaption, channelHeight,
                                              channelLabel, channelRange,
                                              channelTop, channelsInOrder,
                                              channelsSpan, frontierXs,
                                              pieceFlex, readSamples,
                                              samplesStart, spanPiece,
                                              traceChannels, traceLayout,
                                              tracePoints, traceXs,
                                              tracesHeight, xPercent)
import           Common.Types                (BandFlag (..), BandPiece (..),
                                              ComparisonEntry (..),
                                              Countdown (..), DriverEntry (..),
                                              DriverStatus (..),
                                              HistoricalStat (..),
                                              LapComparison (..),
                                              LapProgress (..), LayoutId (..),
                                              LiveTable (..),
                                              LiveTimingRow (..), RowBreak (..),
                                              SessionClock (..),
                                              SessionInfo (..),
                                              SessionState (..),
                                              StartNotice (..), StatEntity (..),
                                              StateBasis (..),
                                              StateReading (..),
                                              TelemetryPoint (..),
                                              TracePoint (..),
                                              TrackCondition (..),
                                              TyreStint (..), UpNext (..),
                                              WidgetConfig (..), WidgetId (..),
                                              WidgetType (..), bandMark,
                                              bandNote, bandPieces, bandRight,
                                              bestLapMarks, catchUp, clockLabel,
                                              countdownText, cutOffLabel,
                                              flagName, lapLabel, lapSeconds,
                                              noParams, overCutOff, pieceFlag,
                                              pieceSeparator, pieceWord,
                                              rowBreaks, sessionInProgress,
                                              sessionIsLive, sessionStateFrom,
                                              sessionStateLabel,
                                              sessionStateWord, sessionTitle,
                                              shownClock, shownNext, showsClock,
                                              statusLabel, tickClock, tickDown,
                                              upNextLabel, waitingSession,
                                              waitingTable)
import           Config                      (openF1Log, telemetrySocket)
import           Data.Aeson                  (Value (..), decodeStrictText,
                                              eitherDecodeStrict, toJSON)
import           Data.ByteString             (ByteString)
import qualified Data.ByteString.Char8       as BC
import           Data.Either                 (isLeft)
import           Data.List                   (find, nub)
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (fromMaybe, listToMaybe)
import           Data.Proxy                  (Proxy (..))
import qualified Data.Set                    as Set
import qualified Data.Text                   as T
import           Data.Time.Calendar          (fromGregorian)
import           Data.Time.Clock             (NominalDiffTime, UTCTime (..),
                                              addUTCTime)
import           GHC.TypeLits                (symbolVal)
import qualified Handler.Comparison.Context  as Comparison
import           Handler.Comparison.Helper   (RawComparison, assembleComparison,
                                              comparable)
import qualified Handler.Comparison.Helper   as Comparison
import qualified Handler.Drivers.Context     as Drivers
import           Handler.Drivers.Helper      (RawDriver, assembleDrivers)
import qualified Handler.Drivers.Helper      as Drivers
import           Handler.Feed.Helper         (FeedFlag (..), FeedLive (..),
                                              FeedNotice (..), FeedRow (..),
                                              FeedSession (..), FeedTrack (..))
import           Handler.Feed.Manager        (feedTimeoutSeconds)
import           Handler.Historical.Helper   (Root, assembleConstructorStats,
                                              assembleStats, parseNum)
import           Handler.Live                (LiveResponse)
import           Handler.Live.Helper         (Announced (..), ClockVerdict (..),
                                              FeedVerdict (..), Notice (..),
                                              Of1Interval, Of1Lap,
                                              Of1Meeting (..), Of1Position,
                                              Of1Result (..), Of1Session (..),
                                              advanceClock, announcedAt,
                                              assembleRows, chequeredGrace,
                                              classificationGaps,
                                              classificationTime, clockVerdict,
                                              closesFeedWindow, derivedState,
                                              endMargin, feedRows, feedSession,
                                              feedStatus, feedVerdict,
                                              feedWindowLead, feedWindowOpen,
                                              fetchFailure, finaliseBox,
                                              freezeClock, inheritFinalised,
                                              lapProgress, latestByDriver,
                                              meetingNames, openf1ClockIdle,
                                              openf1ClockPeriod, openf1MinGap,
                                              openf1Session, parseFeedInstant,
                                              parseNotice, parseRemaining,
                                              schedule, servedFromBox,
                                              sessionBestLap, sessionClock,
                                              stillRecent, trackCondition,
                                              upNext)
import           Handler.OpenF1.Helper       (Answer (..), Of1Driver (..),
                                              alwaysWritten, answerOf,
                                              brakeWait, brakeWindow,
                                              requestLine)
import           Handler.OpenF1.Manager      (endsAfter, latestSession)
import           Handler.Telemetry.Helper    (FastF1Point, assemblePoints)
import qualified Handler.Telemetry.Helper    as Telemetry
import           Handler.TyreStrategy.Helper (Of1Stint, assembleStints,
                                              tyreStep)
import qualified Network.HTTP.Client         as Client
import           Network.HTTP.Req            (HttpException (..),
                                              queryParamToList)
import           Outcome                     (Rejection (..), rejectionFor)
import           Provenance                  (FetchedAtHeaderName,
                                              OriginHeaderName,
                                              Provenanced (..),
                                              SourceHeaderName, fetchedAtText,
                                              isoInstant, withProvenance)
import           Servant.API                 (ResponseHeader (..), getResponse,
                                              lookupResponseHeader)
import           Test.Hspec
import           Test.Hspec.QuickCheck       (prop)
import           Test.QuickCheck             (NonNegative (..), Property,
                                              (.&&.), (===))

main :: IO ()
main = hspec $ do
  describe "telemetrySocket" $ do
    it "sin la variable, el backend habla por TCP" $
      telemetrySocket Nothing `shouldBe` Nothing

    it "vacía cuenta como no definida" $
      telemetrySocket (Just "") `shouldBe` Nothing

    it "con una ruta, esa ruta" $
      telemetrySocket (Just "/run/user/1000/dashboardF1/fastf1-8080.sock")
        `shouldBe` Just "/run/user/1000/dashboardF1/fastf1-8080.sock"

  describe "openF1Log" $ do
    it "sin la variable, solo los fallos" $
      openF1Log Nothing `shouldBe` False

    it "vacía cuenta como no definida" $
      openF1Log (Just "") `shouldBe` False

    it "con cualquier valor, todas las peticiones" $
      openF1Log (Just "1") `shouldBe` True

  describe "assembleStats" $ do
    it "emite una fila por piloto, en el orden de la clasificación y con la identidad completa" $
      driverStatsOf driverStandings
        `shouldBe`
          [ HistoricalStat DriverStat "VER" "Max" "Verstappen" 393 (Just 9) (Just 1)
          , HistoricalStat DriverStat "NOR" "Lando" "Norris" 331 (Just 3) (Just 2)
          ]

    -- Las dos métricas dejaron de descartarse igual el 2026-08-24: con una fila
    -- por entidad, `points` ilegible no tiene dónde caerse solo.
    it "descarta al piloto entero cuando `points` no parsea, aunque `wins` sí" $
      driverStatsOf unparseablePoints `shouldBe` []

    it "conserva al piloto con hsWins en Nothing cuando `wins` no parsea" $
      driverStatsOf unparseableWins
        `shouldBe` [HistoricalStat DriverStat "HAM" "Lewis" "Hamilton" 183 Nothing (Just 5)]

    it "usa el apellido como código cuando Jolpica omite `code`" $
      driverStatsOf driverWithoutCode
        `shouldBe` [HistoricalStat DriverStat "Bortoleto" "Gabriel" "Bortoleto" 12 (Just 0) (Just 18)]

    it "deja hsWins en Nothing cuando Jolpica no publica `wins`" $
      driverStatsOf driverWithoutWins
        `shouldBe` [HistoricalStat DriverStat "ALO" "Fernando" "Alonso" 24 Nothing (Just 9)]

    it "devuelve [] cuando la respuesta no trae la clave DriverStandings" $
      driverStatsOf standingsListWithoutKeys `shouldBe` []

    -- El puesto oficial de Jolpica, con los empates ya resueltos (en la ronda 16 de
    -- 2026, tres pilotos con 7 puntos salen 15.º, 16.º y 17.º).
    it "el puesto sale de `positionText`; uno que no es número queda sin puesto" $
      -- «D» es como Ergast escribe a un excluido. Se siembra también el que sí es
      -- número, para que la aserción no pase con el puesto siempre vacío.
      map (fmap hsPosition . driverStatsOf . withPosition)
          [ "\"position\":\"15\",\"positionText\":\"15\""
          , "\"position\":\"22\",\"positionText\":\"D\""
          , "\"positionText\":\"-\""
          ]
        `shouldBe` [[Just 15], [Nothing], [Nothing]]

    it "sin `positionText` vale `position`, y sin ninguno no hay puesto" $
      map (fmap hsPosition . driverStatsOf . withPosition)
          ["\"position\":\"16\"", ""]
        `shouldBe` [[Just 16], [Nothing]]

    it "ignora la clasificación de constructores" $
      driverStatsOf constructorStandings `shouldBe` []

  describe "assembleConstructorStats" $ do
    it "emite una fila por constructor, con `constructorId` en hsCode y `name` en hsFamilyName" $
      constructorStatsOf constructorStandings
        `shouldBe`
          [ HistoricalStat ConstructorStat "red_bull" "" "Red Bull" 712 (Just 12) (Just 1)
          , HistoricalStat ConstructorStat "mclaren" "" "McLaren" 640 (Just 9) (Just 2)
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
      Telemetry.resolveParams Nothing Nothing `shouldBe` Right ("latest", "all")

    it "respeta el parámetro presente y deja el ausente en su defecto" $ do
      Telemetry.resolveParams (Just "2026-13-R") Nothing `shouldBe` Right ("2026-13-R", "all")
      Telemetry.resolveParams Nothing (Just "1,4") `shouldBe` Right ("latest", "1,4")

    it "rechaza un parámetro escrito pero vacío con su motivo, aunque el otro sea bueno" $ do
      Telemetry.resolveParams (Just "") Nothing
        `shouldBe` Left (BadRequest "session está vacío: omítelo para usar la sesión por defecto")
      Telemetry.resolveParams (Just "2026-13-R") (Just "")
        `shouldBe` Left (BadRequest "driver está vacío: omítelo para pedir todos los coches")

  describe "assembleComparison" $ do
    it "mapea los coches en el orden pedido, la referencia primero, con sus sectores y su traza" $
      comparisonOf comparisonObject
        `shouldBe`
          MkLapComparison
            { lcEntries =
                [ MkComparisonEntry
                    { ceCar = "16", ceDriver = "LEC", ceLap = "1:29.512", cePart = Just "Q3"
                    , ceSectors = Just (29.0, 31.0, 29.512)
                    , ceFrontiers = Just (1210.5, 2650.25)
                    , ceTrace =
                        [ MkTracePoint 0.0 0.0 287.0 1.0 0.0
                        , MkTracePoint 89.512 5100.0 301.0 1.0 0.0
                        ]
                    }
                , MkComparisonEntry
                    { ceCar = "1", ceDriver = "NOR", ceLap = "1:29.345", cePart = Just "Q3"
                    , ceSectors = Just (29.048, 30.871, 29.426)
                    , ceFrontiers = Nothing
                    , ceTrace = []
                    }
                ]
            , lcSamples = 2
            , lcNotice = ""
            }

    it "decodifica un coche sin vuelta en vez de tumbar el objeto" $ do
      -- El caso medido en Monza (el 16) y Zandvoort (el 87 y el 3): el servicio
      -- emite el coche sin sectores ni tiempo, y decidir es del Context.
      let c = comparisonOf comparisonWithoutLap
      map ceSectors (lcEntries c) `shouldBe` [Nothing, Just (29.048, 30.871, 29.426)]
      map ceLap (lcEntries c) `shouldBe` ["", "1:29.345"]
      comparable c `shouldBe` True

    it "no da por comparable una comparación en la que ningún coche tiene vuelta" $
      comparable (comparisonOf comparisonWithoutLaps) `shouldBe` False

  describe "Comparison.adjustSamples" $ do
    it "deja tal cual 0 y lo que ya está en 60–250 de 5 en 5, sin aviso" $
      map Comparison.adjustSamples [0, 60, 100, 250] `shouldBe` [(0, ""), (60, ""), (100, ""), (250, "")]

    it "lleva lo de fuera al borde y lo negativo a 0, con el aviso" $ do
      Comparison.adjustSamples 30 `shouldBe` (60, "samples=30 fuera de 60–250 de 5 en 5: se usó 60")
      Comparison.adjustSamples 1 `shouldBe` (60, "samples=1 fuera de 60–250 de 5 en 5: se usó 60")
      Comparison.adjustSamples 300 `shouldBe` (250, "samples=300 fuera de 60–250 de 5 en 5: se usó 250")
      Comparison.adjustSamples (-5) `shouldBe` (0, "samples=-5 fuera de 60–250 de 5 en 5: se usó 0")

    it "lleva lo que no es múltiplo de 5 al más cercano" $
      map (fst . Comparison.adjustSamples) [61, 62, 63, 64, 248, 249] `shouldBe` [60, 60, 65, 65, 250, 250]

    prop "siempre da 0 o un múltiplo de 5 entre 60 y 250, y ajustarlo otra vez no lo mueve" $ \n ->
      let used = fst (Comparison.adjustSamples n)
       in (used == 0 || (used >= 60 && used <= 250 && used `mod` 5 == 0))
            && Comparison.adjustSamples used == (used, "")

  describe "Comparison.resolveParams" $ do
    it "sin parámetros compara los dos coches del dummy, la referencia primero y sin trazas" $
      Comparison.resolveParams Nothing Nothing Nothing `shouldBe` Right (("latest", "16,1", 0), "")

    it "respeta el parámetro presente y deja el ausente en su defecto" $ do
      Comparison.resolveParams (Just "2026-13-Q") Nothing Nothing
        `shouldBe` Right (("2026-13-Q", "16,1", 0), "")
      Comparison.resolveParams Nothing (Just "44,63") (Just 100)
        `shouldBe` Right (("latest", "44,63", 100), "")

    it "ajusta las muestras en la clave y devuelve el aviso aparte" $
      Comparison.resolveParams Nothing Nothing (Just 30)
        `shouldBe` Right (("latest", "16,1", 60), "samples=30 fuera de 60–250 de 5 en 5: se usó 60")

    it "rechaza un parámetro escrito pero vacío con su motivo, aunque el otro sea bueno" $ do
      Comparison.resolveParams (Just "") (Just "44,63") Nothing
        `shouldBe` Left (BadRequest "session está vacío: omítelo para usar la sesión por defecto")
      Comparison.resolveParams Nothing (Just "") Nothing
        `shouldBe` Left (BadRequest "drivers está vacío: omítelo para comparar los coches por defecto")

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
      -- el simple, a diferencia del `comparable` de Comparison.
      driversOf emptyArray `shouldBe` []

  describe "Drivers.resolveParams" $ do
    it "sin parámetro consulta la última carrera, como los otros dos endpoints" $
      Drivers.resolveParams Nothing `shouldBe` Right "latest"

    it "respeta la sesión presente" $
      Drivers.resolveParams (Just "2026-13-Q") `shouldBe` Right "2026-13-Q"

    it "rechaza la sesión escrita pero vacía con su motivo" $
      Drivers.resolveParams (Just "")
        `shouldBe` Left (BadRequest "session está vacío: omítelo para usar la sesión por defecto")

    it "solo la cadena vacía es vacía: un valor de espacios pasa tal cual" $
      Drivers.resolveParams (Just " ") `shouldBe` Right " "

  describe "driversPathFor" $ do
    it "sin sesión da el path desnudo, que es el caso normal del widget" $
      driversPathFor Nothing `shouldBe` "/api/drivers"

    it "con sesión la pone en el query, y no hay segundo parámetro que omitir" $
      driversPathFor (Just "2026-13-R") `shouldBe` "/api/drivers?session=2026-13-R"

  -- Único `describe` de la suite cuyos casos afirman que un fixture __no__
  -- decodifica, y por eso es el único que usa `tryOf1Drivers` en vez de un helper
  -- que aborte. `Of1Driver` es la puerta de entrada de dos áreas —Live y
  -- TyreStrategy— y sus tres campos son obligatorios: lo que se fija aquí es que
  -- ese «todo o nada» sea el criterio y no una casualidad, porque es lo que
  -- decide si la tabla cae a cache/dummy o se sirve a medias.
  --
  -- El camino feliz ya estaba cubierto de rebote —`stintsOf` y `rowsOf` decodifican
  -- esta misma parrilla y abortan si falla—, así que lo que estos casos añaden son
  -- las ramas negativas y el mapeo campo a campo.
  --
  -- El orden de salida __no__ se prueba, y es deliberado: las dos consumidoras
  -- usan la lista como tabla de búsqueda (`find` por `odNumber`) y reordenan lo que
  -- emiten, así que un caso de orden probaría a aeson y no a este repo.
  describe "Of1Driver" $ do
    it "mapea los tres campos e ignora las claves que no modela" $
      -- La respuesta real trae once claves; el tipo consume tres. Que las otras
      -- ocho no estorben es contrato del decode y no una propiedad de aeson que
      -- se pueda dar por supuesta: bastaría un `withObject` estricto para que la
      -- parrilla entera dejara de decodificar sin que nada más cambiara.
      fmap (map (\d -> (odNumber d, odAcronym d, odTeam d))) (tryOf1Drivers openF1Grid)
        `shouldBe` Right [(1, "NOR", "McLaren"), (16, "LEC", "Ferrari")]

    it "sin team_name no decodifica, y eso tumba la parrilla entera" $
      -- El contrario exacto de `assembleDrivers`, que ante el equipo ausente
      -- conserva la lista y pierde la decoración (`.:? … .!= ""`). Aquí los tres
      -- campos son `.:`, así que el área pierde la traducción
      -- `driver_number → name_acronym` y no solo el nombre del equipo: servir la
      -- tabla sin ella daría filas que el widget no puede etiquetar. Que las dos
      -- áreas traten el mismo no-dato al revés es decisión, y sin este caso nada
      -- la sostiene.
      tryOf1Drivers openF1GridWithoutTeam `shouldSatisfy` isLeft

    it "con driver_number como cadena tampoco decodifica" $
      -- Los dos `/drivers` del repo discrepan en el tipo del mismo concepto: el de
      -- FastF1 emite el número como texto (ver `driverGrid`) y el de OpenF1 como
      -- entero. Confundirlos es el error que este caso ancla, y el fallo tiene que
      -- ser de lista entera: una fila descartada en silencio dejaría a un piloto
      -- fuera de la tabla con la red viva.
      tryOf1Drivers openF1GridNumberAsText `shouldSatisfy` isLeft

    it "una sesión sin parrilla publicada decodifica como []" $
      -- La sesión sin parrilla tiene que __decodificar__, no reventar: el `[]` es
      -- la puerta por la que los `Context` de Live y TyreStrategy degradan, porque
      -- su condición de éxito es `not (null rows)`. Las dos puertas acaban en
      -- cache/dummy, y este caso fija que esta pasa por la lista vacía y no por la
      -- excepción. Mismo papel que el `[]` de `assembleDrivers`.
      tryOf1Drivers emptyArray `shouldBe` Right []

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

  -- La escalera de `/api/tyre-strategy` con su procedencia. Lo guardado lleva una
  -- tanda distinta de la traída en todos los casos, para que servir la equivocada no
  -- pueda pasar la prueba.
  describe "tyreStep" $ do
    it "con filas sirve lo traído como fresco de OpenF1 y lo guarda con la hora de ahora" $
      tyreStep tyreNow (Just freshStints) (Just (fetchInstant, keptStints))
        `shouldBe`
          ( Just (Provenanced Fresh (Just OpenF1) Nothing freshStints)
          , Just (tyreNow, freshStints) )

    it "una respuesta vacía cae a lo guardado, con su hora, y no lo pisa" $
      tyreStep tyreNow (Just []) (Just (fetchInstant, keptStints))
        `shouldBe`
          ( Just (Provenanced Cached (Just OpenF1) (Just fetchInstant) keptStints)
          , Just (fetchInstant, keptStints) )

    it "un fallo sirve lo guardado igual que una respuesta vacía" $
      tyreStep tyreNow Nothing (Just (fetchInstant, keptStints))
        `shouldBe`
          ( Just (Provenanced Cached (Just OpenF1) (Just fetchInstant) keptStints)
          , Just (fetchInstant, keptStints) )

    it "sin nada guardado un fallo no tiene qué servir, y quien llama pone el ejemplo" $
      tyreStep tyreNow Nothing Nothing `shouldBe` (Nothing, Nothing)

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
  --     @position@ ×5) solo los de @duration@ llegan al decode, y entran como
  --     'Nothing' sin tumbarlo; los otros dos campos no se modelan.
  describe "assembleRows" $ do
    it "cruza las cinco respuestas y ordena por posición" $
      -- El orden que llega es el de `/drivers` (coche 1 primero); el que sale es
      -- por posición, así que LEC (P1) va antes que NOR (P2). Y de las dos
      -- muestras por coche de `/position` e `/intervals` se toma la última por
      -- `date`, no la primera.
      rowsOf openF1Grid positionArray intervalArray lapArray resultArray
        `shouldBe`
          [ LiveTimingRow 1 "LEC" "Ferrari" "LEADER" "-" "1:15.265" Running "1:15.265" "" [] False False
          , LiveTimingRow 2 "NOR" "McLaren" "+2.310" "+2.310" "1:16.001" Running "1:16.001" "" [] False False
          ]

    it "marca el DNF que sí trae posición, y la fila sigue en la tabla" $
      -- El caso medido del coche 23, y el que justifica que 'ltStatus' exista: la
      -- fila __no__ desaparece ni cambia de sitio, solo gana la marca. Sus gap e
      -- intervalo siguen siendo los de su última muestra, que es exactamente el
      -- dato engañoso que la marca contextualiza.
      rowsOf openF1Grid positionArray intervalArray lapArray resultWithDnf
        `shouldBe`
          [ LiveTimingRow 1 "LEC" "Ferrari" "LEADER" "-" "1:15.265" Running "1:15.265" "" [] False False
          , LiveTimingRow 2 "NOR" "McLaren" "+2.310" "+2.310" "1:16.001" Dnf "1:16.001" "" [] False False
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
        `shouldBe` [LiveTimingRow 1 "LEC" "Ferrari" "LEADER" "-" "1:15.265" Running "1:15.265" "" [] False False]

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

    it "la vuelta rápida es la más corta de las cronometradas, no la última; sin ninguna, la raya" $ do
      let laps = "[" <> lap 1 1 "75.0" <> "," <> lap 1 2 "76.001" <> "," <> lap 16 1 "75.265"
                   <> "," <> lap 16 2 "null" <> "]"
      map (\r -> (ltLastLap r, ltBestLap r, ltPartBestLap r))
          (rowsOf openF1Grid positionArray intervalArray laps resultArray)
        `shouldBe` [("1:15.265", "1:15.265", ""), ("1:16.001", "1:15.000", "")]
      map ltBestLap (rowsOf openF1Grid positionArray intervalArray emptyArray resultArray)
        `shouldBe` ["-", "-"]

    it "pone `-` en la última vuelta del piloto sin ninguna cronometrada" $
      -- El coche que abandonó en la vuelta 0 (el 3 de la 11353): está en la
      -- parrilla y en `/position`, pero no tiene una sola vuelta buena.
      map ltLastLap (rowsOf openF1Grid positionArray intervalArray emptyArray resultArray)
        `shouldBe` ["-", "-"]

    -- Las seis que siguen son el caso de las sesiones sin `/intervals`, que son
    -- cuatro de las cinco del fin de semana: medido el 2026-09-12, el endpoint da
    -- 404 en las tres prácticas __y en la Qualy__, y solo la carrera lo publica.
    it "saca gap e intervalo de la clasificación cuando `/intervals` llega vacía" $
      -- Es la mitad que faltaba: `assembleRows` ya toleraba la ausencia poniendo
      -- `-`, y una tabla con dos columnas a raya es el mismo vacío con otra forma.
      map (\r -> (ltGap r, ltInterval r))
          (rowsOf openF1Grid positionArray emptyArray lapArray resultPractice)
        `shouldBe` [("LEADER", "-"), ("+0.166", "+0.166")]

    it "deja ganar a `/intervals` cuando sí trae datos" $
      -- La prueba que evita pasar por el motivo equivocado: el mismo fixture de
      -- prácticas daría `+0.166`, así que este `+2.310` solo puede venir de
      -- `/intervals`. Sin este caso, una regla invertida pasaría los dos.
      map (\r -> (ltGap r, ltInterval r))
          (rowsOf openF1Grid positionArray intervalArray lapArray resultPractice)
        `shouldBe` [("LEADER", "-"), ("+2.310", "+2.310")]

    it "toma el último tiempo no nulo del arreglo de una Qualy" $
      -- El 1 cayó en Q1 y vale su Q1; el 16 corrió las tres y vale su Q3. La
      -- diferencia es contra la __pole__ (+0.993) y no los +0.167 que OpenF1
      -- publica contra el líder de Q1, que es justo lo que se descartó.
      map (\r -> (ltGap r, ltInterval r))
          (rowsOf openF1Grid positionArray emptyArray lapArray resultQualy)
        `shouldBe` [("LEADER", "-"), ("+0.993", "+0.993")]

    it "pone `-` al piloto cuyo arreglo de Qualy está entero a nulos" $
      map (\r -> (ltGap r, ltInterval r))
          (rowsOf openF1Grid positionArray emptyArray lapArray resultQualyAllNull)
        `shouldBe` [("LEADER", "-"), ("-", "-")]

    it "da el gap de carrera al restar tiempos totales" $
      -- En carrera solo se llega aquí si `/intervals` falló. `duration` no es una
      -- vuelta sino el tiempo total, y aun así la __resta__ sale bien: +3.857 es
      -- exactamente el `gap_to_leader` que la 11361 publica para el segundo.
      map (\r -> (ltGap r, ltInterval r))
          (rowsOf openF1Grid positionArray emptyArray lapArray resultRace)
        `shouldBe` [("LEADER", "-"), ("+3.857", "+3.857")]

    it "pone `-` al piloto que no tiene tiempo en la clasificación" $
      -- El coche 23 de la FP3 de hoy, con 2 vueltas y ninguna cronometrada:
      -- `duration` nulo sin ninguna bandera puesta. La fila sigue en la tabla.
      map (\r -> (ltGap r, ltInterval r))
          (rowsOf openF1Grid positionArray emptyArray lapArray resultNoTime)
        `shouldBe` [("LEADER", "-"), ("-", "-")]

  -- Vive separada de `assembleRows` porque es la única pieza del área que no cruza
  -- respuestas: entra una lista y sale otra, así que sus casos límite se escriben
  -- sin montar los cinco fixtures.
  describe "classificationGaps" $ do
    it "devuelve [] sobre una clasificación vacía" $
      classificationGaps [] `shouldBe` []

    it "deja al más rápido con las dos a `-`" $
      -- No tiene a nadie delante ni diferencia consigo mismo. En la tabla esa fila
      -- la pinta el `pos == 1` de `assembleRows`, que llega antes.
      classificationGaps [timedResult 16 (Just 92.797)]
        `shouldBe` [(16, ("-", "-"))]

    it "ordena por tiempo y no por el orden de llegada" $
      -- La lista de `/session_result` viene ordenada, pero la función no puede
      -- depender de eso: el intervalo al de delante sería el de otro piloto.
      map fst (classificationGaps
                 [ timedResult 1 (Just 92.963)
                 , timedResult 16 (Just 92.797)
                 , timedResult 4 (Just 92.986)
                 ])
        `shouldBe` [16, 1, 4]

    it "acumula la diferencia al líder y no al de delante" $
      -- Las dos columnas dicen cosas distintas, y con tres pilotos se separan: el
      -- tercero está a +0.189 del líder pero a +0.023 del segundo.
      map snd (classificationGaps
                 [ timedResult 16 (Just 92.797)
                 , timedResult 1 (Just 92.963)
                 , timedResult 4 (Just 92.986)
                 ])
        `shouldBe` [("-", "-"), ("+0.166", "+0.166"), ("+0.189", "+0.023")]

    it "da `+0.000` al empatado en vez de tratarlo como el líder" $
      map snd (classificationGaps
                 [ timedResult 16 (Just 92.797), timedResult 1 (Just 92.797) ])
        `shouldBe` [("-", "-"), ("+0.000", "+0.000")]

    it "omite al piloto sin tiempo en vez de colocarlo el primero" $
      -- Con 'Nothing' ordenando antes que cualquier 'Just', un piloto sin tiempo
      -- sería el líder y le robaría la referencia a toda la tabla.
      classificationGaps [timedResult 1 Nothing, timedResult 16 (Just 92.797)]
        `shouldBe` [(16, ("-", "-"))]

  -- La misma clave con tres formas, y las tres legítimas. Los casos de abajo son
  -- los que el decode no ve nunca en producción; los que sí se ven van por
  -- `assembleRows`, que los ejercita a través del JSON.
  describe "classificationTime" $ do
    it "toma el número tal cual" $
      classificationTime (Number 92.797) `shouldBe` Just 92.797

    it "toma el último no nulo del arreglo, no el primero ni el mínimo" $
      -- El mínimo daría 82.077 (el Q2), y lo que la clasificación enseña es el Q3.
      classificationTime (jsonArray [Number 82.612, Number 82.077, Number 81.786])
        `shouldBe` Just 81.786

    it "salta los nulos de las Q que el piloto no disputó" $
      classificationTime (jsonArray [Number 84.595, Null, Null])
        `shouldBe` Just 84.595

    it "da Nothing con el arreglo entero a nulos y con el arreglo vacío" $
      map classificationTime [jsonArray [Null, Null, Null], jsonArray []]
        `shouldBe` [Nothing, Nothing]

    it "da Nothing ante el nulo y ante cualquier forma que no sea número" $
      -- La cadena es la forma que `gap_to_leader` trae en carrera (@\"+1 LAP\"@);
      -- aquí no se ha visto, y el decode tiene que sobrevivirla igual.
      map classificationTime [Null, String "+1 LAP", Bool True]
        `shouldBe` [Nothing, Nothing, Nothing]

  describe "latestByDriver" $
    it "con dos muestras empatadas en la clave de orden, gana la que llega después" $
      -- Las series del directo entran por aquí; dos muestras del mismo coche con
      -- la misma @date@ no se distinguen por la clave, y la respuesta tiene que ser
      -- una y fija.
      latestByDriver (\(n, _, _) -> n) (\(_, k, _) -> k)
          ([(1, 5, "antes"), (16, 3, "otro"), (1, 5, "después")] :: [(Int, Int, T.Text)])
        `shouldBe` [(1, 5, "después"), (16, 3, "otro")]

  -- La otra fuente, y el reparto con OpenF1 es el contrario: allí se ensamblan cinco
  -- respuestas, aquí la tabla llega hecha. Lo que estos casos sostienen es lo poco
  -- que queda en el lado Haskell —quién puede faltar, el estado y el orden—, que es
  -- justo lo que decide si una sesión en marcha se ve o se pierde: por la decisión
  -- del 2026-09-12, un decode roto es un fallo del feed y la tabla sale de la cache.
  describe "FeedRow y feedRows" $ do
    it "mapea la tabla que emite el microservicio, con el líder tal cual viene" $
      -- El `\"LEADER\"` y el `\"-\"` los pone el microservicio, con el mismo
      -- criterio que `assembleRows`: la tabla no puede decir dos cosas distintas
      -- según de dónde venga el dato, así que aquí no se recalculan.
      fmap feedRows (tryFeedRows feedTable) `shouldBe` Right feedRowsFixture

    it "ordena por posición aunque el emisor mande la tabla desordenada" $
      -- El microservicio ya ordena. Que esta función lo repita es lo que impide que
      -- un cambio en la otra punta salga como una tabla desordenada sin error.
      fmap (map ltPosition . feedRows) (tryFeedRows feedTableUnordered)
        `shouldBe` Right [1, 2, 3]

    it "con solo posición y piloto la fila sobrevive, con lo demás en blanco" $
      -- El contrario de `Of1Driver`, que ante el equipo ausente tumba la parrilla
      -- entera. Aquí degradar es lo correcto porque el precio de no hacerlo es la
      -- tabla de la sesión en marcha, que es el único momento en que OpenF1 calla.
      fmap feedRows (tryFeedRows feedTableMinimal)
        `shouldBe` Right [LiveTimingRow 4 "ANT" "" "" "" "" Running "" "" [] False False]

    it "sin ltPosition no decodifica, y eso tumba la tabla entera" $
      -- Sin posición no hay fila que ordenar, que es el criterio que ya aplican
      -- `assembleRows` y el propio microservicio. El fallo tiene que ser de tabla
      -- entera: una fila descartada en silencio dejaría a un coche fuera con el
      -- feed vivo.
      tryFeedRows feedTableWithoutPosition `shouldSatisfy` isLeft

    it "sin ltDriver tampoco, porque la fila no identificaría a nadie" $
      tryFeedRows feedTableWithoutDriver `shouldSatisfy` isLeft

    it "una sesión que no está en marcha decodifica como [], no revienta" $
      -- El `[]` es la puerta por la que la escalera baja a OpenF1: si esto fuera una
      -- excepción, sería un fallo del feed y se iría a la cache, dejando la página
      -- sin el dato real que OpenF1 sí tiene fuera de sesión.
      fmap feedRows (tryFeedRows emptyArray) `shouldBe` Right []

  describe "feedStatus" $ do
    it "lee los cuatro nombres tal cual los emite el microservicio" $
      map feedStatus ["Running", "Dnf", "Dns", "Dsq"]
        `shouldBe` [Running, Dnf, Dns, Dsq]

    it "tolera espacios y mayúsculas, como el resto de lo que llega por cable" $
      map feedStatus ["  dnf ", "DSQ"] `shouldBe` [Dnf, Dsq]

    it "lo que no reconoce entra como Running, y ésa es la decisión" $
      -- Inventar un abandono haría creer en un incidente que nadie reportó, y
      -- tirar la fila perdería un coche que sí está en pista. `Running` significa
      -- «no consta que abandonara», igual que en `statusOf`.
      map feedStatus ["", "  ", "Retired", "InPit"]
        `shouldBe` [Running, Running, Running, Running]

  -- Los fixtures de este bloque son el tema de información de sesión REAL de las
  -- dos grabaciones —la carrera 11369 y la clasificación 11365—, no una forma
  -- inventada. Es lo que evita probar contra lo que creemos que el feed manda.
  describe "FeedSession y feedSession" $ do
    it "mapea la sesión de una carrera, con su circuito, sus vueltas y su reloj" $
      fmap (feedSession raceServedAt) (trySession feedSessionRace)
        `shouldBe` Right
          SessionInfo
            { siType    = "Race"
            , siName    = "Race"
            , siMeeting = "Spanish Grand Prix"
            , siCircuit = Just "Madring"
            , siState   = Just (StateReading SessionStarted Heard)
            , siLaps    = Just (LapProgress 12 57)
              -- Publicado a las 13:04:05.01 con 01:59:59 por delante y servido a
              -- las 13:34:05: han pasado 1799,99 s, o sea 1799 segundos enteros, y
              -- quedan 5400. El centésimo es del instante REAL de la grabación, y
              -- es lo que hace que la cuenta no sea la media hora redonda.
            , siClock   = Just (SessionClock 5400 True)
            , siPart    = Nothing
            , siTrack   = Nothing
            , siCountdown = Nothing
            , siStart   = Nothing
            , siEntries = []
            , siCutOffTime = Nothing
            }

    it "una clasificación no cuenta vueltas, y eso no es un fallo" $
      -- Medido: el tema que las publica manda 57 mensajes en la carrera 11369 y
      -- NINGUNO en la clasificación 11365. Son cuatro de las cinco sesiones de un
      -- fin de semana, así que la ausencia es el caso normal.
      fmap (siLaps . feedSession raceServedAt) (trySession feedSessionQualy)
        `shouldBe` Right Nothing

    it "un estado que no se reconoce conserva su texto, para poder verlo" $
      -- Lo que distingue a esto de `originFrom`, que tira lo irreconocible: aquel
      -- valor lo pone nuestro backend y éste lo pone el feed, que puede estrenar un
      -- estado sin avisar. Guardarlo es lo que permite saber CUÁL llegó.
      fmap (siState . feedSession raceServedAt) (trySession feedSessionAborted)
        `shouldBe` Right (Just (StateReading (SessionUnknown "Aborted") Heard))

    it "sin ningún campo decodifica igual, con todo en blanco" $
      -- Al contrario que `FeedRow`, aquí no hay campo del que dependan los demás.
      -- El estado sale en `Just` aun así: el feed que calla dice la cadena vacía, y
      -- eso es un estado desconocido, no un estado ausente. El hueco del tipo es
      -- para quien no publica estado ninguno.
      fmap (feedSession raceServedAt) (trySession "{}")
        `shouldBe` Right
          SessionInfo
            { siType    = ""
            , siName    = ""
            , siMeeting = ""
            , siCircuit = Nothing
            , siState   = Just (StateReading (SessionUnknown "") Heard)
            , siLaps    = Nothing
            , siClock   = Nothing
            , siPart    = Nothing
            , siTrack   = Nothing
            , siCountdown = Nothing
            , siStart   = Nothing
            , siEntries = []
            , siCutOffTime = Nothing
            }

    it "una vuelta sin su total no es medio progreso: es ninguno" $
      -- Los dos juntos son un solo hecho. «Vuelta 12» sin total no dice por dónde
      -- va la sesión, así que no hay nada que enseñar.
      fmap lapProgress (trySession feedSessionLapNoTotal) `shouldBe` Right Nothing

  describe "sessionClock" $ do
    it "el reloj que corre descuenta lo transcurrido desde que se publicó" $
      -- EL caso que motiva toda esta función, y está medido: en la carrera 11369 el
      -- feed publicó su reloj DOS veces, la última a los seis minutos. Servido
      -- crudo, diría «quedan 1 h 59 min» durante las dos horas siguientes.
      fmap (sessionClock raceServedAt) (trySession feedSessionRace)
        `shouldBe` Right (Just (SessionClock 5400 True))

    it "el reloj parado no se toca, sea cuando sea que se sirva" $
      -- `Extrapolating: false` es lo que el feed emite antes de arrancar y al
      -- cerrar cada segmento. Descontarle nada sería inventar.
      fmap (sessionClock raceServedAt) (trySession feedSessionFrozen)
        `shouldBe` Right (Just (SessionClock 7200 False))

    it "sin la marca se trata como parado, que es lo observado" $
      -- Decidido el 2026-09-14. Los dos únicos mensajes medidos sin la marca eran
      -- el arranque de un segmento, con el reloj todavía quieto. Y su modo de fallo
      -- —un reloj que no se mueve— se ve antes que el contrario.
      fmap (sessionClock raceServedAt) (trySession feedSessionNoMark)
        `shouldBe` Right (Just (SessionClock 900 False))

    it "corriendo pero sin saber desde cuándo, no hay reloj que servir" $
      -- Servir el número sin corregir afirmaría que quedan exactamente esos
      -- segundos, y es justo la afirmación que no se sostiene.
      fmap (sessionClock raceServedAt) (trySession feedSessionRunningNoUtc)
        `shouldBe` Right Nothing

    it "una foto muy posterior deja el reloj en cero, no en negativo" $
      -- El feed no calla al acabar la sesión (2026-09-13 (b)), así que este caso no
      -- es raro: es lo que devuelve al día siguiente.
      fmap (sessionClock dayAfterRace) (trySession feedSessionRace)
        `shouldBe` Right (Just (SessionClock 0 True))

    it "sin restante no hay reloj, aunque venga el instante" $
      fmap (sessionClock raceServedAt) (trySession feedSessionUtcOnly)
        `shouldBe` Right Nothing

  describe "sessionIsLive" $ do
    it "solo una sesión finalizada deja de dar directo" $
      -- `Finalised` es el único estado que sale exactamente una vez en las dos
      -- grabaciones (2026-09-13 (c)); «terminada» cicla por segmento y no sirve.
      map sessionIsLive [SessionInactive, SessionStarted, SessionFinalised]
        `shouldBe` [True, True, False]

    it "un estado que no se reconoce sigue dando directo" $
      -- La ausencia de la señal no es la señal contraria: un estado nuevo del feed
      -- tratado como «acabada» escondería la única fuente que publica en carrera.
      sessionIsLive (SessionUnknown "Aborted") `shouldBe` True

    it "y sobre las dos grabaciones reales, la carrera sí y la clasificación no" $
      -- Contra los fixtures y no contra constructores escritos a mano: lo que se
      -- afirma es que el estado REAL del feed atraviesa el decode y el mapeo hasta
      -- aquí con el sentido correcto.
      --
      -- El `Just` que queda a la vista es la otra mitad de la afirmación: por el
      -- feed el estado llega siempre, así que su ausencia no se prueba aquí — se
      -- prueba donde nace, que es la fuente que no lo publica.
      map
        (fmap (fmap (sessionIsLive . srState) . siState . feedSession raceServedAt) . trySession)
        [feedSessionRace, feedSessionQualy]
        `shouldBe` [Right (Just True), Right (Just False)]

  describe "sessionInProgress" $ do
    it "solo consta que hay carrera con la sesión en marcha o en un estado nuevo" $
      -- La tabla entera de una vez. Son cinco valores para seis situaciones: el
      -- estado ausente y la sesión ausente llegan por el mismo `Nothing`, que es
      -- justo lo que el aplanado hace inalcanzable por separado.
      map sessionInProgress
          [ Just SessionStarted
          , Just (SessionUnknown "Aborted")
          , Just SessionInactive
          , Just SessionFinalised
          , Nothing
          ]
        `shouldBe` [True, True, False, False, False]

    it "y sobre la grabación real, la sesión que rodaba enciende y la acabada no" $
      -- Contra los fixtures, por lo mismo que el caso equivalente de
      -- `sessionIsLive`: lo que se afirma es que el estado REAL atraviesa el decode
      -- y el mapeo con el sentido correcto.
      map
        (fmap (sessionInProgress . fmap srState . siState . feedSession raceServedAt) . trySession)
        [feedSessionRace, feedSessionQualy]
        `shouldBe` [Right True, Right False]

  -- La decisión entera de la escalera sobre el feed, sin levantar red. Vive en el
  -- `Helper` para que estas tres ramas existan: el `Context` solo despacha sobre
  -- ellas, y ahí no habría forma de probarlas.
  describe "feedVerdict" $ do
    it "con filas y la sesión en marcha, sirve el feed" $
      fmap (feedVerdict raceServedAt) (tryLive feedLiveFull)
        `shouldBe` Right (FeedServes (LiveTable (Just raceSessionFixture) feedRowsFixture NextUnknown))

    it "con filas pero la sesión finalizada, NO sirve el feed" $
      -- El feed sigue devolviendo la clasificación final durante horas, y servirla
      -- como `fresh` es afirmar que es de ahora.
      fmap (feedVerdict raceServedAt) (tryLive feedLiveFinalised)
        `shouldBe` Right (FeedFinalised finalisedHeard')

    it "sin filas no hay tabla, anuncie lo que anuncie la sesión" $
      -- Se mira antes que el estado: la sesión que venga al lado no cambia que no
      -- haya nada que servir.
      fmap (feedVerdict raceServedAt) (tryLive feedLiveEmpty)
        `shouldBe` Right FeedEmpty

    it "con filas y sin sesión, se sirve: la ausencia no es la señal contraria" $
      fmap (feedVerdict raceServedAt) (tryLive feedLiveWithoutSession)
        `shouldBe` Right (FeedServes (LiveTable Nothing feedRowsFixture NextUnknown))

  -- Lo que el log dice cuando un fetch no sale. Hasta el 2026-09-17 no decía nada, y
  -- el rechazo por ritmo de OpenF1 hubo que deducirlo midiendo la API por fuera.
  describe "fetchFailure" $ do
    it "nombra el 429, porque su número no dice qué hacer" $
      -- No es la red ni el servicio caído: es haber preguntado de más. Es el único
      -- status al que se le pone nombre.
      --
      -- 'fetchInstant' trae fracción de segundo, que es lo que da getCurrentTime;
      -- que el esperado no la lleve es lo que afirma que la marca la tira. Va aquí
      -- y no en un caso propio porque comparar la línea entera ya lo cubre.
      fetchFailure fetchInstant "el nombre de la sesión" (Just 429) "lo que sea"
        `shouldBe`
          "2026-09-11T14:03:22Z [live] el nombre de la sesión: \
          \HTTP 429, límite de peticiones de la fuente"

    it "los demás status van a secas, que para eso son códigos conocidos" $
      fetchFailure fetchInstant "las filas" (Just 503) "lo que sea"
        `shouldBe` "2026-09-11T14:03:22Z [live] las filas: HTTP 503"

    it "sin status sirve el texto de la excepción, que es lo único que distingue" $
      -- Conexión rechazada, techo vencido y un 200 con otra forma no tienen número
      -- que las nombre; su texto sí las separa.
      fetchFailure fetchInstant "el calendario" Nothing
        "ConnectionFailure: connect: does not exist"
        `shouldBe`
          "2026-09-11T14:03:22Z [live] el calendario: \
          \ConnectionFailure: connect: does not exist"

    it "el prefijo y el nombre de lo que se pedía van siempre, haya status o no" $
      -- Es lo que permite filtrar el log por área sin adivinar, y saber cuál de los
      -- tres fetch calló sin leer el código.
      map (T.isInfixOf "[live] el calendario: ")
          [ fetchFailure fetchInstant "el calendario" (Just 429) "x"
          , fetchFailure fetchInstant "el calendario" Nothing "x"
          ]
        `shouldBe` [True, True]

    it "la marca del log y la de la cabecera salen de la misma forma" $
      -- Si divergieran, cruzar los dos instrumentos exigiría convertir, y una
      -- conversión a mano es justo donde se cuela el error que no se ve releyendo.
      T.isPrefixOf (isoInstant fetchInstant)
        (fetchFailure fetchInstant "las filas" (Just 503) "x")
        `shouldBe` True

  describe "clockVerdict" $ do
    it "en frío no baja: nadie ha preguntado nunca" $
      -- Es el estado con el que arranca el proceso, y es lo que hace que un backend
      -- levantado y sin mirar cueste cero, como hoy.
      clockVerdict raceStartsAt False Nothing `shouldBe` ClockIdle

    it "con lector reciente y sin sesión, baja" $
      clockVerdict (addUTCTime 10 raceStartsAt) False (Just raceStartsAt)
        `shouldBe` ClockAsks

    it "con sesión y la página preguntando, el reloj se salta la foto: ya la pidió ella" $
      -- La página pregunta cada 10 s y el periodo son 20: con ella abierta, el reloj
      -- no añade ninguna foto.
      clockVerdict (addUTCTime 1 raceStartsAt) True (Just raceStartsAt)
        `shouldBe` ClockFeedAsked

    it "con sesión y nadie mirando, el reloj pide la foto: el reposo no manda ahí" $
      -- Es el caso por el que existe: lo que pasa en pista antes de abrir la página
      -- (los sectores de la mejor vuelta) solo se guarda si alguien pide la foto.
      clockVerdict (addUTCTime 3600 raceStartsAt) True (Just raceStartsAt)
        `shouldBe` ClockFeedPhoto

    it "con sesión y el proceso recién arrancado, también pide la foto" $
      clockVerdict raceStartsAt True Nothing `shouldBe` ClockFeedPhoto

    it "el borde del periodo de la foto: a los 19,9 s ya la pidió la página; a los 20, no" $
      map (\s -> clockVerdict (addUTCTime s raceStartsAt) True (Just raceStartsAt))
          [0, 19.9, 20, 39.9, 40]
        `shouldBe` [ ClockFeedAsked, ClockFeedAsked, ClockFeedPhoto, ClockFeedPhoto
                   , ClockFeedPhoto ]

    it "con sesión, un instante del futuro no cuenta como foto pedida: se pide" $
      -- Solo sale de un reloj del sistema que ha retrocedido; darlo por pedida
      -- dejaría sin foto todo lo que retrocedió, sin nadie mirando.
      clockVerdict raceStartsAt True (Just (addUTCTime 300 raceStartsAt))
        `shouldBe` ClockFeedPhoto

    it "el borde del reposo: justo antes baja, justo en el umbral ya no" $
      -- Dos periodos son 40 s. A los 39,9 todavía hay lector; a los 40 exactos, no.
      map (\s -> clockVerdict (addUTCTime s raceStartsAt) False (Just raceStartsAt))
          [0, 20, 39.9, 40, 60]
        `shouldBe` [ClockAsks, ClockAsks, ClockAsks, ClockIdle, ClockIdle]

    it "un instante del futuro cuenta como lector, no como reposo" $
      -- Solo sale de un reloj del sistema que ha retrocedido. Darlo por viejo
      -- pararía el reloj con la página abierta delante, que es el fallo caro.
      clockVerdict raceStartsAt False (Just (addUTCTime 300 raceStartsAt))
        `shouldBe` ClockAsks

    it "el umbral de reposo son dos periodos, y sale del periodo" $
      -- Si alguien cambia el periodo, el umbral tiene que moverse con él: son el
      -- mismo número dicho dos veces, no dos números que mantener sincronizados.
      openf1ClockIdle `shouldBe` 2 * openf1ClockPeriod

    prop "con la ventana del feed abierta nunca baja ni reposa, mire quien mire"
      neverAsksInsideFeedWindow

    prop "con la ventana abierta, la foto se salta solo si la página preguntó en el periodo"
      skipsPhotoOnlyWhenAskedThisPeriod

    it "el periodo de la foto es el del reloj" $
      -- La propiedad de arriba escribe 20 a mano; si el periodo cambia, esto avisa
      -- antes de que la propiedad pase a comprobar otra cosa.
      openf1ClockPeriod `shouldBe` 20

  describe "servedFromBox" $ do
    it "el borde del umbral: hasta los 40 s es reciente, desde ahí ya no" $
      -- Los 40 s solo se alcanzan con el reloj parado por reposo, muerto, o bajando
      -- contra un rechazo. Los tres son «no se ha vuelto a saber», y ése es el sello
      -- que la página ya sabe enseñar.
      map (fst . servedFromBox' raceStartsAt) [0, 20, 39.9, 40, 600]
        `shouldBe` [Recent, Recent, Recent, Cached, Cached]

    it "un instante del futuro cae en cached, no en reciente" $
      -- Solo sale de un reloj del sistema que ha retrocedido, y ahí no se puede
      -- afirmar que el dato sea de ahora.
      fst (servedFromBox' raceStartsAt (-300)) `shouldBe` Cached

    it "nunca devuelve fresh, porque aquí nadie ha salido a la red" $
      -- 'Fresh' afirma una bajada hecha en esta misma petición. Servir desde la caja
      -- no lo es, por reciente que sea. Se siembran las dos ramas a propósito: con
      -- solo las recientes, la aserción pasaría con la rama vieja rota.
      map (fst . servedFromBox' raceStartsAt) [0, 5, 19, 41, 3600]
        `shouldNotContain` [Fresh]

    it "el sello y el reloj de la sesión salen acordes, y por eso salen juntos" $
      -- Es lo que justifica devolver los dos de una sola función: separarlos dejaría
      -- escribir la combinación imposible, un sello que dice «de ahora» sobre un
      -- reloj parado. A los 12 s el restante baja de 5400 a 5388 y el reloj sigue
      -- andando; a los 41 se para y el número se queda donde estaba, diciendo cuánto
      -- quedaba cuando se supo.
      map (boxClock . servedFromBox' raceStartsAt) [12, 41]
        `shouldBe`
          [ (Recent, Just (SessionClock 5388 True))
          , (Cached, Just (SessionClock 5400 False))
          ]

  describe "freezeClock" $ do
    it "para el reloj sin borrarlo ni tocar nada más de la sesión" $
      -- El número guardado sigue diciendo cuánto quedaba al tomarse el dato, y el
      -- instante de esa toma viaja en cabecera propia. Lo que deja de ser cierto
      -- es que siga descontando.
      freezeClock raceSessionFixture
        `shouldBe` raceSessionFixture { siClock = Just (SessionClock 5400 False) }

    it "una sesión sin reloj sigue sin él, y no se inventa uno parado" $
      -- Cuatro de las cinco sesiones de un fin de semana llegan sin reloj en la
      -- foto; «parado en cero» diría que la sesión acabó.
      freezeClock (raceSessionFixture { siClock = Nothing })
        `shouldBe` raceSessionFixture { siClock = Nothing }

    it "un reloj ya parado no cambia, así que congelar dos veces es congelar una" $
      -- Es lo que pasa al servir desde la cache algo que ya salió de ella.
      (freezeClock . freezeClock) raceSessionFixture
        `shouldBe` freezeClock raceSessionFixture

  -- La otra punta del 59: entre el «finalizada» del feed y la vuelta de OpenF1 se sirve
  -- lo guardado, que era la última tabla del feed con «en marcha».
  describe "finaliseBox" $ do
    it "lo guardado del feed pasa a finalizada de oídas, con su instante y sus filas" $
      -- El instante no se mueve: lo servido sigue diciendo de cuándo es la tabla.
      finaliseBox finalisedHeard' (raceStartsAt, Feed, liveTableFixture)
        `shouldBe`
          ( raceStartsAt
          , Feed
          , liveTableFixture
              { liveSession = Just raceSessionFixture { siState = Just finalisedHeard' } }
          )

    it "lo que salió de OpenF1 no se toca, porque el feed no habla de esa tabla" $
      finaliseBox finalisedHeard' (raceStartsAt, OpenF1, liveTableFixture)
        `shouldBe` (raceStartsAt, OpenF1, liveTableFixture)

    it "sin sesión no hay a quién ponérselo, y la tabla sigue igual" $
      let bare = liveTableFixture { liveSession = Nothing }
       in finaliseBox finalisedHeard' (raceStartsAt, Feed, bare) `shouldBe` (raceStartsAt, Feed, bare)

    it "una finalizada deducida tras la bandera sigue deducida, y lleva su asterisco" $
      let derived = StateReading SessionFinalised Derived
       in finaliseBox derived (raceStartsAt, Feed, liveTableFixture)
            `shouldBe`
              ( raceStartsAt
              , Feed
              , liveTableFixture
                  { liveSession = Just raceSessionFixture { siState = Just derived } }
              )

  -- La bandera a cuadros, con los avisos REALES de control de carrera de la
  -- clasificación de Malasia (2026-10-03): la foto de las 07:50 aún traía la bandera
  -- de la P3, y la sesión empezaba a las 16:00 locales, 08:00 UTC.
  describe "feedSession con la bandera a cuadros" $ do
    let stateAt upTo field now =
          siState (feedSession now (malaysiaQuali upTo field))

    it "antes de empezar, la bandera de la sesión anterior no cuenta" $
      -- El estado del campo manda igual (Inactive), pero se comprueba también con
      -- «en marcha» para que la aserción no pase solo porque el campo no lo sea.
      map (\field -> stateAt "2026-10-03T07:50:00" field (malaysiaAt 7 50 0))
          ["Inactive", "Started"]
        `shouldBe`
          [ Just (StateReading SessionInactive Heard)
          , Just (StateReading SessionStarted Heard)
          ]

    it "tras la bandera de Q1, bandera a cuadros; con la verde de Q2, en marcha" $
      [ stateAt "2026-10-03T08:18:30" "Started" (malaysiaAt 8 18 30)
      , stateAt "2026-10-03T08:26:00" "Started" (malaysiaAt 8 26 0)
      ]
        `shouldBe`
          [ Just (StateReading SessionChequered Heard)
          , Just (StateReading SessionStarted Heard)
          ]

    it "sin otra salida en 12 min, finalizada y deducida; un segundo antes, todavía no" $
      -- La bandera de Q3 cayó a las 09:00:00. En la grabación el feed dijo
      -- «Finalised» a las 09:04:01, así que esto solo salta si no lo dice.
      map (stateAt "2026-10-03T09:01:00" "Started" . (\(h, m, s) -> malaysiaAt h m s))
          [(9, 1, 0), (9, 11, 59), (9, 12, 0)]
        `shouldBe`
          [ Just (StateReading SessionChequered Heard)
          , Just (StateReading SessionChequered Heard)
          , Just (StateReading SessionFinalised Derived)
          ]

    it "el 12 min está por encima de los descansos y del tramo hasta el Finalised" $
      -- 7:00 en los seis descansos medidos; 10:30 el tramo más largo medido entre
      -- la bandera y el «Finalised» (P2 de Bakú).
      (chequeredGrace > 7 * 60, chequeredGrace > 10 * 60 + 30) `shouldBe` (True, True)

    it "si el campo ya dice finalizada, gana el campo" $
      stateAt "2026-10-03T09:04:01" "Finalised" (malaysiaAt 9 4 1)
        `shouldBe` Just (StateReading SessionFinalised Heard)

    it "sin hora de inicio no cuenta ningún aviso" $
      let fs = (malaysiaQuali "2026-10-03T08:18:30" "Started") { fsStartDate = Nothing }
       in siState (feedSession (malaysiaAt 8 18 30) fs)
            `shouldBe` Just (StateReading SessionStarted Heard)

    it "una bandera de sector no es la de la pista" $
      let fs = (malaysiaQuali "2026-10-03T08:00:00" "Started")
                 { fsFlags = [FeedFlag "2026-10-03T08:10:00" "CHEQUERED" "Sector"] }
       in siState (feedSession (malaysiaAt 8 11 0) fs)
            `shouldBe` Just (StateReading SessionStarted Heard)

    it "un desfase negativo también se resta: 09:00 a −4 h es 13:00 UTC" $
      let fs flagAt = (malaysiaQuali "" "Started")
                        { fsStartDate = Just "2026-10-03T09:00:00"
                        , fsGmtOffset = Just "-04:00:00"
                        , fsFlags     = [FeedFlag flagAt "CHEQUERED" "Track"]
                        }
       in map (\flagAt -> siState (feedSession (malaysiaAt 13 31 0) (fs flagAt)))
              ["2026-10-03T12:59:00", "2026-10-03T13:30:00"]
            `shouldBe`
              [ Just (StateReading SessionStarted Heard)
              , Just (StateReading SessionChequered Heard)
              ]

    it "con bandera a cuadros la derecha de la banda calla, como rodando" $
      upNext (malaysiaAt 9 1 0)
          (Just raceSessionFixture { siState = Just (StateReading SessionChequered Heard) })
          [ScheduledSession "Race" 1308 "Bahrain Grand Prix" (malaysiaAt 31 0 0) (malaysiaAt 33 0 0)]
        `shouldBe` NextSilent

  -- El descanso alargado, con los avisos REALES de la clasificación Sprint de Singapur
  -- (2026-10-09, 20:30 locales, 12:30 UTC): la bandera de SQ1 a las 12:52:09, «START
  -- OF SQ2 WILL BE DELAYED» a las 12:55:03, «SQ2 WILL START AT 21:11» a las 13:05:26
  -- y la verde de SQ2 a las 13:11:00, 19 min después de la bandera.
  describe "feedSession con la parte siguiente anunciada" $ do
    let at :: Int -> Int -> Int -> UTCTime
        at h m s = addUTCTime (fromIntegral (h * 3600 + m * 60 + s))
                     (UTCTime (fromGregorian 2026 10 9) 0)
        notice u msg = FeedNotice u "Other" msg
        sq = (malaysiaQuali "" "Started")
               { fsName      = "Sprint Qualifying"
               , fsStartDate = Just "2026-10-09T20:30:00"
               , fsFlags     =
                   [ FeedFlag "2026-10-09T12:30:00" "GREEN"     "Track"
                   , FeedFlag "2026-10-09T12:35:52" "RED"       "Track"
                   , FeedFlag "2026-10-09T12:38:22" "CLEAR"     "Track"
                   , FeedFlag "2026-10-09T12:46:00" "GREEN"     "Track"
                   , FeedFlag "2026-10-09T12:52:09" "CHEQUERED" "Track"
                   , FeedFlag "2026-10-09T13:11:00" "GREEN"     "Track"
                   , FeedFlag "2026-10-09T13:21:00" "CHEQUERED" "Track"
                   , FeedFlag "2026-10-09T13:28:00" "GREEN"     "Track"
                   , FeedFlag "2026-10-09T13:36:00" "CHEQUERED" "Track"
                   ]
               , fsNotices   =
                   [ notice "2026-10-09T12:55:03" "START OF SQ2 WILL BE DELAYED"
                   , notice "2026-10-09T13:05:26" "SQ2 WILL START AT 21:11"
                   , notice "2026-10-09T13:25:01" "SQ3 WILL START AT 21:28"
                   ]
               }
        -- Lo que había llegado hasta `upTo`, servido en ese instante.
        upTo u fs = fs { fsFlags   = filter ((<= u) . ffUtc) (fsFlags fs)
                       , fsNotices = filter ((<= u) . fnUtc) (fsNotices fs) }
        stateAt fs (u, (h, m, s)) = siState (feedSession (at h m s) (upTo u fs))

    it "con el retraso de SQ2 anunciado, pasados los 12 min sigue la bandera, y con la verde, en marcha" $
      map (stateAt sq)
          [ ("2026-10-09T13:05:00", (13, 5, 0))
          , ("2026-10-09T13:10:59", (13, 10, 59))
          , ("2026-10-09T13:11:30", (13, 11, 30))
          ]
        `shouldBe`
          [ Just (StateReading SessionChequered Heard)
          , Just (StateReading SessionChequered Heard)
          , Just (StateReading SessionStarted Heard)
          ]

    it "la hora anunciada de la parte cuenta igual que el retraso" $
      let onlyTime = sq { fsNotices = filter ((/= "START OF SQ2 WILL BE DELAYED") . fnMessage) (fsNotices sq) }
       in stateAt onlyTime ("2026-10-09T13:06:00", (13, 6, 0))
            `shouldBe` Just (StateReading SessionChequered Heard)

    it "un retraso que no nombra parte no cuenta, y a los 12 min queda deducida" $
      let unnamed = sq { fsNotices = [notice "2026-10-09T12:55:03" "DELAYED START"] }
       in stateAt unnamed ("2026-10-09T13:05:00", (13, 5, 0))
            `shouldBe` Just (StateReading SessionFinalised Derived)

    it "un aviso anterior a la bandera no cuenta" $
      let early = sq { fsNotices = [notice "2026-10-09T12:50:00" "START OF SQ2 WILL BE DELAYED"] }
       in stateAt early ("2026-10-09T13:05:00", (13, 5, 0))
            `shouldBe` Just (StateReading SessionFinalised Derived)

    it "fuera de una clasificación el aviso no cuenta" $
      stateAt sq { fsType = "Practice" } ("2026-10-09T13:05:00", (13, 5, 0))
        `shouldBe` Just (StateReading SessionFinalised Derived)

    it "tras la última bandera, sin avisos, a los 12 min queda deducida como siempre" $
      map (stateAt sq)
          [ ("2026-10-09T13:47:59", (13, 47, 59))
          , ("2026-10-09T13:48:00", (13, 48, 0))
          ]
        `shouldBe`
          [ Just (StateReading SessionChequered Heard)
          , Just (StateReading SessionFinalised Derived)
          ]

  -- La roja, con los avisos REALES de control de carrera de la P3 de Malasia
  -- (2026-10-03, 12:30 locales, 04:30 UTC): «RED FLAG» a las 04:54:23, «TRACK
  -- CLEAR» a las 04:56:59 y la verde a las 04:59:00.
  describe "feedSession con bandera roja" $ do
    let p3 = (malaysiaQuali "" "Started")
               { fsName      = "Practice 3"
               , fsStartDate = Just "2026-10-03T12:30:00"
               , fsFlags     =
                   [ FeedFlag "2026-10-03T04:54:23" "RED"   "Track"
                   , FeedFlag "2026-10-03T04:56:59" "CLEAR" "Track"
                   , FeedFlag "2026-10-03T04:59:00" "GREEN" "Track"
                   ]
               }
        -- Los avisos que habían llegado hasta `upTo`, servidos en ese instante.
        stateAt (upTo, (h, m, s)) =
          siState (feedSession (malaysiaAt h m s) p3 { fsFlags = filter ((<= upTo) . ffUtc) (fsFlags p3) })

    it "de la roja a la verde dice «Bandera roja», también tras «TRACK CLEAR»" $
      map stateAt
          [ ("2026-10-03T04:54:30", (4, 54, 30))
          , ("2026-10-03T04:57:30", (4, 57, 30))
          , ("2026-10-03T04:59:30", (4, 59, 30))
          ]
        `shouldBe`
          [ Just (StateReading SessionRedFlag Heard)
          , Just (StateReading SessionRedFlag Heard)
          , Just (StateReading SessionStarted Heard)
          ]

    it "con la roja la derecha de la banda calla, y el punto no dice «en curso»" $ do
      upNext (malaysiaAt 4 55 0)
          (Just raceSessionFixture { siState = Just (StateReading SessionRedFlag Heard) })
          [ScheduledSession "Qualifying" 1308 "Bahrain Grand Prix" (malaysiaAt 8 0 0) (malaysiaAt 9 0 0)]
        `shouldBe` NextSilent
      sessionInProgress (Just SessionRedFlag) `shouldBe` False

    it "la roja viaja como «Red» y vuelve igual" $
      (sessionStateLabel SessionRedFlag, sessionStateFrom "Red")
        `shouldBe` ("Red", SessionRedFlag)

  -- Los avisos con hora, con los REALES de las grabaciones: la carrera de Malasia
  -- (2026-10-04, 15:00 locales, 07:00 UTC, salida retrasada por lluvia), la
  -- clasificación de Bakú (2026-09-25, 16:00 locales, 12:00 UTC, que salió a las 16:04)
  -- y la roja de la P3 de Malasia.
  describe "las cuentas de control de carrera" $ do
    let at :: Int -> Int -> Int -> Int -> UTCTime
        at d h m s = addUTCTime (fromIntegral (h * 3600 + m * 60 + s))
                       (UTCTime (fromGregorian 2026 10 d) 0)
        notice u msg = FeedNotice u "Other" msg
        race = (malaysiaQuali "" "Inactive")
                 { fsType = "Race", fsName = "Race", fsFlags = []
                 , fsStartDate = Just "2026-10-04T15:00:00"
                 , fsNotices =
                     [ notice "2026-10-04T06:42:57" "DELAYED START"
                     , notice "2026-10-04T07:30:05" "FORMATION LAP WILL START AT 15:40"
                     , notice "2026-10-04T07:45:11" "STARTING PROCEDURE SUSPENDED"
                     , notice "2026-10-04T08:22:26" "RACE WILL START AT 16:33"
                     ]
                 }
        upTo u fs = fs { fsNotices = filter ((<= u) . fnUtc) (fsNotices fs) }
        startAt u now = siStart (feedSession now (upTo u race))

    it "lee las formas grabadas, con la hora local que anuncian" $
      map parseNotice
          [ "DELAYED START", "START OF QUALIFYING WILL BE DELAYED", "START OF SQ2 WILL BE DELAYED"
          , "FORMATION LAP WILL START AT 15:40", "RACE WILL START AT 16:33"
          , "Q1 WILL START AT 16:04", "SQ3 WILL START AT 16:51"
          , "SESSION WILL RESUME AT 12:59", "TRACK SURFACE SLIPPERY IN TRACK SECTOR 5"
          ]
        `shouldBe`
          [ Just (NoticeDelay Nothing), Just (NoticeDelay Nothing), Just (NoticeDelay (Just 2))
          , Just (NoticeAt AnnouncedFormation (15, 40)), Just (NoticeAt AnnouncedStart (16, 33))
          , Just (NoticeAt (AnnouncedPart 1) (16, 4)), Just (NoticeAt (AnnouncedPart 3) (16, 51))
          , Just (NoticeAt AnnouncedResume (12, 59)), Nothing
          ]

    it "la hora local anunciada pasa a UTC con el desfase, y cerca de medianoche, al día siguiente" $ do
      announcedAt (8 * 3600) (at 4 8 22 26) (16, 33) `shouldBe` at 4 8 33 0
      announcedAt (8 * 3600) (at 4 15 50 0) (0, 10) `shouldBe` at 4 16 10 0

    it "Malasia: antes de los avisos nada; «DELAYED START» ya es «sale tarde», 18 min antes" $
      [ startAt "2026-10-04T06:40:00" (at 4 6 40 0)
      , startAt "2026-10-04T06:50:00" (at 4 6 50 0)
      ]
        `shouldBe` [Nothing, Just StartDelayed]

    it "Malasia: cuenta hasta la hora anunciada, y al pasarla sin salir, «sale tarde»" $
      [ startAt "2026-10-04T07:30:30" (at 4 7 30 30)
      , startAt "2026-10-04T07:41:00" (at 4 7 41 0)
      , startAt "2026-10-04T08:22:30" (at 4 8 22 30)
      ]
        `shouldBe`
          [ Just (StartAnnounced (Countdown "Vuelta de formación" 570))
          , Just StartDelayed
          , Just (StartAnnounced (Countdown "Salida" 630))
          ]

    it "sin ningún aviso, pasada la hora prevista también sale tarde" $
      startAt "" (at 4 7 0 30) `shouldBe` Just StartDelayed

    it "un aviso de más de 45 min antes de la hora prevista no cuenta" $
      let early = race { fsNotices = [notice "2026-10-04T06:14:00" "DELAYED START"] }
       in siStart (feedSession (at 4 6 50 0) early) `shouldBe` Nothing

    it "con la sesión ya en marcha no se habla de la salida" $
      siStart (feedSession (at 4 8 40 0) race { fsState = "Started" }) `shouldBe` Nothing

    it "la derecha de la banda dice lo que dice la sesión que sale tarde" $
      let shown = feedSession (at 4 8 22 30) (upTo "2026-10-04T08:22:30" race)
          cal   = [ScheduledSession "Practice 1" 1309 "Singapore Grand Prix" (at 9 8 30 0) (at 9 9 30 0)]
       in upNext (at 4 8 22 30) (Just shown) cal `shouldBe` NextAnnounced (Countdown "Salida" 630)

    it "Bakú: la clasificación que sale tarde cuenta hasta Q1; en la Sprint, hasta SQ1" $
      let baku name = (malaysiaQuali "" "Inactive")
                        { fsName = name, fsFlags = []
                        , fsStartDate = Just "2026-09-25T16:00:00"
                        , fsGmtOffset = Just "04:00:00"
                        , fsNotices = [ notice "2026-09-25T11:57:33" "START OF QUALIFYING WILL BE DELAYED"
                                      , notice "2026-09-25T12:00:34" "Q1 WILL START AT 16:04" ]
                        }
          now = addUTCTime (12 * 3600 + 60) (UTCTime (fromGregorian 2026 9 25) 0)
       in map (siStart . feedSession now . baku) ["Qualifying", "Sprint Qualifying"]
            `shouldBe` [ Just (StartAnnounced (Countdown "Q1" 180))
                       , Just (StartAnnounced (Countdown "SQ1" 180)) ]

    it "Bakú: en el descanso tras la bandera cuenta hasta la parte siguiente" $
      let bakuQ = (malaysiaQuali "" "Started")
                    { fsStartDate = Just "2026-09-25T16:00:00"
                    , fsGmtOffset = Just "04:00:00"
                    , fsFlags = [ FeedFlag "2026-09-25T12:04:00" "GREEN" "Track"
                                , FeedFlag "2026-09-25T12:22:00" "CHEQUERED" "Track" ]
                    , fsNotices = [ notice "2026-09-25T12:00:34" "Q1 WILL START AT 16:04"
                                  , notice "2026-09-25T12:27:16" "Q2 WILL START AT 16:29" ]
                    }
          now = addUTCTime (12 * 3600 + 28 * 60) (UTCTime (fromGregorian 2026 9 25) 0)
       in siCountdown (feedSession now bakuQ) `shouldBe` Just (Countdown "Q2" 60)

    it "P3 de Malasia: con la roja cuenta hasta la reanudación, y con la verde se acaba" $
      let p3 flags = (malaysiaQuali "" "Started")
                       { fsStartDate = Just "2026-10-03T12:30:00"
                       , fsFlags = flags
                       , fsNotices = [notice "2026-10-03T04:57:59" "SESSION WILL RESUME AT 12:59"]
                       }
          red   = [FeedFlag "2026-10-03T04:54:23" "RED" "Track"]
          green = red <> [FeedFlag "2026-10-03T04:59:00" "GREEN" "Track"]
       in [ siCountdown (feedSession (at 3 4 58 0) (p3 red))
          , siCountdown (feedSession (at 3 4 59 30) (p3 green))
          ]
            `shouldBe` [Just (Countdown "Reanuda" 60), Nothing]

    it "de lo guardado no sale ninguna cuenta: la salida anunciada pasa a «sale tarde»" $
      let shown = feedSession (at 4 8 22 30) (upTo "2026-10-04T08:22:30" race)
       in (siCountdown (freezeClock shown), siStart (freezeClock shown))
            `shouldBe` (Nothing, Just StartDelayed)

    it "la cuenta en texto lleva la hora local del final, y da la vuelta a medianoche" $ do
      countdownText (6 * 3600 + 27 * 60 + 16) (Countdown "Q2" 104) `shouldBe` "Q2 en 1:44 · 06:29"
      countdownText (23 * 3600 + 59 * 60) (Countdown "Salida" 120) `shouldBe` "Salida en 2:00 · 00:01"
      upNextLabel 0 NextDelayed `shouldBe` "Salida retrasada"
      catchUp 4 (NextAnnounced (Countdown "Salida" 10)) `shouldBe` NextAnnounced (Countdown "Salida" 6)

    it "en el sitio del estado la cuenta va detrás de la bandera, y con la sesión rodando no" $
      [ bandPieces (Just SessionChequered) Nothing (Just "Q2 en 1:44 · 06:29")
      , bandPieces (Just SessionStarted) Nothing (Just "Q2 en 1:44 · 06:29")
      ]
        `shouldBe`
          [ [PieceFlag ChequeredFlag, PieceWord "Q2 en 1:44 · 06:29"]
          , [PieceWord "En marcha"] ]

  describe "trackCondition" $ do
    it "nombra amarilla, Safety Car, roja, VSC y VSC terminando; lo despejado no dice nada" $
      map (trackCondition . (`FeedTrack` "")) ["1", "2", "4", "5", "6", "7", "3", ""]
        `shouldBe`
          [ Nothing, Just TrackYellow, Just TrackSafetyCar, Just TrackRed
          , Just TrackVsc, Just TrackVscEnding, Nothing, Nothing ]

    it "la sesión servida lleva la pista" $
      fmap (siTrack . feedSession raceServedAt)
           (trySession "{\"siTrack\":{\"status\":\"2\",\"message\":\"Yellow\"}}")
        `shouldBe` Right (Just TrackYellow)

    it "la bandera viaja como «Chequered», se lee y se dice «Bandera a cuadros»" $
      ( sessionStateLabel SessionChequered
      , sessionStateFrom "Chequered"
      , sessionStateWord SessionChequered
      , sessionInProgress (Just SessionChequered)
      , sessionIsLive SessionChequered
      )
        `shouldBe` ("Chequered", SessionChequered, "Bandera a cuadros", False, True)

  -- Los minutos en que OpenF1 vuelve sin estado: la sesión es la que el feed ya dio
  -- por finalizada, y eso se oyó.
  describe "inheritFinalised" $ do
    let quali meeting st =
          (namedSession "Qualifying" "Qualifying" meeting) { siState = st }
        kept = quali "Bahrain Grand Prix" (Just finalisedHeard')
        fresh = quali "Bahrain Grand Prix"

    it "la misma sesión sin estado hereda la finalizada que dijo el feed" $
      inheritFinalised (Just kept) (fresh Nothing)
        `shouldBe` fresh (Just finalisedHeard')

    it "gana a la deducida del calendario, así que no lleva asterisco" $
      inheritFinalised (Just kept) (fresh (Just (StateReading SessionFinalised Derived)))
        `shouldBe` fresh (Just finalisedHeard')

    it "otra sesión no hereda nada" $
      let practice = kept { siType = "Practice", siName = "Practice 3" }
       in inheritFinalised (Just practice) (fresh Nothing) `shouldBe` fresh Nothing

    it "otro gran premio no hereda; uno en blanco no desempata y hereda" $
      map (\m -> inheritFinalised (Just kept) (quali m Nothing))
          ["Azerbaijan Grand Prix", ""]
        `shouldBe`
          [quali "Azerbaijan Grand Prix" Nothing, quali "" (Just finalisedHeard')]

    it "lo guardado sin finalizar, o finalizado por deducción, no deja nada" $
      -- Se siembra también el caso que sí hereda, para que la aserción no pase con la
      -- función rota en el sentido de no heredar nunca.
      map (\st -> inheritFinalised (Just (quali "Bahrain Grand Prix" st)) (fresh Nothing))
          [ Just (StateReading SessionStarted Heard)
          , Just (StateReading SessionFinalised Derived)
          , Just finalisedHeard'
          ]
        `shouldBe` [fresh Nothing, fresh Nothing, fresh (Just finalisedHeard')]

    it "un estado oído de la propia sesión no se toca, y sin nada guardado tampoco" $
      ( inheritFinalised (Just kept) (fresh (Just (StateReading SessionStarted Heard)))
      , inheritFinalised Nothing (fresh Nothing)
      )
        `shouldBe` (fresh (Just (StateReading SessionStarted Heard)), fresh Nothing)

    it "aplicarlo dos veces es aplicarlo una" $
      -- Es lo que pasa en cada tic del reloj: lo que heredó se guarda y vuelve a ser
      -- lo guardado del tic siguiente.
      let once = inheritFinalised (Just kept) (fresh Nothing)
       in inheritFinalised (Just once) once `shouldBe` once

  -- El freno a OpenF1. Su número sale del presupuesto que el propio servicio publica
  -- en su rechazo —30 peticiones por minuto—, y lo que se ancla aquí es la cuenta,
  -- no solo el número: cambiar el hueco o el ritmo de la página tiene que seguir
  -- cabiendo.
  describe "openf1MinGap y stillRecent" $ do
    it "con la caja vacía y la fuente rechazando, el gasto cabe en el presupuesto" $
      -- Es el único camino en que el endpoint sale a la red. Sin freno, cada
      -- pregunta de la página reintenta: seis por minuto, de 1 a 5 peticiones cada
      -- una, hasta 30 por minuto con una sola pantalla. Con freno, la página solo
      -- puede saltarse preguntas enteras, así que los intentos caen cada 20 s.
      let poll      = liveRefreshSeconds
          gap       = ceiling openf1MinGap :: Int
          period    = until (>= gap) (+ poll) poll
          tries     = 60 `div` period
          worstCase = 5 * tries
       in (period, tries, worstCase <= 30) `shouldBe` (20, 3, True)

    it "el intento vale mientras no haya pasado el hueco, y el borde ya no" $
      map (\s -> stillRecent (addUTCTime s raceStartsAt) raceStartsAt) [0, 10, 14.9, 15, 20]
        `shouldBe` [True, True, True, False, False]

    it "un instante del futuro no vale: el reloj que retrocede deja intentarlo" $
      -- Darlo por reciente dejaría de intentarlo durante todo lo que el reloj haya
      -- retrocedido, y la pantalla se quedaría sin su oportunidad de tener dato.
      stillRecent raceStartsAt (addUTCTime 5 raceStartsAt) `shouldBe` False

  -- La simétrica de `freezeClock`: aquél para el reloj porque la fuente no contestó;
  -- éste lo pone al día porque no hacía falta preguntar y se sabe cuánto ha pasado.
  describe "advanceClock" $ do
    it "descuenta lo transcurrido de un reloj que anda" $
      advanceClock 12 raceSessionFixture
        `shouldBe` raceSessionFixture { siClock = Just (SessionClock 5388 True) }

    it "con la sesión detenida no descuenta nada: bandera roja" $
      -- El feed publica el reloj parado; descontarle inventaría que el tiempo corre.
      let stopped = raceSessionFixture { siClock = Just (SessionClock 5400 False) }
       in advanceClock 12 stopped `shouldBe` stopped

    it "no baja de cero" $
      advanceClock 12 (raceSessionFixture { siClock = Just (SessionClock 5 True) })
        `shouldBe` raceSessionFixture { siClock = Just (SessionClock 0 True) }

    it "sin reloj no inventa uno, y un transcurrido negativo no suma tiempo" $
      [ advanceClock 12 (raceSessionFixture { siClock = Nothing })
      , advanceClock (-30) raceSessionFixture
      ]
        `shouldBe` [raceSessionFixture { siClock = Nothing }, raceSessionFixture]

    it "cuenta segundos enteros, sin redondear hacia arriba" $
      -- El restante se publica en segundos; restar 13 por 12,9 s adelantaría el
      -- reloj respecto al de la fuente.
      advanceClock 12.9 raceSessionFixture
        `shouldBe` raceSessionFixture { siClock = Just (SessionClock 5388 True) }

  -- La otra fuente que sabe de qué sesión habla. Los fixtures son las respuestas
  -- REALES medidas el 2026-09-15, no formas inventadas: lo que se prueba incluye que
  -- el decode ignore los campos que no modela, y eso solo lo ancla la respuesta
  -- entera.
  describe "Of1Session y Of1Meeting" $ do
    it "decodifica /sessions e ignora las nueve claves que no modela" $
      tryOf1Sessions openF1SessionArray
        `shouldBe` Right
          [Of1Session "Race" "Race" 1294 raceStartsAt raceEndsAt (Just "Madring")]

    it "una sesión sin circuito entra igual, sin circuito" $
      -- Medido el 2026-09-23: las 131 sesiones de 2026 lo traen. Si un día falta,
      -- perder la sesión entera por él sería peor que enseñarla sin circuito.
      fmap (map osCircuit) (tryOf1Sessions openF1SessionNoCircuit)
        `shouldBe` Right [Nothing]

    it "decodifica /meetings, que es de donde sale el nombre del gran premio" $
      -- `/sessions` trae la clave del gran premio pero NO su nombre. Medido: lo más
      -- parecido que tiene son `location` y `country_name`, y ninguno es el nombre.
      tryOf1Meetings openF1MeetingArray
        `shouldBe` Right [Of1Meeting 1294 "Spanish Grand Prix"]

    it "una sesión sin tipo tumba la lista, y eso es lo que se quiere" $
      -- Al contrario que las banderas de `Of1Result`, aquí no hay default
      -- semánticamente correcto: una sesión de tipo vacío no existe. El fallo sube
      -- hasta el `try` del `Context` y sale como «no se sabe», sin tocar la tabla.
      tryOf1Sessions openF1SessionNoType `shouldSatisfy` isLeft

    it "ni sin hora de arranque, que es de lo que cuelga la ventana" $
      tryOf1Sessions openF1SessionNoStart `shouldSatisfy` isLeft

    it "ni sin hora de fin, que es de lo que cuelga el estado deducido" $
      tryOf1Sessions openF1SessionNoEnd `shouldSatisfy` isLeft

    it "la hora de fin llega con su desplazamiento, igual que la de arranque" $
      -- El fixture ya traía `date_end` desde que se escribió, a la espera de que al
      -- tipo le llegara el turno. Le llegó.
      fmap (map osEnd) (tryOf1Sessions openF1SessionArray)
        `shouldBe` Right [raceEndsAt]

    it "y un gran premio sin nombre, igual" $
      tryOf1Meetings openF1MeetingNoName `shouldSatisfy` isLeft

    it "ni sin clave, que es por donde se junta con sus sesiones" $
      tryOf1Meetings openF1MeetingNoKey `shouldSatisfy` isLeft

    it "la hora de arranque llega con el desplazamiento que OpenF1 emite" $
      -- `date_start` viene como «…T13:00:00+00:00» y no con la Z, así que lo que se
      -- afirma es que el decode lee ese desplazamiento y no lo ignora.
      fmap (map osStart) (tryOf1Sessions openF1SessionArray)
        `shouldBe` Right [raceStartsAt]

  describe "openf1Session" $ do
    it "sirve tipo, nombre, gran premio y circuito, y deja vacío lo que OpenF1 no publica" $
      -- Las vueltas y el reloj no son un degradado: OpenF1 no los emite. El estado
      -- queda vacío aquí porque se pregunta con la sesión rodando, que es justo el
      -- borde en el que no se deduce nada.
      openf1Session
        (addUTCTime (60 * 60) raceStartsAt)
        (Of1Session "Race" "Race" 1294 raceStartsAt raceEndsAt (Just "Madring"))
        "Spanish Grand Prix"
        `shouldBe` SessionInfo
          { siType    = "Race"
          , siName    = "Race"
          , siMeeting = "Spanish Grand Prix"
          , siCircuit = Just "Madring"
          , siState   = Nothing
          , siLaps    = Nothing
          , siClock   = Nothing
          , siPart    = Nothing
          , siTrack   = Nothing
          , siCountdown = Nothing
          , siStart   = Nothing
          , siEntries = []
          , siCutOffTime = Nothing
          }

    it "pasado el margen sí dice que acabó, y lo dice MARCADO como deducido" $
      -- La marca es lo único que separa esto de un `Finalised` oído del feed. Sin
      -- ella, el día que se repitan sesiones pasadas todas serían deducidas y nadie
      -- podría notarlo.
      siState
        (openf1Session
           (addUTCTime (4 * 3600) raceEndsAt)
           (Of1Session "Race" "Race" 1294 raceStartsAt raceEndsAt Nothing)
           "")
        `shouldBe` Just (StateReading SessionFinalised Derived)

    it "y en el borde sigue siendo «no se sabe», que es donde la medición manda" $
      -- Medido sobre la carrera 11369: arrancó cuatro minutos después de su
      -- `date_start` y acabó trece antes de su `date_end`, así que la deducción
      -- miente justo ahí. El hueco del tipo se conserva para ese tramo.
      map
        (\t ->
           siState
             (openf1Session
                t
                (Of1Session "Race" "Race" 1294 raceStartsAt raceEndsAt Nothing)
                ""))
        [raceStartsAt, raceEndsAt, addUTCTime (3 * 3600) raceEndsAt]
        `shouldBe` [Nothing, Nothing, Nothing]

    it "sin gran premio la sesión se sirve igual, con el nombre en blanco" $
      -- `/meetings` puede devolver el arreglo vacío, y desde el 2026-09-18 la caja
      -- del `Env` puede no tener la clave. El tipo y el nombre siguen diciendo de
      -- qué se habla, así que perder la sesión entera sería peor.
      openf1Session
        (addUTCTime (30 * 60) raceStartsAt)
        (Of1Session "Qualifying" "Qualifying" 1294 raceStartsAt raceEndsAt Nothing)
        ""
        `shouldBe` SessionInfo
          { siType    = "Qualifying"
          , siName    = "Qualifying"
          , siMeeting = ""
          , siCircuit = Nothing
          , siState   = Nothing
          , siLaps    = Nothing
          , siClock   = Nothing
          , siPart    = Nothing
          , siTrack   = Nothing
          , siCountdown = Nothing
          , siStart   = Nothing
          , siEntries = []
          , siCutOffTime = Nothing
          }

  -- Cómo el backend guarda el calendario: cada sesión con su gran premio, juntados
  -- por clave porque vienen de dos peticiones distintas.
  describe "schedule" $ do
    it "le pone a cada sesión el nombre de SU gran premio, no el del primero" $
      -- Hacen falta DOS grandes premios distintos y en orden cruzado respecto a las
      -- sesiones: con uno solo, o con los dos en el mismo orden, juntar por clave y
      -- coger el primero darían lo mismo y el caso pasaría sin afirmar nada.
      map ssGrandPrix
          (schedule
             [ scheduledIn 1294 "Race"     "Race"       raceStartsAt raceEndsAt
             , scheduledIn 1295 "Practice" "Practice 1" bakuP1       bakuP1End
             ]
             [ Of1Meeting 1295 "Azerbaijan Grand Prix"
             , Of1Meeting 1294 "Spanish Grand Prix"
             ])
        `shouldBe` ["Spanish Grand Prix", "Azerbaijan Grand Prix"]

    it "un gran premio que no está deja el nombre en blanco, y NO tira la sesión" $
      -- Sin nombre la sesión sigue sabiendo cuándo es, que es lo que decide la
      -- ventana del feed. Perderla entera por la etiqueta sería peor — el mismo
      -- criterio con el que `openf1Session` sirve la sesión sin gran premio.
      schedule [scheduled "Race" "Race" raceStartsAt raceEndsAt] []
        `shouldBe` [ScheduledSession "Race" 1294 "" raceStartsAt raceEndsAt]

    it "guarda el NOMBRE de la sesión y no su tipo" $
      -- Es lo que distingue un Sprint de una carrera larga, que comparten
      -- `session_type`, y de lo que cuelga el margen de `endMargin`.
      map ssName
          (schedule
             [ scheduled "Race"       "Sprint"            sprintStartsAt sprintEndsAt
             , scheduled "Qualifying" "Sprint Qualifying" sprintStartsAt sprintEndsAt
             ]
             [])
        `shouldBe` ["Sprint", "Sprint Qualifying"]

    it "conserva el orden de entrada" $
      -- Ordenar por hora es decisión de quien busque «la siguiente»; hacerlo aquí la
      -- escondería en una función que solo junta.
      map ssStart
          (schedule
             [ scheduled "Practice" "Practice 1" bakuP1 bakuP1End
             , scheduled "Race"     "Race"       raceStartsAt   raceEndsAt
             ]
             [])
        `shouldBe` [bakuP1, raceStartsAt]

  -- El índice que `schedule` usa para juntar y que el `Env` guarda para no volver a
  -- preguntar. Tiene DOS consumidores, y de ahí que exista aparte: escrito en los dos
  -- sitios, uno podría resolver distinto del otro.
  describe "meetingNames" $ do
    it "indexa por clave, que es por donde se busca en los dos consumidores" $
      meetingNames
        [ Of1Meeting 1295 "Azerbaijan Grand Prix"
        , Of1Meeting 1294 "Spanish Grand Prix"
        ]
        `shouldBe` Map.fromList
          [(1294, "Spanish Grand Prix"), (1295, "Azerbaijan Grand Prix")]

    it "sin grandes premios da el índice vacío, que es «no se sabe ninguno»" $
      -- Es lo que hay al arrancar el proceso, y lo que hace que se pregunte.
      meetingNames [] `shouldBe` Map.empty

    it "es el MISMO índice que schedule usa para juntar" $
      -- Lo que ancla que sacarlo de `schedule` no cambió a quién nombra cada sesión:
      -- el nombre que sale del calendario y el que sale de la caja son uno.
      map ssGrandPrix
          (schedule
             [scheduled "Race" "Race" raceStartsAt raceEndsAt]
             [Of1Meeting 1294 "Spanish Grand Prix"])
        `shouldBe` [Map.findWithDefault "" 1294
                      (meetingNames [Of1Meeting 1294 "Spanish Grand Prix"])]

  -- Qué enseña la mitad derecha de la banda. Cada caso sale de una decisión distinta
  -- y por eso hay uno por cada una, más los controles que impiden que pasen por el
  -- motivo equivocado.
  describe "upNext" $ do
    it "sin calendario dice que aún no se sabe" $
      -- El estado con el que arranca el proceso, y dura lo que tarde la primera
      -- petición del calendario.
      upNext bakuLongBefore (Just (stateOf SessionFinalised)) []
        `shouldBe` NextUnknown

    it "con la sesión rodando, calla y le deja el ancho" $
      upNext bakuLongBefore (Just (stateOf SessionStarted)) bakuWeekend
        `shouldBe` NextSilent

    it "y un estado que no se reconoce cuenta como rodando" $
      -- El mismo criterio que `sessionIsLive`: lo desconocido sigue dando directo,
      -- así que tampoco es momento de hablar de la siguiente.
      upNext bakuLongBefore (Just (stateOf (SessionUnknown "Warmup"))) bakuWeekend
        `shouldBe` NextSilent

    it "con la sesión aún sin empezar, cuenta a ELLA y sin etiqueta" $
      -- Desde que se le pregunta, el feed enseña la sesión sin empezar, así que este
      -- caso se ve de verdad. Lo que hace falta saber entonces es cuándo arranca lo que
      -- se está mirando, no lo de después — y nombrarlo sobraría: ya está al lado.
      upNext bakuInLead (Just (stateOf SessionInactive)) bakuWeekend
        `shouldBe` NextStartsIn (10 * 60)

    it "acabada, cuenta a la siguiente y la nombra por su gran premio" $
      -- Fuera del fin de semana la izquierda dice otro gran premio, así que el de la
      -- derecha es información nueva.
      upNext raceEndsAt (Just (stateOf SessionFinalised)) bakuWeekend
        `shouldBe` NextAfter "Azerbaijan Grand Prix" (10 * 86400 + 17 * 3600 + 30 * 60)

    it "pero DENTRO de su fin de semana la nombra por la sesión, no repitiendo el GP" $
      -- Si la izquierda ya dice «Azerbaijan Grand Prix», repetirlo a la derecha no
      -- diría nada que no estuviera en pantalla; el nombre de la sesión sí.
      upNext
        bakuDuringP1
        (Just (sessionAt "Azerbaijan Grand Prix" SessionFinalised))
        bakuWeekend
        `shouldBe` NextAfter "Practice 2" (3 * 3600)

    it "sin estado conocido también cuenta a la siguiente" $
      -- Es el caso de OpenF1 en el borde, donde `derivedState` calla: no saber en qué
      -- punto está no es saber que está rodando.
      upNext raceEndsAt (Just (stateless "Spanish Grand Prix")) bakuWeekend
        `shouldBe` NextAfter "Azerbaijan Grand Prix" (10 * 86400 + 17 * 3600 + 30 * 60)

    it "coge la de arranque más próximo, no la primera de la lista" $
      -- El control del orden: el calendario llega ordenado, pero depender de eso
      -- ataría esto a una promesa de OpenF1 que nadie ha comprobado.
      upNext bakuLongBefore (Just (stateOf SessionFinalised)) (reverse bakuWeekend)
        `shouldBe` NextAfter "Azerbaijan Grand Prix" (90 * 60)

    it "y descarta las que ya arrancaron" $
      -- Con P1 ya empezada, la siguiente es P2 y no ella misma.
      upNext bakuDuringP1 (Just (stateOf SessionFinalised)) bakuWeekend
        `shouldBe` NextAfter "Azerbaijan Grand Prix" (3 * 3600)

    it "sin nombre de gran premio se cae al de la sesión, que siempre hay" $
      -- `/meetings` puede no haber contestado. Sin etiqueta la cuenta atrás no diría
      -- a qué cuenta.
      upNext bakuLongBefore (Just (stateOf SessionFinalised)) namelessWeekend
        `shouldBe` NextAfter "Practice 1" (90 * 60)

  -- El margen de la hora de FIN, simétrico de `feedWindowLead`. Sale de multiplicar
  -- la duración prevista, así que los dos números que ya estaban decididos no se
  -- escriben en ningún sitio: se comprueba que salgan.
  describe "endMargin" $ do
    it "reproduce los dos números ya decididos sin tenerlos escritos" $
      -- 3 h para una carrera de 120 min y 45 min para unas prácticas de 60.
      [endMargin "Race" (120 * 60), endMargin "Practice 1" (60 * 60)]
        `shouldBe` [3 * 3600, 45 * 60]

    it "el Sprint coge el margen corto aunque su TIPO sea Race" $
      -- El caso que la regla por tipo se comía, y está medido: el `session_type` del
      -- Sprint es `"Race"`, así que por tipo se llevaría 3 h siendo de 60 min. El
      -- nombre es lo que los distingue, y es además lo que la banda ya enseña.
      endMargin "Sprint" (60 * 60) `shouldBe` 45 * 60

    it "y la Sprint Qualifying, con su duración propia de 44 min" $
      -- Otra medida del calendario real: no dura los 60 de una clasificación larga.
      endMargin "Sprint Qualifying" (44 * 60) `shouldBe` 33 * 60

    it "el nombre se compara recortado y en minúsculas" $
      -- Mismo criterio que `sessionStateFrom`: un valor de cable atraviesa cosas que
      -- no controlamos.
      map (\n -> endMargin n (120 * 60)) ["Race", "race", "  RACE  "]
        `shouldBe` replicate 3 (3 * 3600)

    it "el suelo tapa una duración ridícula, y también una negativa" $
      -- Ninguna de las dos está observada —las 45 sesiones publicadas van de 44 a
      -- 120 min—: son cotas de cordura sobre un calendario que no controlamos.
      map (endMargin "Practice 1") [5 * 60, 0, negate (60 * 60)]
        `shouldBe` replicate 3 (30 * 60)

    it "y el techo tapa una absurdamente larga" $
      endMargin "Race" (24 * 3600) `shouldBe` 4 * 3600

  describe "derivedState" $ do
    it "no dice nada mientras no se cruce el margen, NI JUSTO AL CRUZARLO" $
      -- El borde es lo que esta función existe para no cruzar: la carrera acaba a
      -- las 15:00 previstas, el margen son 3 h, y a las 18:00 en punto todavía no se
      -- afirma nada. Un segundo después, sí.
      map
        (\t -> derivedState t (scheduled "Race" "Race" raceStartsAt raceEndsAt))
        [ raceStartsAt
        , raceEndsAt
        , addUTCTime (3 * 3600) raceEndsAt
        , addUTCTime (3 * 3600 + 1) raceEndsAt
        ]
        `shouldBe` [Nothing, Nothing, Nothing, Just SessionFinalised]

    it "solo deduce que acabó, nunca que empezó ni que está rodando" $
      -- Entre el arranque y el fin previstos no se dice nada, y no es un hueco sin
      -- rellenar: está medido que ahí las horas mienten —la 11369 arrancó cuatro
      -- minutos tarde—, así que afirmar sería inventar.
      derivedState
        (addUTCTime (60 * 60) raceStartsAt)
        (scheduled "Race" "Race" raceStartsAt raceEndsAt)
        `shouldBe` Nothing

    it "el Sprint se da por acabado antes de que empiece la sesión siguiente" $
      -- El caso concreto de Singapur, medido el 2026-09-17: el Sprint acaba a las
      -- 10:00 y la clasificación siguiente empieza a las 13:00. Con el margen por
      -- tipo la banda se pasaría esas tres horas sin poder decir que acabó, y al
      -- poder decirlo ya habría empezado otra sesión.
      derivedState
        (addUTCTime (60 * 60) sprintEndsAt)
        (scheduled "Race" "Sprint" sprintStartsAt sprintEndsAt)
        `shouldBe` Just SessionFinalised

    it "y la carrera larga NO, con ese mismo retraso" $
      -- El control negativo del caso de arriba: si las dos se dieran por acabadas a
      -- la hora, el test anterior pasaría sin que el nombre discriminara nada.
      derivedState
        (addUTCTime (60 * 60) raceEndsAt)
        (scheduled "Race" "Race" raceStartsAt raceEndsAt)
        `shouldBe` Nothing

  -- El único caso de la suite que mira un parámetro de salida en vez de un dato de
  -- entrada. Existe porque el fallo que ancla no se ve leyendo el código ni
  -- ejecutando las otras pruebas: la URL la construye `req`, y una forma mal armada
  -- vuelve como 404 que el `Context` se traga.
  describe "endsAfter" $
    it "pega el operador al valor, sin un = entre medias" $
      -- Con `("date_end>=" =:)` sale `date_end%3E%3D=2026-…` y OpenF1 responde
      -- 404 «No results found», así que el calendario no llega nunca y la ventana
      -- del feed no se cierra jamás. Medido el 2026-09-15 contra las dos formas.
      queryParamToList (endsAfter "2026-09-24T08:30:00Z")
        `shouldBe` [("date_end>=2026-09-24T08:30:00Z", Nothing)]

  -- La línea que deja cada petición a OpenF1: una petición, una línea, para poder
  -- contarlas y ver cuáles rechaza la fuente.
  describe "requestLine" $ do
    it "una buena: instante con milisegundos, ruta con parámetros, código y duración" $
      requestLine fetchInstant "position" latest 0.7984 (Answered 200 "")
        `shouldBe`
          "2026-09-11T14:03:22.123Z [openf1] position?session_key=latest 200 0.798 s"

    it "un rechazo lleva su texto" $
      requestLine fetchInstant "intervals" latest 0.471
        (Answered 404 "{\"detail\":\"No results found.\"}")
        `shouldBe`
          "2026-09-11T14:03:22.123Z [openf1] intervals?session_key=latest 404 0.471 s: \
          \{\"detail\":\"No results found.\"}"

    it "sin código, --- y la causa" $
      requestLine fetchInstant "position" latest 5.0021 (Unanswered "ResponseTimeout")
        `shouldBe`
          "2026-09-11T14:03:22.123Z [openf1] position?session_key=latest --- 5.002 s: \
          \ResponseTimeout"

    it "un parámetro sin valor sale pegado, como lo manda req" $
      requestLine fetchInstant "sessions"
        (queryParamToList (endsAfter "2026-09-24T08:30:00Z")) 0.5 (Answered 200 "")
        `shouldBe`
          "2026-09-11T14:03:22.123Z [openf1] sessions?date_end>=2026-09-24T08:30:00Z \
          \200 0.500 s"

    it "sin parámetros, la ruta sola" $
      requestLine fetchInstant "drivers" [] 0.5 (Answered 200 "")
        `shouldBe` "2026-09-11T14:03:22.123Z [openf1] drivers 200 0.500 s"

    it "siempre una línea: los saltos del texto se vuelven espacios" $
      requestLine fetchInstant "laps" [] 1 (Answered 429 "{\n\"detail\": \"x\"\n}")
        `shouldBe` "2026-09-11T14:03:22.123Z [openf1] laps 429 1.000 s: { \"detail\": \"x\" }"

    it "el texto se corta a 200 caracteres" $
      requestLine fetchInstant "laps" [] 1 (Answered 500 (BC.replicate 300 'x'))
        `shouldBe`
          "2026-09-11T14:03:22.123Z [openf1] laps 500 1.000 s: " <> T.replicate 200 "x"

  -- Qué sale sin OPENF1_LOG: los fallos, salvo el 404 con el que OpenF1 dice que aún
  -- no hay datos (/intervals fuera de carrera lo da en cada refresco).
  describe "alwaysWritten" $ do
    it "una buena, no" $
      alwaysWritten (Answered 200 "") `shouldBe` False

    it "el 404, no" $
      alwaysWritten (Answered 404 "{\"detail\":\"No results found.\"}") `shouldBe` False

    it "el 429, sí" $
      alwaysWritten (Answered 429 "") `shouldBe` True

    it "un 5xx, sí" $
      alwaysWritten (Answered 503 "") `shouldBe` True

    it "sin respuesta, sí" $
      alwaysWritten (Unanswered "ResponseTimeout") `shouldBe` True

  describe "answerOf" $ do
    it "techo vencido: solo el motivo, sin la petición que arrastra la excepción" $
      answerOf
        (VanillaHttpException
           (Client.HttpExceptionRequest Client.defaultRequest Client.ResponseTimeout))
        `shouldBe` Unanswered "ResponseTimeout"

    it "un 200 que no se deja leer: el texto de aeson" $
      answerOf (JsonHttpException "Error in $: expected Array")
        `shouldBe` Unanswered "Error in $: expected Array"

  -- El freno de OpenF1: 3 salidas por ventana de 1,2 s. Las horas van de la más
  -- reciente a la más vieja, como las guarda el freno.
  describe "brakeWait" $ do
    let ago s = addUTCTime (negate s) fetchInstant
    it "sin salidas previas, sale ya" $
      brakeWait fetchInstant [] `shouldBe` 0

    it "con dos en la ventana, la tercera sale ya" $
      brakeWait fetchInstant [ago 0.16, ago 0.34] `shouldBe` 0

    it "con tres en la ventana, espera a que la más vieja salga de ella" $
      -- Un refresco del directo: drivers, position e intervals salen en 0,34 s, y
      -- laps espera hasta 1,2 s después de drivers.
      brakeWait fetchInstant [ago 0.16, ago 0.34, ago 0.5] `shouldBe` 0.7

    it "si la más vieja de las tres ya salió de la ventana, sale ya" $
      brakeWait fetchInstant [ago 0.2, ago 0.4, ago 1.3] `shouldBe` 0

    it "una hora del futuro (reloj que retrocede) no espera más que la ventana" $
      brakeWait fetchInstant [ago (-10), ago (-11), ago (-12)] `shouldBe` brakeWindow

  -- Cuándo merece la pena pedirle la foto al feed, que cuesta 16-23 s. Todos los
  -- casos son sobre instantes fijos y sin reloj real: la función es pura justo para
  -- que esto se pueda afirmar sin levantar red ni esperar a un fin de semana.
  describe "feedWindowOpen" $ do
    it "sin calendario se pregunta: no saber no es saber que no hay nada" $
      -- Es el estado del proceso recién arrancado, y el de un backend que reinicia
      -- durante una sesión, cuando OpenF1 responde 401 y no puede decirle la hora.
      -- El precio es la foto; el beneficio, no perder el directo.
      feedWindowOpen bakuDuringP1 [] Nothing `shouldBe` True

    it "con la sesión aún lejos, no se pregunta" $
      -- Hora y media antes de Bakú P1, con la ventana aún sin abrir.
      feedWindowOpen bakuLongBefore [bakuP1, bakuP2] Nothing `shouldBe` False

    it "dentro del margen, antes de la hora prevista, ya se pregunta" $
      -- Diez minutos antes, dentro del margen.
      feedWindowOpen bakuInLead [bakuP1, bakuP2] Nothing `shouldBe` True

    it "justo en la apertura ya se pregunta, no un instante después" $
      -- La frontera cae del lado de preguntar: el criterio es «ya llegó», no «pasó
      -- de sobra». Se escribe con la constante y no con el número para que moverla
      -- no deje este caso afirmando otra cosa.
      feedWindowOpen
        (addUTCTime (negate feedWindowLead) bakuP1)
        [bakuP1]
        Nothing
        `shouldBe` True

    it "con la sesión rodando y sin señal de fin, sigue abierta" $
      feedWindowOpen bakuDuringP1 [bakuP1, bakuP2] Nothing `shouldBe` True

    it "vista la finalización, se cierra" $
      feedWindowOpen bakuAfterP1 [bakuP1, bakuP2] (Just bakuP1Finalised)
        `shouldBe` False

    it "y verla dos veces cierra igual, que es lo que la repetición exige" $
      -- El campo de estado emite `Finalised` más de una vez (2026-09-14 (k)). Aquí
      -- la señal se COMPARA contra la hora de arranque y no se consume, así que un segundo
      -- aviso de la misma sesión no adelanta nada. Un «avanza a la siguiente» se
      -- habría saltado una sesión entera.
      feedWindowOpen bakuAfterP1 [bakuP1, bakuP2] (Just bakuP1FinalisedAgain)
        `shouldBe` False

    it "y se reabre sola cuando la siguiente sesión cruza su apertura" $
      -- Sin olvidar la señal ni mover ningún puntero: la hora de arranque de P2 es
      -- posterior a la finalización de P1, y con eso basta.
      feedWindowOpen bakuInLeadP2 [bakuP1, bakuP2] (Just bakuP1Finalised)
        `shouldBe` True

    it "el orden del calendario no decide nada" $
      -- OpenF1 lo sirve ordenado, pero apoyarse en eso sería apoyarse en algo que
      -- nadie promete: lo que manda es la apertura más reciente, no la última fila.
      feedWindowOpen bakuInLeadP2 [bakuP2, bakuP1] (Just bakuP1Finalised)
        `shouldBe` True

    it "la finalización de la sesión anterior, vista con la ventana ya abierta, no la cierra" $
      -- La P1 de Malasia: hasta anunciarla, el feed siguió dando la carrera de Bakú
      -- por finalizada, y esa señal cerró la ventana de la P1 hasta la de la P2.
      -- Ninguna sesión acaba antes de empezar: lo visto antes de su hora es de otra.
      feedWindowOpen malasiaInLeadP1 [malasiaP1] (Just malasiaBakuStillShown)
        `shouldBe` True

    it "y la de la propia sesión, vista después de su hora, sí la cierra" $
      -- El control del caso anterior: una regla que nunca cerrara también lo pasaría.
      feedWindowOpen malasiaAfterP1 [malasiaP1] (Just malasiaP1Finalised)
        `shouldBe` False

    prop "abierta la ventana, solo la cierra una finalización desde la hora de arranque"
      closesOnlyFromStart

    it "la finalizada que dijo el feed cierra; la deducida tras la bandera, no" $
      -- La clasificación Sprint de Singapur: la deducida a los 12 min de la bandera
      -- de SQ1 cerró la ventana, y la SQ2 y la SQ3 no se vieron.
      map closesFeedWindow
          [StateReading SessionFinalised Heard, StateReading SessionFinalised Derived]
        `shouldBe` [True, False]

  -- Lo que `GET /fastf1/live` entrega: la tabla y la sesión en la MISMA foto, así
  -- que hablan del mismo instante. Los fixtures llevan las claves que el
  -- microservicio emite, no una forma inventada.
  describe "FeedLive" $ do
    it "lee las dos mitades de una respuesta completa" $
      fmap (fmap fsState . flSession) (tryLive feedLiveFull)
        `shouldBe` Right (Just "Started")

    it "y sus filas, que son las de siempre" $
      fmap (map frDriver . flRows) (tryLive feedLiveFull)
        `shouldBe` Right ["VER", "LEC"]

    it "la sesión puede ser null, y eso es «el feed no la anunció»" $
      -- No es lo mismo que anunciarla con los campos vacíos: aquello sí llega como
      -- un FeedSession con sus defaults, y esto como la ausencia que es.
      fmap flSession (tryLive feedLiveWithoutSession)
        `shouldBe` Right Nothing

    it "el campo de sesión puede faltar entero, con el mismo significado" $
      fmap flSession (tryLive feedLiveSessionAbsent)
        `shouldBe` Right Nothing

    it "la tabla vacía decodifica: es «no hay sesión rodando», no un fallo" $
      -- Es la señal con la que `Handler.Live.Context` baja a OpenF1, así que
      -- tratarla como error cerraría ese camino.
      fmap flRows (tryLive feedLiveEmpty) `shouldBe` Right []

    it "sin el campo de las filas NO decodifica, que es lo que la manda a la cache" $
      -- La asimetría con la sesión es deliberada: una respuesta sin filas es
      -- legítima, y una sin el campo entero es un contrato roto. Fundirlos haría
      -- que un microservicio averiado se leyera como «no hay sesión».
      isLeft (tryLive feedLiveRowsAbsent) `shouldBe` True

  -- Los valores son los que el microservicio emitió sobre la clasificación de Malasia
  -- reconstruida a las 08:30 UTC, ya en la Q2.
  describe "lo que el feed sabe de una clasificación" $ do
    it "la sesión trae la parte, cuántos entran, el corte y la pista" $
      fmap (\s -> (fsPart s, fsEntries s, fsCutOffTime s, fsTrack s))
           (trySession feedSessionMalaysiaQ2)
        `shouldBe` Right (Just 2, [22, 16, 10], Just "1:43.230", Just (FeedTrack "1" "AllClear"))

    it "y los avisos que no son de bandera, con su hora en UTC y su texto" $
      fmap fsNotices (trySession feedSessionMalaysiaQ2)
        `shouldBe` Right
          [ FeedNotice "2026-10-03T08:22:15" "Other"
              "FIA STEWARDS: Q1 INCIDENT INVOLVING CAR 18 (STR) NOTED - FAILING TO FOLLOW \
              \RACE DIRECTORS INSTRUCTIONS - MAXIMUM DELTA TIME"
          ]

    it "sin nada de eso decodifica igual: fuera de clasificación no existe" $
      -- Una práctica no trae parte, ni entradas, ni corte; y un microservicio viejo
      -- no trae ni los avisos ni la pista. Ninguna de las dos cosas es un fallo.
      fmap (\s -> (fsPart s, fsEntries s, fsCutOffTime s, fsTrack s, fsNotices s))
           (trySession "{}")
        `shouldBe` Right (Nothing, [], Nothing, Nothing, [])

    it "una fila trae la mejor de cada parte, si está eliminada y si va sin 107 %" $
      -- VER lidera la Q2 sin vuelta en ella: su BestLapTime ya se vació, y la de la
      -- Q1 solo sobrevive en la lista por partes.
      fmap (map (\r -> (frDriver r, frPartBests r, frKnockedOut r, frCutoff r)))
           (tryFeedRows feedRowsMalaysiaQ2)
        `shouldBe` Right
          [ ("VER", ["1:36.477", "-", "-"], False, False)
          , ("PER", ["1:38.933", "-", "-"], True, False)
          , ("ANT", ["-", "-", "-"], False, True)
          ]

    it "la sesión servida lleva la parte, y el 0 de antes de empezar no es una parte" $ do
      fmap (siPart . feedSession raceServedAt) (trySession feedSessionMalaysiaQ2)
        `shouldBe` Right (Just 2)
      fmap (siPart . feedSession raceServedAt) (trySession "{\"siPart\":0}")
        `shouldBe` Right Nothing
      fmap (siPart . feedSession raceServedAt) (trySession "{}")
        `shouldBe` Right Nothing

    it "la tabla servida lleva lo de cada fila: la mejor de cada parte, eliminada y sin 107 %" $
      fmap (map (\r -> (ltDriver r, ltPartBests r, ltKnockedOut r, ltCutoff r)) . feedRows)
           (tryFeedRows feedRowsMalaysiaQ2)
        `shouldBe` Right
          [ ("VER", ["1:36.477", "-", "-"], False, False)
          , ("ANT", ["-", "-", "-"], False, True)
          , ("PER", ["1:38.933", "-", "-"], True, False)
          ]

    it "Best Lap es la menor de todas las partes: el feed vacía la suya en cada parte" $
      -- VER y PER, de la Q2 de Malasia: VER sin vuelta en ella y PER eliminado; ANT
      -- sin ninguna vuelta todavía.
      fmap (map (\r -> (ltDriver r, ltBestLap r)) . feedRows) (tryFeedRows feedRowsMalaysiaQ2)
        `shouldBe` Right [("VER", "1:36.477"), ("ANT", "-"), ("PER", "1:38.933")]

    it "con vuelta en varias partes gana la menor, sea de la parte que sea" $ do
      -- VER y HAD en la Q3 de Malasia (08:52 UTC): VER aún sin vuelta en la Q3, HAD
      -- con la más rápida de la sesión en ella.
      sessionBestLap "-" ["1:36.477", "1:35.696", "-"] `shouldBe` "1:35.696"
      sessionBestLap "1:35.558" ["1:36.898", "1:36.192", "1:35.558"] `shouldBe` "1:35.558"

    it "fuera de clasificación no cambia nada, ni lo que no es un tiempo" $
      map (uncurry sessionBestLap) [("1:29.345", []), ("-", []), ("", [])]
        `shouldBe` ["1:29.345", "-", ""]

    it "y la sesión servida, cuántos entran en cada parte y el 107 %" $
      fmap ((\s -> (siEntries s, siCutOffTime s)) . feedSession raceServedAt)
           (trySession feedSessionMalaysiaQ2)
        `shouldBe` Right ([22, 16, 10], Just "1:43.230")

    it "mientras la página espera, el 107 % no se enseña: diría que alguien ya marcó" $
      siCutOffTime (waitingSession raceSessionFixture {siCutOffTime = Just "1:43.230"})
        `shouldBe` Nothing

    it "sin esos campos la fila es la de siempre: ni eliminada ni fuera del 107 %" $
      fmap (map (\r -> (frPartBests r, frKnockedOut r, frCutoff r)))
           (tryFeedRows feedTableMinimal)
        `shouldBe` Right [([], False, False)]

  describe "parseRemaining y parseFeedInstant" $ do
    it "lee las dos longitudes que una duración puede tener" $
      map parseRemaining ["01:59:59", "02:00:00", "00:00:00", "15:00"]
        `shouldBe` [Just 7199, Just 7200, Just 0, Just 900]

    it "lo que no es una duración entera da Nothing, sin quedarse con la mitad" $
      -- Un reloj a medio leer es peor que ninguno: diría una hora que nadie dio.
      map parseRemaining ["", "1:2:3:4", "01:xx:59", "01:59", "-1:00:00", "1h"]
        `shouldBe` [Nothing, Nothing, Nothing, Just 119, Nothing, Nothing]

    it "lee el instante con cualquier precisión de fracción, y sin ella" $
      -- Medido: siete dígitos en la foto inicial y dos en un delta de la misma
      -- carrera, así que fijar la precisión habría roto con uno de los dos.
      map (fmap (const ()) . parseFeedInstant)
        [ "2026-09-13T12:58:15.4797492Z"
        , "2026-09-13T13:04:05.01Z"
        , "2026-09-13T13:04:05Z"
        ]
        `shouldBe` [Just (), Just (), Just ()]

    it "un instante con otra forma da Nothing" $
      map parseFeedInstant ["", "13:04:05", "2026-09-13 13:04:05"]
        `shouldBe` [Nothing, Nothing, Nothing]

  -- El único caso del cliente del feed que no necesita red: su techo de duración.
  -- Existe porque el número no es una preferencia sino una medición, y bajarlo
  -- rompería el peldaño entero sin que nada más se pusiera rojo.
  describe "feedTimeoutSeconds" $
    it "deja margen sobre lo que cuesta una foto del feed, sin esperar lo imposible" $ do
      -- Medido el 2026-09-12 sin sesión en marcha: 16,87, 17,00 y 16,99 s. Con un
      -- techo por debajo, TODA respuesta buena se leería como fallo del feed, y un
      -- fallo del feed sirve desde la cache sin intentar OpenF1. El margen tiene que
      -- cubrir además el solape de dos clientes, que ya se vio pasarse de 20 s.
      feedTimeoutSeconds `shouldSatisfy` (>= 30)
      -- Por arriba, el propio microservicio se rinde: aplica su plazo de 15 s tres
      -- veces, así que pasados ~45 s contesta 503 y esperar más es esperar algo que
      -- ya no va a llegar.
      feedTimeoutSeconds `shouldSatisfy` (<= 45)

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

  describe "sessionTitle" $ do
    it "junta el gran premio y el nombre, y deja fuera el tipo" $
      -- El tipo repetiría la palabra: medido sobre el calendario de 2026, tipo y
      -- nombre coinciden en 50 de las 131 sesiones, y son justo la carrera y la
      -- clasificación.
      sessionTitle (namedSession "Race" "Race" "Spanish Grand Prix")
        `shouldBe` "Spanish Grand Prix · Race"

    it "el nombre distingue las formas que el tipo confunde" $
      -- `Sprint` llega con tipo `Race` y `Sprint Qualifying` con tipo
      -- `Qualifying`, que son los mismos que la carrera y la clasificación
      -- largas: con el tipo dentro, los cuatro modos no se distinguirían.
      map sessionTitle
          [ namedSession "Race"       "Sprint"            "Azerbaijan Grand Prix"
          , namedSession "Qualifying" "Sprint Qualifying" "Azerbaijan Grand Prix"
          , namedSession "Practice"   "Practice 1"        "Azerbaijan Grand Prix"
          ]
        `shouldBe` [ "Azerbaijan Grand Prix · Sprint"
                   , "Azerbaijan Grand Prix · Sprint Qualifying"
                   , "Azerbaijan Grand Prix · Practice 1"
                   ]

    it "sin gran premio no queda un separador suelto" $
      -- OpenF1 sirve la sesión con el gran premio en blanco cuando no lo sabe
      -- (`openf1Session`), y entonces el título es el nombre a secas.
      sessionTitle (namedSession "Race" "Race" "") `shouldBe` "Race"

    it "el circuito va entre el gran premio y el nombre" $
      sessionTitle raceSessionFixture `shouldBe` "Spanish Grand Prix · Madring · Race"

    it "sin gran premio el circuito abre el título, sin separador suelto" $
      sessionTitle raceSessionFixture {siMeeting = ""} `shouldBe` "Madring · Race"

    it "un circuito vacío se salta igual que uno ausente" $
      -- El microservicio no emite la clave vacía, pero OpenF1 podría mandar la
      -- cadena: los dos casos tienen que dar el mismo título.
      map sessionTitle
          [ raceSessionFixture {siCircuit = Just ""}
          , raceSessionFixture {siCircuit = Nothing}
          ]
        `shouldBe` ["Spanish Grand Prix · Race", "Spanish Grand Prix · Race"]

    it "la parte de una clasificación va al final, con SQ en la clasificación Sprint" $
      map sessionTitle
          [ (namedSession "Qualifying" "Qualifying"        "Singapore Grand Prix") {siPart = Just 2}
          , (namedSession "Qualifying" "Sprint Qualifying" "Singapore Grand Prix") {siPart = Just 2}
          , (namedSession "Qualifying" "Qualifying"        "Singapore Grand Prix") {siPart = Nothing}
          ]
        `shouldBe` [ "Singapore Grand Prix · Qualifying · Q2"
                   , "Singapore Grand Prix · Sprint Qualifying · SQ2"
                   , "Singapore Grand Prix · Qualifying"
                   ]

  describe "formatCountdown" $ do
    it "da las tres unidades mayores y no la cuarta" $
      -- A seis días los segundos son ruido; a cuatro minutos ya no hay días y los
      -- segundos entran solos.
      map formatCountdown
          [ 6 * 86400 + 19 * 3600 + 25 * 60 + 10
          , 2 * 3600 + 30 * 60 + 15
          , 4 * 60 + 50
          , 50
          ]
        `shouldBe` ["6 d 19 h 25 min", "2 h 30 min 15 s", "4 min 50 s", "50 s"]

    it "se salta las magnitudes en cero y las tres siguen siendo tres" $
      -- Los dos casos del 2026-09-17: un cero en medio gasta sitio
      -- y una de las tres posiciones para decir que no hay nada que decir.
      map formatCountdown
          [ 3 * 86400 + 50 * 60 + 36
          , 12 * 86400 + 30 * 60
          ]
        `shouldBe` ["3 d 50 min 36 s", "12 d 30 min"]

    it "las tres pueden no ser contiguas, y se acepta a sabiendas" $
      -- El precio de la regla de arriba. Sale de saltarse dos magnitudes seguidas.
      formatCountdown (86400 + 1) `shouldBe` "1 d 1 s"

    it "recorta también las de cola que valen cero" $
      formatCountdown (6 * 86400) `shouldBe` "6 d"

    it "el cero se dice, no se calla" $
      -- En blanco se leería como que la cuenta atrás se rompió.
      formatCountdown 0 `shouldBe` "0 s"

    it "lo negativo es cero" $
      -- Mismo criterio que `formatClock`: no hay forma de decir «falta menos que
      -- nada», y el productor de hoy ya no baja de cero, pero eso es invariante suyo.
      formatCountdown (negate 500) `shouldBe` "0 s"

    it "cruza el día sin envolverse a 24 h" $
      -- 48 h son dos días, no cero. Es el equivalente de lo que `formatClock`
      -- promete al no envolver sus horas.
      formatCountdown (2 * 86400) `shouldBe` "2 d"

  describe "upNextLabel y tickDown" $ do
    it "la que rueda calla, y la que no se sabe lo dice" $
      -- Los dos silencios son distintos: uno es a propósito y el otro es el arranque
      -- del proceso. En blanco los dos, no se distinguirían.
      map (upNextLabel 0) [NextSilent, NextUnknown] `shouldBe` ["", "Próxima: …"]

    it "la que aún no empieza no se nombra: ya está escrita al lado" $
      upNextLabel 0 (NextStartsIn (12 * 60)) `shouldBe` "empieza en 12 min"

    it "y la siguiente sí, con su etiqueta delante" $
      upNextLabel 0 (NextAfter "Azerbaijan Grand Prix" (6 * 86400 + 19 * 3600))
        `shouldBe` "Azerbaijan Grand Prix · en 6 d 19 h"

    it "el tic descuenta un segundo de las dos que cuentan" $
      map tickDown [NextStartsIn 100, NextAfter "Baku" 100]
        `shouldBe` [NextStartsIn 99, NextAfter "Baku" 99]

    it "y no toca a las dos que no cuentan" $
      map tickDown [NextSilent, NextUnknown] `shouldBe` [NextSilent, NextUnknown]

    it "no baja de cero por mucho que se tique" $
      -- La respuesta siguiente dice qué hay después de que la cuenta se agote; esta
      -- función no lo inventa.
      iterate tickDown (NextStartsIn 2) !! 5 `shouldBe` NextStartsIn 0

    it "lo que llegó hace k segundos se pone a la hora del calendario" $
      map (catchUp 41) [NextStartsIn 100, NextAfter "Baku" 100]
        `shouldBe` [NextStartsIn 59, NextAfter "Baku" 59]

    it "ponerse al día no toca a las que no cuentan, no sube con k negativo ni baja de cero" $ do
      map (catchUp 41) [NextSilent, NextUnknown] `shouldBe` [NextSilent, NextUnknown]
      catchUp (-5) (NextStartsIn 10) `shouldBe` NextStartsIn 10
      catchUp 41 (NextAfter "Baku" 30) `shouldBe` NextAfter "Baku" 0

    prop "ponerse al día en dos saltos es ponerse al día en uno" $
      \(NonNegative a) (NonNegative b) (NonNegative n) ->
        catchUp a (catchUp b (NextStartsIn n)) === catchUp (a + b) (NextStartsIn n)

  describe "shownNext" $ do
    it "sin tabla todavía no se sabe, que es con lo que arranca la cuenta" $
      shownNext Nothing `shouldBe` NextUnknown

    it "la primera tabla que pide callar es un cambio y no se pierde" $
      -- Abrir con la sesión rodando: si antes de la primera respuesta ya valiera
      -- callar, la cuenta no vería el cambio y se quedaría en «Próxima: …».
      shownNext (Just liveTableFixture {liveNext = NextSilent}) `shouldBe` NextSilent

  describe "sessionStateWord y bandMark" $ do
    it "da la palabra de los tres estados publicados" $
      map sessionStateWord [SessionInactive, SessionStarted, SessionFinalised]
        `shouldBe` ["Por empezar", "En marcha", "Finalizada"]

    it "lo que no se reconoce sale crudo, con el texto que la fuente mandó" $
      -- Es para lo que `SessionUnknown` guarda el texto: traducirlo sería inventar
      -- una palabra para algo que aún no sabemos qué es. Y el texto NO se
      -- normaliza, así que llega con las mayúsculas que trajo.
      map sessionStateWord [SessionUnknown "Aborted", SessionUnknown ""]
        `shouldBe` ["Aborted", ""]

    it "no repite palabra entre estados distintos" $
      -- Mismo criterio que `statusLabel`: dos estados con la misma palabra serían
      -- indistinguibles en la banda.
      let words' = map sessionStateWord
                     [ SessionInactive, SessionStarted, SessionChequered
                     , SessionRedFlag, SessionFinalised ]
       in length (nub words') `shouldBe` length words'

    it "el asterisco sale solo en lo deducido" $
      map (bandMark False . Just)
          [ StateReading SessionFinalised Heard
          , StateReading SessionFinalised Derived
          ]
        `shouldBe` ["", "*"]

    it "lo desconocido no lleva marca: llegó de la fuente, así que es oído" $
      -- El cuarto caso del estado y la marca de procedencia son preguntas
      -- distintas. Un valor raro sigue siendo lo que el feed dijo.
      bandMark False (Just (StateReading (SessionUnknown "Aborted") Heard))
        `shouldBe` ""

    it "los dos asteriscos de lo conservado mandan sobre el uno de lo deducido" $
      -- No se suman: tres asteriscos no significan nada, y de las dos cosas la que
      -- decide si el dato es de ahora es que sea conservado.
      map (`bandMark` Just (StateReading SessionFinalised Derived))
          [False, True]
        `shouldBe` ["*", "**"]

    it "una sesión conservada sin estado deja los dos asteriscos solos" $
      -- Es lo que le da ancla al aviso: sin ellos, el caso que esto arregla sería
      -- el único que no se avisa.
      (bandPieces Nothing Nothing Nothing, bandMark True Nothing) `shouldBe` ([], "**")

    it "sin estado y sin conservar no hay nada que leer" $
      (bandPieces Nothing Nothing Nothing, bandMark False Nothing) `shouldBe` ([], "")

  -- Lo que tiene símbolo va dibujado y lo demás, con palabra (decidido el
  -- 2026-10-05).
  describe "bandPieces" $ do
    it "la bandera a cuadros y la roja se dibujan; los demás estados se nombran" $
      map (\s -> bandPieces (Just s) Nothing Nothing)
          [SessionChequered, SessionRedFlag, SessionStarted, SessionFinalised]
        `shouldBe`
          [ [PieceFlag ChequeredFlag], [PieceFlag RedFlag]
          , [PieceWord "En marcha"], [PieceWord "Finalizada"] ]

    it "la pista va detrás del estado, dibujada o nombrada" $
      map (\t -> bandPieces (Just SessionStarted) (Just t) Nothing)
          [TrackYellow, TrackRed, TrackSafetyCar, TrackVsc, TrackVscEnding]
        `shouldBe`
          [ [PieceWord "En marcha", PieceFlag YellowFlag]
          , [PieceWord "En marcha", PieceFlag RedFlag]
          , [PieceWord "En marcha", PieceWord "Safety Car"]
          , [PieceWord "En marcha", PieceWord "VSC"]
          , [PieceWord "En marcha", PieceWord "VSC termina"]
          ]

    it "con la sesión por empezar también: la roja de la salida suspendida de Malasia" $
      bandPieces (Just SessionInactive) (Just TrackRed) Nothing
        `shouldBe` [PieceWord "Por empezar", PieceFlag RedFlag]

    it "con la bandera, la roja o la sesión acabada, la pista no se enseña" $
      -- La amarilla de la sesión anterior viaja en la foto hasta el anuncio de la
      -- siguiente; y con la roja de control de carrera la pista también dice roja.
      map (\s -> bandPieces (Just s) (Just TrackYellow) Nothing)
          [SessionChequered, SessionRedFlag, SessionFinalised]
        `shouldBe`
          [[PieceFlag ChequeredFlag], [PieceFlag RedFlag], [PieceWord "Finalizada"]]

    it "los huecos: la palabra o la bandera de cada pieza, y el separador solo entre dos" $ do
      let two = bandPieces (Just SessionStarted) (Just TrackYellow) Nothing
      (pieceWord (listToMaybe two), pieceFlag (listToMaybe (drop 1 two)), pieceSeparator two)
        `shouldBe` ("En marcha", Just YellowFlag, " · ")
      pieceSeparator (bandPieces (Just SessionStarted) Nothing Nothing) `shouldBe` ""
      (pieceWord Nothing, pieceFlag Nothing) `shouldBe` ("", Nothing)

    it "cada bandera se nombra al pasar el ratón" $
      map flagName [YellowFlag, RedFlag, ChequeredFlag]
        `shouldBe` ["Bandera amarilla", "Bandera roja", "Bandera a cuadros"]

    it "la marca es lo ÚNICO que distingue un estado oído de uno deducido" $
      -- El control negativo de la afirmación de arriba: sin `srBasis` los dos
      -- valores serían iguales, y es justo la propiedad que se perdería en
      -- silencio al repetir sesiones pasadas.
      StateReading SessionFinalised Heard
        `shouldNotBe` StateReading SessionFinalised Derived

  -- Lo que las marcas no caben en decir. Con dos asteriscos el de lo deducido deja
  -- de verse, así que este texto es el único sitio donde esa segunda mitad puede
  -- decirse, y de ahí que se componga en vez de elegir.
  describe "bandNote" $ do
    it "sin nada que aclarar es la cadena vacía, que es lo que deja el botón inerte" $
      bandNote Nothing False `shouldBe` ""

    it "de lo conservado dice de cuándo es, y nada más" $
      bandNote (Just 12) False `shouldBe` "Sesión de hace 12 s"

    it "de lo deducido dice de dónde salió el estado" $
      bandNote Nothing True `shouldBe` "Estado previsto por el calendario"

    it "cuando concurren, las dos frases y en ese orden" $
      -- La edad va delante porque es la que cambia: leerla al final obligaría a
      -- recorrer una frase fija cada segundo para ver el número.
      bandNote (Just 12) True
        `shouldBe` "Sesión de hace 12 s. Estado previsto por el calendario"

    it "un corte largo se lee en minutos, sin decidirlo aquí" $
      -- Sale de `formatCountdown`, el mismo que la cuenta atrás: un segundo formato
      -- para el mismo hecho divergiría del otro.
      bandNote (Just 95) False `shouldBe` "Sesión de hace 1 min 35 s"

    it "el cero se dice y no se calla" $
      -- Callar se leería como que el aviso se rompió, que es el mismo criterio con
      -- el que `formatCountdown` decide no devolver blanco.
      bandNote (Just 0) False `shouldBe` "Sesión de hace 0 s"

  -- La coherencia entre los dos respaldos de FastF1. No es cosmética: los dos
  -- widgets se miran a la vez, así que un coche que el de comparación pinta y el
  -- selector no lista sería una contradicción visible con el servicio apagado.
  describe "los dummies de Drivers y Comparison" $ do
    it "la parrilla de respaldo contiene los coches que la comparación de respaldo pinta" $ do
      let numbers = map deNumber Drivers.dummy
      map ceCar (lcEntries Comparison.dummy) `shouldSatisfy` all (`elem` numbers)

    it "y les da el mismo acrónimo que la parrilla, no uno distinto para el mismo coche" $ do
      -- La mitad que faltaba, y la que se había desincronizado: el dummy de
      -- comparación decía que el coche 1 era VER desde la Fase 1, y la primera
      -- parrilla real (2026-08-06) mostró que es NOR. Contener el número no basta
      -- si las dos áreas lo nombran distinto.
      [codeOfCar (ceCar e) | e <- lcEntries Comparison.dummy]
        `shouldBe` [Just (ceDriver e) | e <- lcEntries Comparison.dummy]

    it "los coches de la comparación de respaldo son los del defecto, en su orden" $
      T.intercalate "," (map ceCar (lcEntries Comparison.dummy)) `shouldBe` Comparison.defaultDrivers

    it "los sectores de la comparación de respaldo suman sus tiempos de vuelta" $
      -- Lo que el dummy anterior incumplía: NOR más rápido en la cabecera y «por
      -- detrás» en la curva. Con la Δ calculada desde los sectores, la cabecera y la
      -- curva solo cuadran si los sectores suman la vuelta.
      let near a b = abs (a - b) < 1e-9
       in [fmap (\(a, b, c) -> a + b + c) (ceSectors e) | e <- lcEntries Comparison.dummy]
            `shouldSatisfy` and . zipWith near [89.512, 89.345] . map (fromMaybe 0)

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
      fmap (\d -> comparisonPathFor Nothing (Just d) 0) (driversParam "44" "63")
        `shouldBe` Just "/api/comparison?drivers=44,63"

    it "las muestras van en el query solo si son positivas" $ do
      comparisonPathFor Nothing (Just "16,1") 100 `shouldBe` "/api/comparison?drivers=16,1&samples=100"
      comparisonPathFor Nothing Nothing 0 `shouldBe` "/api/comparison"
      comparisonPathFor (Just "2026-13-Q") Nothing (-5) `shouldBe` "/api/comparison?session=2026-13-Q"

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

    it "la serie del dummy ocupa el ancho útil de extremo a extremo" $
      -- Se casa la lista entera en vez de pedirle el primero y el último: cuatro
      -- entradas dan cuatro puntos, y así la aridad queda afirmada junto a los
      -- extremos en lugar de darse por supuesta.
      case map fst (deltaPoints [0.0, -0.048, 0.081, 0.167]) of
        [x0, _, _, x3] -> (x0, x3) `shouldBe` (chartPad, chartWidth - chartPad)
        other          -> expectationFailure ("se esperaban cuatro puntos: " <> show other)

    it "emite `points` con coordenadas enteras, sin notación científica" $
      deltaPolyline [0, 0, 0] `shouldBe` "10,100 300,100 590,100"

    prop "ninguna coordenada se sale del viewBox" (staysInsideViewBox deltaPoints)

  -- La fila de debajo del gráfico de Lap Comparison: nombre y valor de cada frontera,
  -- con los números tal como llegan del microservicio.
  describe "frontierCells" $ do
    let series = [0, -0.13400000000000034, 0.19299999999999784, 0.6170000000000044]
    it "cuatro fronteras: su nombre y su valor con signo y unidad" $
      map (\(_, name, value) -> (name, value)) (frontierCells series)
        `shouldBe`
          [ ("Inicio", "0.000 s")
          , ("S1", "\x2212\&0.134 s")
          , ("S2", "+0.193 s")
          , ("S3", "+0.617 s")
          ]

    it "cada valor va en la X de su punto" $
      map (\(x, _, _) -> x) (frontierCells series)
        `shouldBe` map ((\x -> x / chartWidth * 100) . fst) (deltaPoints series)

    it "con otro número de valores no se nombra nada" $ do
      frontierCells [] `shouldBe` []
      frontierCells [0, 0.1, 0.2] `shouldBe` []

  -- El eje de Lap Comparison: múltiplos de un paso redondo, hasta siete, con cada
  -- extremo alargado al múltiplo más lejano del cero cuando le queda igual o más cerca.
  describe "axisTicks" $ do
    let series = [0, -0.13400000000000034, 0.19299999999999784, 0.6170000000000044]
        labels = map (\(_, _, label) -> label) . axisTicks
    it "NOR contra LEC: paso de 0.2, y el −0.134 alarga el eje hasta −0.200" $
      labels series
        `shouldBe` ["+0.600 s", "+0.400 s", "+0.200 s", "0.000 s", "\x2212\&0.200 s"]

    it "de 0 a 1, seis marcas de 0.2" $
      labels [0, 0.3, 0.6, 1.0]
        `shouldBe` ["+1.000 s", "+0.800 s", "+0.600 s", "+0.400 s", "+0.200 s", "0.000 s"]

    it "a medio paso exacto, el extremo también alarga" $
      labels [0, -0.1, 0.6, 1.0]
        `shouldBe` [ "+1.000 s", "+0.800 s", "+0.600 s", "+0.400 s", "+0.200 s"
                   , "0.000 s", "\x2212\&0.200 s" ]

    it "el alargamiento puede dejar ocho marcas" $ do
      labels [0, 0.3, 0.5, 0.68]
        `shouldBe` [ "+0.700 s", "+0.600 s", "+0.500 s", "+0.400 s", "+0.300 s"
                   , "+0.200 s", "+0.100 s", "0.000 s" ]
      labels [-0.18, 0.1, 0.3, 0.48]
        `shouldBe` [ "+0.500 s", "+0.400 s", "+0.300 s", "+0.200 s", "+0.100 s"
                   , "0.000 s", "\x2212\&0.100 s", "\x2212\&0.200 s" ]

    it "si dejaría nueve, sube el paso" $
      labels [-0.18, 0.1, 0.3, 0.58]
        `shouldBe` ["+0.600 s", "+0.400 s", "+0.200 s", "0.000 s", "\x2212\&0.200 s"]

    it "una diferencia de milésimas baja hasta el paso de 0.001, y no más" $ do
      labels [0, 0.001, 0.002, 0.001] `shouldBe` ["+0.002 s", "+0.001 s", "0.000 s"]
      labels [0, 0.0001, 0.0002, 0.0001] `shouldBe` ["0.000 s"]

    it "toda en cero, solo el cero; vacía, nada" $ do
      labels [0, 0, 0, 0] `shouldBe` ["0.000 s"]
      axisTicks [] `shouldBe` []

    it "el rango del eje alarga solo el extremo que lo pide" $
      axisRange series `shouldBe` (-0.2, snd (deltaRange series))

    it "sin nada que alargar, la marca del cero va en la línea del cero" $ do
      let flat = [0, 0.3, 0.6, 1.0]
      axisRange flat `shouldBe` deltaRange flat
      [y | (v, y, _) <- axisTicks flat, v == 0] `shouldBe` [zeroLineY flat]

    it "la curva del eje pone su cero en la marca del cero" $
      [y | (v, y, _) <- axisTicks series, v == 0] `shouldBe` [axisZeroY series]

    it "con el eje, el −0.134 de NOR contra LEC queda por encima del −0.200 del fondo" $
      map snd (axisPoints series) `shouldSatisfy` all (< chartHeight - chartPad)

    it "sin nada que alargar, la curva del eje es la de siempre; vacía, sin puntos" $ do
      let flat = [0, 0.3, 0.6, 1.0]
      axisPolyline flat `shouldBe` deltaPolyline flat
      axisPolyline [] `shouldBe` ""

    prop "como mucho ocho marcas, y el cero entre ellas" fewTicksWithZero
    prop "de arriba abajo, dentro del lienzo y sin dos etiquetas iguales" ticksReadable
    prop "el rango del eje contiene al de la curva" axisRangeContainsDelta
    prop "la curva del eje no se sale del viewBox" (staysInsideViewBox axisPoints)

  -- Los sectores son los de la clasificación de Bakú 2026 (FastF1 3.8.3), con LEC de
  -- referencia; los valores esperados salen de GHC.
  describe "Common.Comparison" $ do
    let near a b = abs (a - b) < 1e-9
        nearRows xs ys =
          length xs == length ys && and (zipWith (\x y -> length x == length y && and (zipWith near x y)) xs ys)
        lec = (36.079, 42.073, 25.211)
        nor = (36.279, 41.840, 25.553)
        rus = (36.009, 41.659, 24.858)
    it "contra la referencia: comparado − referencia en Inicio, S1, S2 y S3" $
      deltasAgainst AgainstReference [Just lec, Just nor, Just rus]
        `shouldSatisfy` nearRows [[0, 0, 0, 0], [0, 0.2, -0.033, 0.309], [0, -0.07, -0.484, -0.837]]

    it "contra el más rápido: la base es RUS, aunque no sea la referencia" $
      deltasAgainst AgainstFastest [Just lec, Just nor, Just rus]
        `shouldSatisfy` nearRows [[0, 0.07, 0.484, 0.837], [0, 0.27, 0.451, 1.146], [0, 0, 0, 0]]

    it "sin sus tres sectores no hay Δ: el piloto da [], y sin base, todos" $ do
      deltasAgainst AgainstReference [Just lec, Nothing, Just rus]
        `shouldSatisfy` nearRows [[0, 0, 0, 0], [], [0, -0.07, -0.484, -0.837]]
      deltasAgainst AgainstReference [Nothing, Just nor] `shouldBe` [[], []]
      deltasAgainst AgainstFastest [Nothing, Just nor, Nothing] `shouldBe` [[], [0, 0, 0, 0], []]
      deltasAgainst AgainstFastest [] `shouldBe` []

    it "un empate en el más rápido se lo queda el primero" $
      deltasAgainst AgainstFastest [Just (30, 40, 30), Just (35, 35, 30)]
        `shouldBe` [[0, 0, 0, 0], [0, 5, 0, 0]]

    prop "la última Δ es la diferencia de vueltas, y la de la base es cero" lastDeltaIsLapDiff
    prop "contra el más rápido nadie acaba por debajo del cero" noneEndsBelowFastest

    it "Sectores: las fronteras del coche caen en las de la referencia; 0 y 1 no se mueven" $
      map (anchored (0.3, 0.7) (0.25, 0.6)) [0, 0.3, 0.5, 0.7, 1]
        `shouldSatisfy` (and . zipWith near [0, 0.25, 0.425, 0.6, 1])

    it "Sectores: con las fronteras de la referencia no cambia, ni con unas imposibles" $ do
      all (\f -> near (anchored (0.3, 0.7) (0.3, 0.7) f) f) [0, 0.01 .. 1] `shouldBe` True
      map (anchored (0, 0.7) (0.25, 0.6)) [0.2, 0.9] `shouldBe` [0.2, 0.9]
      anchored (0.7, 0.3) (0.25, 0.6) 0.2 `shouldBe` 0.2

    it "los ejes, en el orden y con el nombre del desplegable; abre en Tiempo" $ do
      map axisLabel axesInOrder `shouldBe` ["Distancia", "Fracción de vuelta", "Tiempo", "Sectores"]
      defaultAxis `shouldBe` AxisTime
      map axisNotice axesInOrder `shouldSatisfy` all (not . T.null)

    it "cada eje lleva las muestras (segundos, metros) a su X" $ do
      let car = LapGeometry 1000 (300, 700)
          ref = LapGeometry 2000 (500, 1200)
          pts = [(0, 0), (10, 300), (20, 500), (30, 700), (40, 1000)]
      axisXs AxisTime car ref pts `shouldBe` [0, 10, 20, 30, 40]
      axisXs AxisDistance car ref pts `shouldBe` [0, 300, 500, 700, 1000]
      axisXs AxisFraction car ref pts `shouldSatisfy` (and . zipWith near [0, 0.3, 0.5, 0.7, 1])
      axisXs AxisSectors car ref pts `shouldSatisfy` (and . zipWith near [0, 0.25, 0.425, 0.6, 1])

    it "Sectores contra sí mismo es la fracción, y sin distancia todo cae a 0" $ do
      let car = LapGeometry 1000 (300, 700)
          pts = [(0, 0), (10, 300), (20, 500), (30, 700), (40, 1000)]
      and (zipWith near (axisXs AxisSectors car car pts) (axisXs AxisFraction car car pts)) `shouldBe` True
      axisXs AxisSectors (LapGeometry 0 (0, 0)) car pts `shouldBe` [0, 0, 0, 0, 0]

    it "Sectores: no desordena la vuelta" $
      and [ anchored (0.3, 0.7) (0.25, 0.6) f <= anchored (0.3, 0.7) (0.25, 0.6) g
          | f <- [0, 0.01 .. 1], g <- [0, 0.01 .. 1], f <= g ]
        `shouldBe` True

  -- El par que pinta hoy la tarjeta, sobre el dummy (LEC referencia, 1:29.512; NOR
  -- comparado y más rápido, 1:29.345) y sus variantes sin vuelta (Monza: el 16 no
  -- tiene vuelta). Los valores, de GHC.
  describe "Common.Comparison: el par" $ do
    let near a b = abs (a - b) < 1e-9
        nearAll xs ys = length xs == length ys && and (zipWith near xs ys)
        (lec, nor) = case lcEntries Comparison.dummy of
          [a, b] -> (a, b)
          _      -> error "el dummy de la comparación ya no son dos coches"
        pair es = Comparison.dummy { lcEntries = es }
        noLap e = e { ceLap = "", ceSectors = Nothing }
        roles b c = fmap (\p -> (ceDriver (pairBase p), ceDriver (pairOther p))) (pairWith b c)
        delta b c = maybe [] pairDelta (pairWith b c)
    it "contra la referencia: la base es la referencia y la Δ, la del otro" $ do
      roles AgainstReference Comparison.dummy `shouldBe` Just ("LEC", "NOR")
      delta AgainstReference Comparison.dummy `shouldSatisfy` nearAll [0.0, 0.048, -0.081, -0.167]

    it "contra el más rápido: si es el otro, pasa a ser la base y se pinta la referencia" $ do
      roles AgainstFastest Comparison.dummy `shouldBe` Just ("NOR", "LEC")
      delta AgainstFastest Comparison.dummy `shouldSatisfy` nearAll [0.0, -0.048, 0.081, 0.167]

    it "contra el más rápido, si lo es la referencia, igual que contra la referencia" $
      map (\b -> roles b (pair [nor, lec])) baselinesInOrder `shouldBe` replicate 2 (Just ("NOR", "LEC"))

    it "sin vuelta: no hay Δ, y la base es la que la tiene si va contra el más rápido" $ do
      roles AgainstReference (pair [noLap lec, nor]) `shouldBe` Just ("LEC", "NOR")
      delta AgainstReference (pair [noLap lec, nor]) `shouldBe` []
      roles AgainstFastest (pair [noLap lec, nor]) `shouldBe` Just ("NOR", "LEC")
      delta AgainstFastest (pair [noLap lec, nor]) `shouldBe` []
      map (\b -> roles b (pair [lec, noLap nor])) baselinesInOrder `shouldBe` replicate 2 (Just ("LEC", "NOR"))
      map (\b -> delta b (pair [lec, noLap nor])) baselinesInOrder `shouldBe` [[], []]

    it "sin dos coches no hay par" $
      pairWith AgainstReference (pair [lec]) `shouldBe` Nothing

    it "el tiempo, o «sin vuelta» si le faltan los sectores aunque traiga texto" $ do
      map lapShown [lec, nor] `shouldBe` ["1:29.512", "1:29.345"]
      lapShown (lec { ceSectors = Nothing }) `shouldBe` "sin vuelta"

    it "el aviso solo contra la referencia y cuando la que no tiene vuelta es ella" $ do
      missingReference AgainstReference (pair [noLap lec, nor])
        `shouldBe` Just "LEC no tiene vuelta en esta sesión: elige otra referencia."
      missingReference AgainstFastest (pair [noLap lec, nor]) `shouldBe` Nothing
      missingReference AgainstReference (pair [lec, noLap nor]) `shouldBe` Nothing
      missingReference AgainstReference Comparison.dummy `shouldBe` Nothing
      missingReference AgainstReference (pair []) `shouldBe` Nothing

    it "el aviso de un coche por su número, solo si aparece sin vuelta" $ do
      noLapFor "1" (pair [lec, noLap nor]) `shouldBe` Just "NOR no tiene vuelta en esta sesión"
      noLapFor "16" (pair [noLap lec, nor]) `shouldBe` Just "LEC no tiene vuelta en esta sesión"
      noLapFor "1" Comparison.dummy `shouldBe` Nothing
      noLapFor "44" (pair [lec, noLap nor]) `shouldBe` Nothing

    it "el desplegable «Δ contra»: sus dos bases, en orden, y sus claves de ida y vuelta" $ do
      map baselineLabel baselinesInOrder `shouldBe` ["Referencia", "Más rápido"]
      map baselineRole baselinesInOrder `shouldBe` ["referencia", "más rápido"]
      map (baselineFromKey . baselineKey) baselinesInOrder `shouldBe` map Just baselinesInOrder
      baselineFromKey "otra" `shouldBe` Nothing

    it "el desplegable de tipos: los cuatro, en orden; abre en el de hoy y se eligen el 1, el 2 y el 3" $ do
      map chartTypeLabel chartTypesInOrder
        `shouldBe` ["Delta por sectores", "Lap Speed Trace", "Telemetría comparativa", "Lap Delta"]
      defaultChartType `shouldBe` SectorDelta
      filter chartTypeReady chartTypesInOrder `shouldBe` [SectorDelta, LapSpeedTrace, TelemetryTraces]
      map (chartTypeFromKey . chartTypeKey) chartTypesInOrder `shouldBe` map Just chartTypesInOrder
      chartTypeFromKey "otro" `shouldBe` Nothing
      filter chartTypeTraces chartTypesInOrder `shouldBe` [LapSpeedTrace, TelemetryTraces, LapDeltaBars]

    it "el desplegable del eje: sus claves de ida y vuelta" $ do
      map (axisFromKey . axisKey) axesInOrder `shouldBe` map Just axesInOrder
      axisFromKey "otro" `shouldBe` Nothing

    it "qué resta la Δ: el otro menos la base, según la base elegida" $ do
      fmap deltaFormula (pairWith AgainstReference Comparison.dummy) `shouldBe` Just "NOR − LEC"
      fmap deltaFormula (pairWith AgainstFastest Comparison.dummy) `shouldBe` Just "LEC − NOR"

    it "la base por posición: el más rápido de los que tienen vuelta" $ do
      baseIndex AgainstFastest [Nothing, ceSectors nor, ceSectors lec] `shouldBe` Just 1
      baseIndex AgainstReference [Nothing, ceSectors nor] `shouldBe` Nothing
      baseIndex AgainstFastest [Nothing, Nothing] `shouldBe` Nothing

  -- Las trazas del tipo 3 sobre dos vueltas de juguete: la referencia, 100 s y 4000 m
  -- con S1 y S2 a los 1200 y 2800 m; el otro, 110 s y 4200 m, a los 1300 y 2900 m.
  -- Los valores, de GHC.
  -- La columna Best Lap: qué se marca en negrita (la más rápida de la sesión) y en
  -- morado (la más rápida de la parte en curso, o de la sesión si no hay partes).
  describe "las marcas de Best Lap" $ do
    let row best part = LiveTimingRow 1 "X" "" "" "" "" Running best part [] False False
    it "lee los tiempos de vuelta, y no lo que no lo es" $ do
      map lapSeconds ["1:23.456", "59.876", " 1:00.000 "] `shouldBe` [Just 83.456, Just 59.876, Just 60]
      map lapSeconds ["-", "", "LAP 3", "1:2:3"] `shouldBe` replicate 4 Nothing

    it "sin partes, las dos marcas van juntas en la más rápida" $
      bestLapMarks [row "1:31.0" "", row "1:30.5" "", row "-" ""]
        `shouldBe` [(False, False), (True, True), (False, False)]

    it "con partes, la negrita es la de la sesión y el morado el de la parte en curso" $
      bestLapMarks [row "1:30.0" "1:31.2", row "1:30.4" "1:30.9", row "1:31.0" "-"]
        `shouldBe` [(True, False), (False, True), (False, False)]

    it "si la de la parte es también la de la sesión, las dos en la misma fila; un empate marca a los dos" $ do
      bestLapMarks [row "1:30.0" "1:30.0", row "1:30.4" "1:30.9"] `shouldBe` [(True, True), (False, False)]
      bestLapMarks [row "1:30.0" "", row "1:30.0" ""] `shouldBe` [(True, True), (True, True)]

    it "sin ningún tiempo no se marca nada" $
      bestLapMarks [row "-" "", row "" ""] `shouldBe` [(False, False), (False, False)]

  -- Las rayas de la tabla de una clasificación, con la forma de la Q de Malasia: 22
  -- coches, [22, 16, 10] por parte, y los eliminados abajo cuando el feed los marca.
  -- El 107 % de la Q1, con la Q de Bakú a las 12:10:30 UTC: corte 1:53.171, BOT con
  -- 1:48.290 todavía marcado por el feed como fuera, HAM con 1:57.767 y PER sin vuelta.
  describe "cutOffLabel y overCutOff" $ do
    let q1 state cut = raceSessionFixture
          { siType = "Qualifying", siName = "Qualifying", siPart = Just 1
          , siState = Just (StateReading state Heard), siCutOffTime = cut }
        qrow n d best = LiveTimingRow n d "" "" "" "" Running best "" [best, "-", "-"] False True
        baku = [qrow 9 "BOT" "1:48.290", qrow 18 "HAM" "1:57.767", qrow 22 "PER" "-"]
    it "junto al título, el corte solo en la Q1" $ do
      cutOffLabel (q1 SessionStarted (Just "1:45.800")) `shouldBe` Just "107 %: 1:45.800"
      cutOffLabel (q1 SessionStarted (Just "1:43.230")) {siPart = Just 2} `shouldBe` Nothing
      cutOffLabel (q1 SessionStarted Nothing) `shouldBe` Nothing

    it "mientras la Q1 rueda, solo quien tiene vuelta más lenta que el corte, aunque el feed marque a más" $
      overCutOff (Just (q1 SessionStarted (Just "1:53.171"))) baku `shouldBe` [False, True, False]

    it "desde la bandera de la Q1, también quien no tiene vuelta" $
      overCutOff (Just (q1 SessionChequered (Just "1:53.171"))) baku `shouldBe` [False, True, True]

    it "si el feed no lo marca, tampoco: ni con vuelta lenta ni tras la bandera" $
      -- Los tiempos son los de Bakú; la marca apagada es el caso contrario al de BOT,
      -- que no se vio en la grabación (el feed nunca marcó tarde).
      overCutOff (Just (q1 SessionChequered (Just "1:53.171"))) (map (\r -> r {ltCutoff = False}) baku)
        `shouldBe` [False, False, False]

    it "fuera de la Q1, nadie" $ do
      overCutOff (Just (q1 SessionStarted (Just "1:53.171")) {siPart = Just 2}) baku
        `shouldBe` [False, False, False]
      overCutOff Nothing baku `shouldBe` [False, False, False]

  describe "rowBreaks" $ do
    let quali name part = Just raceSessionFixture
          {siType = "Qualifying", siName = name, siPart = Just part, siEntries = [22, 16, 10]}
        grid knocked = [ LiveTimingRow n "X" "" "" "" "" Running "-" "" [] (n > knocked) False
                       | n <- [1 .. 22] ]
        breaks s rows = [ (ltPosition r, b) | (r, Just b) <- zip rows (rowBreaks s rows) ]
    it "en la Q1, y tras su bandera hasta que el feed marca, la raya roja encima del 17" $
      -- El orden cambia durante ~1:40 tras la bandera; el feed marca a los seis unos
      -- seis minutos después, a la vez que la parte pasa a la Q2.
      breaks (quali "Qualifying" 1) (grid 22) `shouldBe` [(17, BreakCut)]

    it "en la Q2, los de la Q1 bajo su raya y la roja encima del 11" $
      breaks (quali "Qualifying" 2) (grid 16)
        `shouldBe` [(11, BreakCut), (17, BreakKnockedOut "fuera en Q1")]

    it "en la Q3, una raya por parte y ninguna roja" $
      breaks (quali "Qualifying" 3) (grid 10)
        `shouldBe` [(11, BreakKnockedOut "fuera en Q2"), (17, BreakKnockedOut "fuera en Q1")]

    it "en la Sprint, la parte con su nombre" $
      breaks (quali "Sprint Qualifying" 2) (grid 16)
        `shouldBe` [(11, BreakCut), (17, BreakKnockedOut "fuera en SQ1")]

    it "fuera de clasificación, sin parte o sin sesión, ninguna raya" $ do
      breaks (Just raceSessionFixture) (grid 22) `shouldBe` []
      breaks Nothing (grid 16) `shouldBe` []

  -- «Columnas ▾» de Live Timing: Pos y Driver no se cierran, y de Gap, Interval, Last
  -- Lap, Best Lap y Estado siempre queda una; Team, libre.
  describe "Common.Columns" $ do
    let countsForOne = [ColGap, ColInterval, ColLastLap, ColBestLap, ColState]
    it "las ocho columnas en orden, y en el menú todas menos Pos y Driver" $ do
      map liveColumnLabel liveColumnsInOrder
        `shouldBe` ["Pos", "Driver", "Team", "Gap", "Interval", "Last Lap", "Best Lap", "Estado"]
      menuColumns `shouldBe` [ColTeam, ColGap, ColInterval, ColLastLap, ColBestLap, ColState]
      length (nub (map liveColumnClass liveColumnsInOrder)) `shouldBe` 8

    it "Pos y Driver no se cierran nunca; Team, siempre" $ do
      map (canClose Set.empty) [ColPos, ColDriver, ColTeam] `shouldBe` [False, False, True]
      canClose (Set.fromList (drop 1 countsForOne)) ColTeam `shouldBe` True

    it "la última abierta de las que cuentan no se cierra, y cerrarla no cambia nada" $ do
      let closed = Set.fromList (drop 1 countsForOne)
      canClose closed ColGap `shouldBe` False
      toggleColumn ColGap False closed `shouldBe` closed
      shownColumns closed `shouldBe` [ColPos, ColDriver, ColTeam, ColGap]

    it "abrir una columna la vuelve a pintar en su sitio" $
      shownColumns (toggleColumn ColInterval True (Set.fromList [ColInterval, ColTeam]))
        `shouldBe` [ColPos, ColDriver, ColGap, ColInterval, ColLastLap, ColBestLap, ColState]

    prop "cierre lo que se cierre, en el orden que sea, siempre queda una de las que cuentan" $ \order ->
      let cols = [toEnum (abs n `mod` 8) | n <- order :: [Int]]
          closed = foldl (\h c -> toggleColumn c False h) Set.empty cols
       in any (`Set.notMember` closed) countsForOne
            && Set.notMember ColPos closed && Set.notMember ColDriver closed

  describe "Common.Traces" $ do
    let near a b = abs (a - b) < 1e-9
        close a b = abs (a - b) <= 1e-6 * max 1 (abs b)
        three = TraceRows channelsInOrder
        speed = TraceRows [Speed]
        layoutPieces r = let l = traceLayout r in tlTop l : tlSpan l ++ [tlBottom l]
        grown s ps = let g = sum (map tpGrow ps) in map (\p -> tpBasis p + tpGrow p / g * s) ps
        nearAll xs ys = length xs == length ys && and (zipWith near xs ys)
        tp t d s th b = MkTracePoint t d s th b
        car c sectors frontiers trace = MkComparisonEntry
          { ceCar = c, ceDriver = c, ceLap = "", cePart = Nothing
          , ceSectors = Just sectors, ceFrontiers = Just frontiers, ceTrace = trace }
        ref = car "16" (30, 40, 30) (1200, 2800)
                [tp 0 0 100 1 0, tp 50 2000 300 0.5 1, tp 100 4000 200 0 0]
        other = car "1" (35, 40, 35) (1300, 2900)
                  [tp 0 0 90 1 0, tp 60 2100 280 0.4 1, tp 110 4200 190 0 0]
    it "tres filas de arriba abajo: velocidad 100, acelerador 50 y freno 20, con 19 de rótulo" $ do
      map channelLabel channelsInOrder `shouldBe` ["km/h", "Acelerador %", "Freno"]
      map (channelHeight three) channelsInOrder `shouldBe` [100, 50, 20]
      map (channelTop three) channelsInOrder `shouldBe` [19, 138, 207]
      tracesHeight three `shouldBe` 243
      channelsSpan three `shouldBe` (19, 227)

    it "los canales de cada tipo: el 3 los tres, el 2 la velocidad, el 1 y el 4 ninguno" $ do
      map traceChannels chartTypesInOrder `shouldBe` [[], [Speed], channelsInOrder, []]
      channelTop speed Speed `shouldBe` 19
      tracesHeight speed `shouldBe` 185
      channelsSpan speed `shouldBe` (19, 169)

    it "la velocidad mide 150 si va sola y 100 con otra fila" $ do
      channelHeight speed Speed `shouldBe` 150
      map (\o -> channelHeight (TraceRows [Speed, o]) Speed) [Throttle, Brake] `shouldBe` [100, 100]

    it "los trozos sin crecer suman el alto del lienzo, con las filas en orden entre sus aires" $ do
      map (sum . map tpBasis . layoutPieces) [speed, three] `shouldBe` [tracesHeight speed, tracesHeight three]
      map tpChannel (layoutPieces three)
        `shouldBe` [Nothing, Just Speed, Nothing, Just Throttle, Nothing, Just Brake, Nothing]
      map tpChannel (layoutPieces speed) `shouldBe` [Nothing, Just Speed, Nothing]

    it "los pesos: en el tipo 3 cada fila su alto y cada aire la mitad; en el 2, todo a la velocidad" $ do
      map tpGrow (layoutPieces three) `shouldBe` [9.5, 100, 9.5, 50, 9.5, 20, 8]
      map tpGrow (layoutPieces speed) `shouldBe` [0, 1, 0]
      pieceFlex (TracePiece (Just Throttle) 50 50) `shouldBe` "flex: 50.000 0 50.0px"
      spanPiece (tlSpan (traceLayout three)) `shouldBe` TracePiece Nothing 208 189

    prop "en el tipo 3, al crecer, las filas guardan el 100 : 50 : 20, cada aire crece la mitad que ellas y suman lo crecido" $
      \(NonNegative s) ->
        let hs = grown s (layoutPieces three)
            k = hs !! 1 / 100
            air = (1 + k) / 2
         in close (sum hs) (tracesHeight three + s)
              && close (hs !! 3) (50 * k) && close (hs !! 5) (20 * k)
              && all (\i -> close (hs !! i) (19 * air)) [0, 2, 4]
              && close (hs !! 6) (16 * air)

    prop "en el tipo 2, la velocidad se queda todo lo que crece" $ \(NonNegative s) ->
      grown s (layoutPieces speed) == [19, 150 + s, 16]

    prop "repartir dentro del grupo de las filas da lo mismo que repartir entre todos" $ \(NonNegative s) ->
      all (\r ->
             let l = traceLayout r
                 sp = spanPiece (tlSpan l)
              in case grown s [tlTop l, sp, tlBottom l] of
                   [t, m, b] -> and (zipWith close (t : grown (m - tpBasis sp) (tlSpan l) ++ [b]) (grown s (layoutPieces r)))
                   _         -> False)
          [speed, three]

    it "la velocidad hasta la máxima redondeada a 50; el acelerador y el freno, fijos" $ do
      channelRange Speed [ref, other] `shouldBe` (0, 300)
      channelRange Speed [ref { ceTrace = [tp 0 0 310 1 0] }] `shouldBe` (0, 350)
      channelRange Speed [] `shouldBe` (0, 50)
      map (`channelRange` []) [Throttle, Brake] `shouldBe` [(0, 100), (0, 1)]

    it "la X de cada muestra en los cuatro ejes, y dónde acaba la vuelta" $ do
      traceXs AxisTime ref other `shouldBe` [0, 60, 110]
      traceXs AxisDistance ref other `shouldBe` [0, 2100, 4200]
      traceXs AxisFraction ref other `shouldSatisfy` nearAll [0, 0.5, 1]
      last (traceXs AxisSectors ref other) `shouldSatisfy` near 1
      axisEnd AxisTime ref other `shouldBe` 110
      traceXs AxisTime ref (other { ceTrace = [] }) `shouldBe` []
      traceXs AxisTime (ref { ceTrace = [] }) other `shouldBe` [0, 60, 110]
      traceXs AxisSectors (ref { ceTrace = [] }) other `shouldBe` []

    it "las fronteras de cada coche en el eje; en «Sectores», las de la referencia" $ do
      frontierXs AxisTime ref other `shouldBe` Just (35, 75)
      frontierXs AxisDistance ref other `shouldBe` Just (1300, 2900)
      fmap (\(a, b) -> nearAll [a, b] [0.30952380952380953, 0.6904761904761905])
        (frontierXs AxisFraction ref other) `shouldBe` Just True
      fmap (\(a, b) -> nearAll [a, b] [0.3, 0.7]) (frontierXs AxisSectors ref other) `shouldBe` Just True
      frontierXs AxisDistance ref (other { ceFrontiers = Nothing }) `shouldBe` Nothing

    it "la fila Δ en las fronteras de la referencia, y la X en porcentaje" $ do
      boundaryXs AxisTime ref `shouldBe` Just [0, 30, 70, 100]
      xPercent 200 50 `shouldBe` 25
      xPercent 0 50 `shouldBe` 0

    it "los rótulos: la velocidad con su rango, y el final del eje en su unidad" $ do
      channelCaption Speed (0, 300) `shouldBe` "km/h (0–300)"
      channelCaption Brake (0, 1) `shouldBe` "Freno"
      map (`axisEndLabel` 105.784) [AxisDistance, AxisFraction, AxisTime, AxisSectors]
        `shouldBe` ["106 m", "105.78", "105.8 s", "105.78"]

    it "el deslizable: solo números entre 60 y 250" $ do
      map readSamples ["60", "100", "250"] `shouldBe` [Just 60, Just 100, Just 250]
      map readSamples ["55", "255", "", "abc"] `shouldBe` replicate 4 Nothing
      samplesStart `shouldBe` 100

    it "la fila Δ en X dadas: las cuatro, o ninguna" $ do
      map (\(x, n, _) -> (x, n)) (frontierCellsAt [0, 30, 70, 100] [0, 0.1, 0.2, 0.3])
        `shouldBe` [(0, "Inicio"), (30, "S1"), (70, "S2"), (100, "S3")]
      frontierCellsAt [0, 50] [0, 0.1, 0.2, 0.3] `shouldBe` []
      frontierCells [0, 0.1, 0.2, 0.3] `shouldBe` frontierCellsAt (map (\(x, _, _) -> x) (frontierCells [0, 0.1, 0.2, 0.3])) [0, 0.1, 0.2, 0.3]

    it "la banda: un tramo por sector entre fronteras, con la Δ acumulada y lo que pasó dentro" $ do
      let deltas = [0, -0.014, 0.791, 0.634]
          pieces = sectorSpans (frontierCellsAt [0, 25.32, 58.81, 99.37] deltas) deltas
      map spName pieces `shouldBe` ["S1", "S2", "S3"]
      map spValue pieces `shouldBe` ["\8722\&0.014 s", "+0.791 s", "+0.634 s"]
      map spPace pieces `shouldBe` [SectorFaster, SectorSlower, SectorFaster]
      map spLeft pieces `shouldBe` [0, 25.32, 58.81]
      and (zipWith (\p w -> abs (spWidth p - w) < 1e-9) pieces [25.32, 33.49, 40.56]) `shouldBe` True

    it "la banda: ninguna sin las cuatro fronteras o sin los cuatro valores" $ do
      sectorSpans (frontierCellsAt [0, 30, 70, 100] [0, 0.1, 0.2, 0.3]) [0, 0.1] `shouldBe` []
      sectorSpans [] [0, 0.1, 0.2, 0.3] `shouldBe` []

    it "un sector empata si da 0.000 al milésimo, aunque la resta arrastre decimales" $ do
      map sectorPace [0, 0.0004, -0.0004] `shouldBe` replicate 3 SectorEven
      map sectorPace [0.001, -0.001] `shouldBe` [SectorSlower, SectorFaster]
      map spPace (sectorSpans (frontierCellsAt [0, 30, 70, 100] [0, 0.3, 0.1 + 0.2, 0.4]) [0, 0.3, 0.1 + 0.2, 0.4])
        `shouldBe` [SectorSlower, SectorEven, SectorSlower]

    it "la curva: X hasta la mayor y la Y en la fila del canal; el freno, en escalones" $ do
      tracePoints three Speed (0, 300) 100 [0, 50, 100] (ceTrace ref) `shouldBe` "0.0,85.7 300.0,19.0 600.0,52.3"
      tracePoints three Brake (0, 1) 100 [0, 50, 100] (ceTrace ref)
        `shouldBe` "0.0,227.0 300.0,227.0 300.0,207.0 600.0,207.0 600.0,227.0"
      tracePoints three Speed (0, 300) 100 [0, 50] (ceTrace ref) `shouldBe` ""
      tracePoints speed Speed (0, 300) 100 [0, 50, 100] (ceTrace ref) `shouldBe` "0.0,119.0 300.0,19.0 600.0,69.0"

  describe "Common.ComparisonCard" $ do
    let near a b = abs (a - b) < 1e-9
    it "los modos, en el orden y con el texto del desplegable; abre en Eje y valores" $ do
      map modeLabel modesInOrder `shouldBe` ["Valores", "Solo eje", "Eje y valores"]
      defaultMode `shouldBe` ModeAxisValues

    it "sin sitio para las dos líneas, «Eje y valores» se apaga y se ve como «Solo eje»" $ do
      map (modeEnabled False) modesInOrder `shouldBe` [True, True, False]
      modeOption False ModeAxisValues `shouldBe` "Eje y valores (no cabe)"
      map (shownMode False) modesInOrder `shouldBe` [ModeValues, ModeAxis, ModeAxis]

    it "con sitio, cada modo se ve como se eligió" $ do
      map (modeOption True) modesInOrder `shouldBe` map modeLabel modesInOrder
      map (shownMode True) modesInOrder `shouldBe` modesInOrder

    it "cada modo tiene su valor en el desplegable, y un valor ajeno no es ninguno" $ do
      map (modeFromKey . modeKey) modesInOrder `shouldBe` map Just modesInOrder
      modeFromKey "eje" `shouldBe` Nothing

    it "la fila dice qué hace pulsarla; desde la banda, en «Valores», se vuelve a los valores" $ do
      map (`rowTitle` False) modesInOrder `shouldBe` replicate 3 "Pulsa para ver los sectores como banda"
      map (`rowTitle` True) modesInOrder
        `shouldBe` [ "Pulsa para volver a los valores"
                   , "Pulsa para volver a Inicio · S1 · S2 · S3"
                   , "Pulsa para volver a Inicio · S1 · S2 · S3" ]

    it "Valores pinta los valores; Solo eje, los nombres; Eje y valores, las dos líneas" $ do
      map showsValues modesInOrder `shouldBe` [True, False, True]
      map showsNames modesInOrder `shouldBe` [False, True, True]

    it "la fila mide 33 px con dos líneas y 21 con una" $
      map rowHeight modesInOrder `shouldBe` [21, 21, 33]

    it "en una tarjeta de 326,5 de alto, las dos líneas caben hasta 302,5 de contenido" $ do
      valuesFitMeasured 326.5 302.5 33 `shouldBe` True
      valuesFitMeasured 326.5 291 21 `shouldBe` False

    it "las dos líneas del tipo 2 en Race Overview a 1912 × 914, con las trazas sin crecer" $ do
      -- 50 u: «Eje y valores» cabe con la velocidad en 150
      valuesFitMeasured 338 291 33 `shouldBe` True
      -- con el lienzo crecido 23 px, se descuenta y sigue cabiendo
      valuesFitMeasured 338 314 (33 + 23) `shouldBe` True
      -- 46 u: con la velocidad en 150 no cabe
      valuesFitMeasured 310 291 33 `shouldBe` False

    prop "da lo mismo medir con una línea, con dos o sin fila" measuredFitAgrees

    it "las dos líneas caben si el contenido sin la fila más 33 px no pasa del alto" $ do
      valuesRowFits 292.5 259.5 `shouldBe` True
      valuesRowFits 292.5 260 `shouldBe` False

    it "la tabla de mando abre a la izquierda, y el eje va siempre en el lado contrario" $ do
      defaultControlSide `shouldBe` SideLeft
      map otherSide [SideLeft, SideRight] `shouldBe` [SideRight, SideLeft]

    it "la tarjeta de hoy (893 px): la tabla mide su máximo, 225; eje fuera" $ do
      let l = cardLayout 893
      clStacked l `shouldBe` False
      clControl l `shouldBe` 225
      clChart l `shouldSatisfy` near (893 - 225 - columnGap)
      clAxisInside l `shouldBe` False

    it "el «VS» va al lado de la referencia si cabe en su margen: desde ~185 px de tabla" $ do
      vsBeside carSelectWidth `shouldBe` False
      vsBeside 184 `shouldBe` False
      vsBeside 185 `shouldBe` True
      vsBeside controlMaxWidth `shouldBe` True

    prop "si el «VS» cabe al lado en un ancho, cabe en cualquiera mayor" vsBesideMonotone

    it "la tabla de mando es un tercio, entre el desplegable de piloto y su máximo" $ do
      controlWidth 500 `shouldSatisfy` near (500 / 3)
      controlWidth 400 `shouldBe` carSelectWidth

    it "los cuatro valores, centrados en sus puntos, caben desde ~162,5 px de gráfica" $ do
      valuesFit 162.4 `shouldBe` False
      valuesFit 162.5 `shouldBe` True

    it "las trazas dejan medio valor a la derecha, y a la izquierda el valor se mete la mitad" $ do
      let (left, right) = tracesInset
      right `shouldSatisfy` (>= valueWidth / 2)
      near (valueWidth / 2 - left) left `shouldBe` True

    it "por debajo de ~323,5 px se apila, y apilada la gráfica tiene todo el ancho" $ do
      clStacked (cardLayout 323.5) `shouldBe` False
      cardLayout 323 `shouldBe` CardLayout True 323 323 False

    it "el eje entra por debajo de ~367 px con dos columnas y de ~206 apilada" $
      map (clAxisInside . cardLayout) [367.5, 367, 323, 206.5, 206]
        `shouldBe` [False, True, False, False, True]

    describe "insideAxisLabels" $ do
      let norLec = [0, -0.134, 0.193, 0.617]
          placed side w = [(label, round x :: Int) | (x, _, label) <- insideAxisLabels side w norLec]
      it "NOR contra LEC a la derecha en 160 px: el +0.600 y el +0.400 se apartan de la curva" $
        placed SideRight 160
          `shouldBe` [ ("+0.600 s", 94), ("+0.400 s", 76), ("+0.200 s", 120)
                     , ("\x2212\&0.200 s", 120) ]

      it "a la izquierda nada se aparta: la curva empieza en el cero, que no se escribe" $
        placed SideLeft 160
          `shouldBe` [ ("+0.600 s", 0), ("+0.400 s", 0), ("+0.200 s", 0)
                     , ("\x2212\&0.200 s", 0) ]

      it "sin un tramo libre en su línea, el número no sale" $
        insideAxisLabels SideRight 90 [0, 0.4, -0.4, 0.4, -0.4, 0.4] `shouldBe` []

      it "no pasa de los tres cuartos: con el único hueco en el cuarto de la tabla, no sale" $
        [label | (_, _, label) <- insideAxisLabels SideRight 184.5 [0, 0.3, 0.3, 0.3]]
          `shouldBe` ["+0.250 s", "+0.200 s", "+0.150 s", "+0.100 s", "+0.050 s"]

      prop "cada número cabe en sus tres cuartos de la gráfica y la curva no lo tapa"
        insideLabelsClear

    prop "con dos columnas, tabla, hueco y gráfica suman la tarjeta" twoColumnsAddUp
    prop "la tabla de mando nunca baja del desplegable ni pasa de su máximo" controlWithinBounds
    prop "si los valores caben en un ancho, caben en cualquiera mayor" valuesFitMonotone

  describe "formatDelta" $ do
    it "el positivo lleva +, y el negativo el menos tipográfico" $ do
      formatDelta 0.617 `shouldBe` "+0.617 s"
      formatDelta (-0.134) `shouldBe` "\x2212\&0.134 s"

    it "lo que redondea a cero va sin signo" $ do
      formatDelta 0 `shouldBe` "0.000 s"
      formatDelta (-0.0004) `shouldBe` "0.000 s"

    it "lo no finito es la raya de no-dato" $
      formatDelta (0 / 0) `shouldBe` noData

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

    -- El reloj de la sesión. La entrada son los segundos que `SessionClock`
    -- lleva, y las tres formas se distinguen solo en cuánto sitio ocupan.
    it "por debajo de la hora, la forma corta se ahorra las horas" $ do
      formatClock ClockCompact 900 `shouldBe` "15:00"
      formatClock ClockCompact 59  `shouldBe` "0:59"
      formatClock ClockCompact 9   `shouldBe` "0:09"
      formatClock ClockCompact 60  `shouldBe` "1:00"

    it "la hora justa es donde la corta cambia de forma" $ do
      formatClock ClockCompact 3599 `shouldBe` "59:59"
      formatClock ClockCompact 3600 `shouldBe` "1:00:00"

    it "la media lleva horas aunque sean cero" $ do
      formatClock ClockHours 900 `shouldBe` "0:15:00"
      formatClock ClockHours 9   `shouldBe` "0:00:09"

    it "la larga rellena la hora a dos dígitos" $ do
      formatClock ClockPadded 900  `shouldBe` "00:15:00"
      formatClock ClockPadded 9    `shouldBe` "00:00:09"
      formatClock ClockPadded 5025 `shouldBe` "01:23:45"

    it "las horas no se envuelven al pasar del día" $ do
      -- 25 h 1 min 1 s. El relleno de la larga es un mínimo, no un recorte.
      formatClock ClockCompact 90061 `shouldBe` "25:01:01"
      formatClock ClockPadded  90061 `shouldBe` "25:01:01"

    it "un restante negativo es cero y no una resta que se fue" $ do
      formatClock ClockCompact (-1) `shouldBe` "0:00"
      formatClock ClockHours   (-1) `shouldBe` "0:00:00"
      formatClock ClockPadded  (-1) `shouldBe` "00:00:00"

    prop "formatFixed nunca emite notación científica" neverScientific
    prop "formatTrimmed no deja cola de ceros ni punto suelto" trimLeavesNoTail
    prop "por encima de la hora, la corta y la media no se distinguen" clockFormsMeet

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

  describe "minWidthFor y minHeightFor" $ do
    -- Los números medidos en Edge, tipo por tipo: lo único que caza un 30 escrito
    -- donde iba un 35.
    it "son los medidos, como (ancho, alto)" $
      map (\t -> (minWidthFor t, minHeightFor t))
          [ LiveTiming, Telemetry, LapComparison, HistoricalStats
          , ConstructorStats, TyreStrategy, Custom ]
        `shouldBe` [ (30, 20), (35, 30), (25, 50), (25, 20)
                   , (20, 20), (30, 20), (25, 20) ]

    it "caen todos en celda del imán" $
      filter ((/= 0) . (`mod` 5))
          (concatMap (\t -> [minWidthFor t, minHeightFor t])
             [ LiveTiming, Telemetry, LapComparison, HistoricalStats
             , ConstructorStats, TyreStrategy, Custom ])
        `shouldBe` []

  describe "clampToMin" $ do
    it "sube al mínimo el widget demasiado estrecho para su contenido" $
      wcW (clampToMin (rect LiveTiming (0, 0, 12, 40))) `shouldBe` minWidthFor LiveTiming

    it "sube al mínimo el widget demasiado bajo para su contenido" $
      wcH (clampToMin (rect LapComparison (0, 0, 60, 10))) `shouldBe` minHeightFor LapComparison

    it "deja intacto al que ya cumple, sin redondear ni pegar a la rejilla" $
      clampToMin (rect Telemetry (7, 3, 63, 41)) `shouldBe` rect Telemetry (7, 3, 63, 41)

    -- El caso que fija el reparto del 2026-09-04 (c). Si esta función moviera el
    -- widget, `fitsAt` no tendría nunca nada que decir sobre un layout saneado y
    -- la marca visible no aparecería jamás.
    it "no mueve nada nunca, ni cuando el widget se sale del lienzo" $ do
      let w = clampToMin (rect LiveTiming (100, 110, 45, 10))
      wcX w `shouldBe` 100
      wcY w `shouldBe` 110
      wcH w `shouldBe` minHeightFor LiveTiming

    it "tampoco recorta al que se sale: agrandar es todo lo que hace" $ do
      let w = clampToMin (rect Custom (0, 0, 200, 150))
      wcW w `shouldBe` 200
      wcH w `shouldBe` 150

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

    it "rechaza al que se sale por abajo" $
      fitsAt (rect LiveTiming (0, 100, 60, 90)) `shouldBe` False

    it "rechaza al que baja de su alto mínimo" $
      fitsAt (rect LapComparison (60, 35, 60, 45)) `shouldBe` False

    it "rechaza la coordenada vertical negativa" $
      fitsAt (rect LiveTiming (0, -5, 60, 40)) `shouldBe` False

    it "acepta al que llega justo al borde de abajo" $
      fitsAt (rect ConstructorStats (60, 90, 60, 30)) `shouldBe` True

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

  -- La traducción del rectángulo a CSS (2026-09-07). Lo que
  -- se prueba NO es la aritmética —con `calc` la hace el navegador y aquí no hay
  -- ninguna división— sino que la traducción __no pierde nada__: si la unidad
  -- viaja literal, la exactitud de los bordes compartidos es consecuencia y no
  -- hace falta una cota de redondeo que probar.
  describe "slotStyle" $ do
    it "emite la unidad y el lienzo tal cual, sin dividir" $
      spanCss 35 `shouldBe` "calc(35 * 100% / 120)"

    -- El caso que motivó `calc`: 35·100/120 = 29.1666… Si alguna unidad llegara
    -- a producir un decimal, la división se estaría haciendo aquí.
    it "ninguna unidad del lienzo produce un decimal" $
      filter (T.any (== '.')) (map spanCss [0 .. canvasSpan]) `shouldBe` []

    it "emite las cuatro declaraciones, y ninguna más" $
      map (T.takeWhile (/= ':')) (T.splitOn "; " (slotStyle (rect LiveTiming (0, 0, 60, 90))))
        `shouldBe` ["left", "top", "width", "height"]

    -- El borde entre `telemetry` y `lap-comparison` en Race Overview: el bajo de
    -- uno y el alto del otro tienen que salir como la MISMA cantidad, no como dos
    -- redondeos que casi coinciden. Es lo que impide la raya de fondo o el píxel
    -- montado entre dos widgets pegados.
    it "el borde compartido de dos widgets pegados es la misma cantidad exacta" $
      let arriba = rect Telemetry     (60,  0, 60, 35)
          abajo  = rect LapComparison (60, 35, 60, 50)
       in spanCss (wcY arriba + wcH arriba) `shouldBe` spanCss (wcY abajo)

    it "el widget que llena el lienzo va del 0 al 100 %" $
      map slotStyle qualyFixture
        `shouldBe` [ "left: calc(0 * 100% / 120); top: calc(0 * 100% / 120); \
                     \width: calc(120 * 100% / 120); height: calc(120 * 100% / 120)" ]

    -- Las 5 unidades bajo `lap-comparison` son un hueco deliberado (los huecos
    -- son legales desde el 2026-09-03) y existen para comprobar que el lienzo NO
    -- los rellena solo. Si la traducción los cerrara por redondeo, la
    -- comprobación visual de hoy diría que sí los rellena y sería mentira.
    it "el hueco bajo lap-comparison sobrevive a la traducción" $
      spanCss 85 `shouldNotBe` spanCss 90

  -- __El caso que más vale de todo el bloque.__ Los seis rectángulos de
  -- `Pages.Dashboard` están escritos a mano y un typo NO lo caza el compilador —
  -- mismo riesgo que los `WidgetId` literales del 2026-09-01, con la misma
  -- consecuencia: se nota al mirar la página, no al compilar.
  --
  -- __Los layouts son una COPIA__ y esa es su debilidad: `frontend` no está en
  -- `cabal.project`, así que la suite no puede importar los de verdad. Si alguien
  -- toca las coordenadas de `Pages.Dashboard` y no toca estas, el test seguirá
  -- verde midiendo un layout que ya no existe. Mientras sea copia, hay que
  -- cambiar los dos sitios.
  describe "applyDrag" $ do
    let onRace wid d = applyDrag gridDivisions raceOverviewFixture (d (WidgetId wid))
        rects        = fmap (map (\w -> (wcX w, wcY w, wcW w, wcH w)))
        column       = [ rectNamed "c1" Custom (0,  0, 30, 40)
                       , rectNamed "c2" Custom (0, 40, 30, 40)
                       , rectNamed "c3" Custom (0, 80, 30, 40) ]
        onColumn divs wid d = rects (applyDrag divs column (d (WidgetId wid)))

    it "Constructores encima de Lap Comparison: la tapa de lado a lado y Lap Comparison baja entera" $
      rects (onRace "constructor-stats" (\w -> MoveTo w 60 35))
        `shouldBe` Just [(0, 0, 60, 90), (60, 0, 60, 35), (60, 65, 60, 50), (0, 90, 60, 30), (60, 35, 60, 30)]

    it "Telemetry 20 a la izquierda: Live Timing se estrecha por el lado del menor solape" $
      rects (onRace "telemetry" (\w -> MoveTo w 40 0))
        `shouldBe` Just [(0, 0, 40, 90), (40, 0, 60, 35), (60, 35, 60, 50), (0, 90, 60, 30), (60, 90, 60, 30)]

    -- Telemetry 35 + Pilotos 30 + los mínimos de Lap Comparison (50) y Constructores
    -- (20) suman 135: la columna no cabe, y en una columna no se prueba el otro eje.
    it "Pilotos a la columna derecha no se deja, con el imán y sin él" $ do
      onRace "driver-stats" (\w -> MoveTo w 60 35) `shouldBe` Nothing
      applyDrag 0 raceOverviewFixture (MoveTo (WidgetId "driver-stats") 60 35) `shouldBe` Nothing

    it "estirar Telemetry empuja la columna, y Constructores encoge hasta su mínimo" $
      rects (onRace "telemetry" (\w -> ResizeTo w 60 50))
        `shouldBe` Just [(0, 0, 60, 90), (60, 0, 60, 50), (60, 50, 60, 50), (0, 90, 60, 30), (60, 100, 60, 20)]

    it "Live Timing sobre la columna derecha intercambia las columnas" $
      rects (onRace "live-timing" (\w -> MoveTo w 60 0))
        `shouldBe` Just [(60, 0, 60, 90), (0, 0, 60, 35), (0, 35, 60, 50), (0, 90, 60, 30), (60, 90, 60, 30)]

    it "soltar en el mismo sitio no cambia nada" $
      onRace "telemetry" (\w -> MoveTo w 60 0) `shouldBe` Just raceOverviewFixture

    it "lo que se sale del lienzo se queda en el borde" $
      onRace "constructor-stats" (\w -> MoveTo w 200 200) `shouldBe` Just raceOverviewFixture

    it "un widget que no está no se deja" $
      onRace "no-existe" (\w -> MoveTo w 0 0) `shouldBe` Nothing

    it "en una columna, la de abajo arriba del todo reordena y la de arriba abajo también" $ do
      onColumn gridDivisions "c3" (\w -> MoveTo w 0 0)
        `shouldBe` Just [(0, 40, 30, 40), (0, 80, 30, 40), (0, 0, 30, 40)]
      onColumn gridDivisions "c1" (\w -> MoveTo w 0 80)
        `shouldBe` Just [(0, 80, 30, 40), (0, 0, 30, 40), (0, 40, 30, 40)]

    it "en una fila, la de la derecha a la izquierda del todo reordena" $
      rects (applyDrag gridDivisions
               [ rectNamed "f1" Custom (0, 0, 30, 40), rectNamed "f2" Custom (30, 0, 30, 40)
               , rectNamed "f3" Custom (60, 0, 30, 40) ]
               (MoveTo (WidgetId "f3") 0 0))
        `shouldBe` Just [(30, 0, 30, 40), (60, 0, 30, 40), (0, 0, 30, 40)]

    it "estirar hasta tapar entera a la de abajo la empuja hacia donde crece" $
      onColumn gridDivisions "c1" (\w -> ResizeTo w 30 80)
        `shouldBe` Just [(0, 0, 30, 80), (0, 80, 30, 20), (0, 100, 30, 20)]

    -- La cadena encoge en proporción; con el imán, cada alto al múltiplo de 5 y la
    -- del borde se queda con lo que sobre; sin él, de 1 en 1.
    it "el redondeo del encogido sigue al imán" $ do
      onColumn gridDivisions "c1" (\w -> ResizeTo w 30 57)
        `shouldBe` Just [(0, 0, 30, 57), (0, 57, 30, 30), (0, 87, 30, 33)]
      onColumn 0 "c1" (\w -> ResizeTo w 30 57)
        `shouldBe` Just [(0, 0, 30, 57), (0, 57, 30, 31), (0, 88, 30, 32)]

    prop "tras un sí, los mismos widgets, sin solapes y cabiendo" dragKeepsLayoutValid
    prop "la que se lleva queda donde se pide, dentro del lienzo y con su tamaño" moveKeepsHeld

  -- Un lienzo de 1200 × 600 px: 10 px por unidad en x y 5 en y, para que las
  -- cuentas salgan exactas en coma flotante.
  describe "Common.Carry" $ do
    let cs       = WidgetId "constructor-stats"
        canvas   = (1200, 600)
        grabbed  = stepBoard True (Press cs ByTitle (700, 500) canvas) (boardOf raceOverviewFixture)
        toY y alt = stepBoard True (Point (700, 500 + (y - 90) * 5) alt) grabbed
        rects    = map (\w -> (wcX w, wcY w, wcW w, wcH w))

    it "el imán: la rejilla si está encendido sin Alt o apagado con Alt; si no, de 1 en 1" $
      map (uncurry magnetDivisions) [(True, False), (True, True), (False, True), (False, False)]
        `shouldBe` [gridDivisions, 0, gridDivisions, 0]

    it "Constructores en y = 37,25: se pinta ahí, el contorno cae en 35 y Lap Comparison baja a 65 (D125)" $ do
      let s = scene True (toY 37.25 False)
      sceneHeld s `shouldBe` Just (Held cs 60 37.25 60 30 True)
      fmap (\t -> (wcX t, wcY t, wcW t, wcH t)) (sceneTarget s) `shouldBe` Just (60, 35, 60, 30)
      rects (sceneCards s)
        `shouldBe` [(0, 0, 60, 90), (60, 0, 60, 35), (60, 65, 60, 50), (0, 90, 60, 30), (60, 35, 60, 30)]

    it "en y = 60 no se deja: las demás se quedan en la foto y no hay contorno" $ do
      let s = scene True (toY 60 False)
      fmap heldFits (sceneHeld s) `shouldBe` Just False
      sceneCards s `shouldBe` raceOverviewFixture
      sceneTarget s `shouldBe` Nothing

    it "soltar deja el empuje; soltar donde no se deja, Esc y un clic sin mover dejan la foto" $ do
      rects (boardLayout (stepBoard True Release (toY 37.25 False)))
        `shouldBe` [(0, 0, 60, 90), (60, 0, 60, 35), (60, 65, 60, 50), (0, 90, 60, 30), (60, 35, 60, 30)]
      boardLayout (stepBoard True Release (toY 60 False)) `shouldBe` raceOverviewFixture
      boardLayout (stepBoard True Cancel (toY 37.25 False)) `shouldBe` raceOverviewFixture
      boardLayout (stepBoard True Release grabbed) `shouldBe` raceOverviewFixture
      boardCarry (stepBoard True Cancel (toY 37.25 False)) `shouldBe` Nothing

    it "con Alt, el imán encendido redondea de 1 en 1: el contorno cae en 37" $ do
      fmap wcY (sceneTarget (scene True (toY 37.25 True))) `shouldBe` Just 37
      fmap wcY (sceneTarget (scene True (stepBoard True (AltKey True) (toY 37.25 False)))) `shouldBe` Just 37

    it "fuera del lienzo, la que se lleva se queda en el borde" $ do
      let far = stepBoard True (Point (90000, -90000) False) grabbed
      fmap (\h -> (heldX h, heldY h)) (sceneHeld (scene True far)) `shouldBe` Just (60, 0)

    it "sin nada cogido no pasa nada, y no se coge otra mientras se lleva una ni con el lienzo sin medir" $ do
      let idle = boardOf raceOverviewFixture
      map (\h -> stepBoard True h idle) [Point (1, 2) False, AltKey True, Release, Cancel]
        `shouldBe` replicate 4 idle
      stepBoard True (Press cs ByTitle (1, 2) (0, 600)) idle `shouldBe` idle
      stepBoard True (Press (WidgetId "nadie") ByTitle (1, 2) canvas) idle `shouldBe` idle
      fmap carryId (boardCarry (stepBoard True (Press (WidgetId "telemetry") ByCorner (1, 2) canvas) grabbed))
        `shouldBe` Just cs

    it "por la esquina, Lap Comparison a 61,25 de alto: el contorno en 60 y Constructores encoge a 25" $ do
      let lc = WidgetId "lap-comparison"
          s  = scene True (stepBoard True (Point (700, 500 + 11.25 * 5) False)
                 (stepBoard True (Press lc ByCorner (700, 500) canvas) (boardOf raceOverviewFixture)))
      sceneHeld s `shouldBe` Just (Held lc 60 35 60 61.25 True)
      fmap (\t -> (wcX t, wcY t, wcW t, wcH t)) (sceneTarget s) `shouldBe` Just (60, 35, 60, 60)
      rects (sceneCards s)
        `shouldBe` [(0, 0, 60, 90), (60, 0, 60, 35), (60, 35, 60, 60), (0, 90, 60, 30), (60, 95, 60, 25)]

    it "por la esquina, de 70 en adelante no se deja; y no baja de su mínimo ni se sale del lienzo" $ do
      let lc       = WidgetId "lap-comparison"
          stretch p = scene True (stepBoard True (Point p False)
                        (stepBoard True (Press lc ByCorner (700, 500) canvas) (boardOf raceOverviewFixture)))
      fmap heldFits (sceneHeld (stretch (700, 500 + 22.5 * 5))) `shouldBe` Just False
      fmap (\h -> (heldW h, heldH h)) (sceneHeld (stretch (-90000, -90000))) `shouldBe` Just (25, 50)
      fmap (\h -> (heldW h, heldH h)) (sceneHeld (stretch (90000, 90000))) `shouldBe` Just (60, 85)

    it "el estilo de la que se lleva: su rectángulo con dos decimales" $
      heldStyle (Held cs 60 37.25 60 30 True)
        `shouldBe` "left: calc(60.00 * 100% / 120); top: calc(37.25 * 100% / 120); \
                   \width: calc(60.00 * 100% / 120); height: calc(30.00 * 100% / 120)"

    prop "lo que enseña el contorno es lo que queda al soltar, y si no se deja queda la foto" carryShowsDrop

  describe "Common.Saved" $ do
    let place w (x, y, wd, ht) = w { wcX = x, wcY = y, wcW = wd, wcH = ht }
        -- D125: Constructores sube a 35 y Lap Comparison baja a 65.
        moved = zipWith place raceOverviewFixture
                  [(0, 0, 60, 90), (60, 0, 60, 35), (60, 65, 60, 50), (0, 90, 60, 30), (60, 35, 60, 30)]
        moving wid r = map (\w -> if widgetId w == WidgetId wid then place w r else w) raceOverviewFixture
        raceSides  = factoryControls raceOverviewFixture
        lapCard f  = Map.adjust f (WidgetId "lap-comparison")
        rightSides = lapCard (\c -> c { ccSide = SideRight }) raceSides
        save       = saveLayout raceSides

    it "sin nada guardado, el de fábrica y sin aviso" $
      restoreLayout raceOverviewFixture Nothing `shouldBe` FromFactory

    it "el de fábrica lo es en cualquier orden; una tarjeta movida o un lado cambiado, no" $
      map (\(sides, shown) -> atFactory raceOverviewFixture sides shown)
          [ (raceSides, raceOverviewFixture)
          , (raceSides, reverse raceOverviewFixture)
          , (raceSides, moved)
          , (raceSides, moving "lap-comparison" (60, 35, 60, 51))
          , (rightSides, raceOverviewFixture)
          ]
        `shouldBe` [True, True, False, False, False]

    it "lo movido y vuelto a su sitio es otra vez el de fábrica" $
      atFactory raceOverviewFixture raceSides (moving "lap-comparison" (60, 35, 60, 50))
        `shouldBe` True

    it "dos estados se ven igual con los mismos rectángulos y lados, y no si cambia uno" $
      map (sameShown (rightSides, moved))
          [(rightSides, reverse moved), (raceSides, moved), (rightSides, raceOverviewFixture)]
        `shouldBe` [True, False, False]

    it "lo guardado vuelve tal cual, en los dos layouts" $ do
      restoreLayout raceOverviewFixture (Just (save moved)) `shouldBe` FromSaved moved raceSides
      restoreLayout qualyFixture (Just (saveLayout Map.empty qualyFixture)) `shouldBe` FromSaved qualyFixture Map.empty

    it "lo guardado pone solo el rectángulo y el lado: el resto y el orden son los de fábrica" $ do
      let hidden = map (\w -> w { widgetVisible = False }) raceOverviewFixture
      restoreLayout hidden (Just (save (reverse moved)))
        `shouldBe` FromSaved (zipWith (\h m -> h { wcX = wcX m, wcY = wcY m, wcW = wcW m, wcH = wcH m }) hidden moved) raceSides

    it "el formato y la clave: un rectángulo por tarjeta, con su id" $ do
      let expected = decodeStrictText
            "[{\"savedId\":\"qualy-live-timing\",\"savedX\":0,\"savedY\":0,\"savedW\":120,\"savedH\":120}]"
      expected `shouldSatisfy` (/= (Nothing :: Maybe Value))
      decodeStrictText (saveLayout (factoryControls qualyFixture) qualyFixture) `shouldBe` expected
      savedKey (LayoutId "race-overview") `shouldBe` "dashboardF1.layout.race-overview"

    it "solo Lap Comparison lleva lado, banda y modo, los de fábrica, y los escribe siempre" $ do
      raceSides `shouldBe` Map.singleton (WidgetId "lap-comparison") defaultControl
      defaultControl `shouldBe` CardControl SideLeft False ModeAxisValues
      factoryControls qualyFixture `shouldBe` Map.empty
      let lapOnly  = filter ((== LapComparison) . widgetType) raceOverviewFixture
          expected = decodeStrictText
            "[{\"savedId\":\"lap-comparison\",\"savedX\":60,\"savedY\":35,\"savedW\":60,\"savedH\":50,\
            \\"savedSide\":\"left\",\"savedBand\":false,\"savedMode\":\"axis-values\"}]"
      expected `shouldSatisfy` (/= (Nothing :: Maybe Value))
      decodeStrictText (save lapOnly) `shouldBe` expected

    it "el lado guardado vuelve; sin él (guardado antes de que existiera), el de fábrica" $ do
      restoreLayout raceOverviewFixture (Just (saveLayout rightSides moved)) `shouldBe` FromSaved moved rightSides
      restoreLayout raceOverviewFixture (Just (saveLayout Map.empty moved)) `shouldBe` FromSaved moved raceSides

    it "la banda y el modo guardados vuelven; sin ellos (guardado antes de que existieran), los de fábrica" $ do
      let banded = lapCard (\c -> c { ccBand = True, ccMode = ModeValues }) rightSides
          noBand = T.replace ",\"savedBand\":true,\"savedMode\":\"values\"" "" (saveLayout banded moved)
      restoreLayout raceOverviewFixture (Just (saveLayout banded moved)) `shouldBe` FromSaved moved banded
      noBand `shouldSatisfy` (not . T.isInfixOf "savedBand")
      restoreLayout raceOverviewFixture (Just noBand) `shouldBe` FromSaved moved rightSides

    it "un lado en una tarjeta que no es Lap Comparison se ignora" $
      restoreLayout raceOverviewFixture
          (Just (saveLayout (Map.insert (WidgetId "telemetry") defaultControl { ccSide = SideRight } rightSides) moved))
        `shouldBe` FromSaved moved rightSides

    it "un lado, una banda o un modo ilegibles no se leen, y lo que no encaja no conserva nada" $
      map (restoreLayout raceOverviewFixture . Just)
        [ T.replace "\"right\"" "\"up\"" (saveLayout rightSides moved)
        , T.replace "\"savedBand\":false" "\"savedBand\":\"no\"" (saveLayout rightSides moved)
        , T.replace "\"axis-values\"" "\"ejes\"" (saveLayout rightSides moved)
        , saveLayout rightSides (moving "lap-comparison" (60, 35, 60, 45))
        ]
        `shouldBe` replicate 4 Unfit

    it "no encaja si no se lee, si las tarjetas no son las de fábrica, si alguna queda bajo su mínimo, fuera o encima de otra" $
      map (restoreLayout raceOverviewFixture . Just)
        [ "", "{", "null", "[]"
        , save (init raceOverviewFixture)
        , save (raceOverviewFixture <> [rectNamed "tyres" TyreStrategy (0, 0, 30, 20)])
        , save (init raceOverviewFixture <> take 1 raceOverviewFixture)
        , save (init raceOverviewFixture <> [rectNamed "constructores" ConstructorStats (60, 90, 60, 30)])
        , save (moving "lap-comparison" (60, 35, 60, 45))
        , save (moving "constructor-stats" (70, 90, 60, 30))
        , save (moving "telemetry" (60, 0, 60, 40))
        ]
        `shouldBe` replicate 11 Unfit

    prop "todo lo que deja el arrastre se guarda y vuelve igual" savedDropRoundTrips

    it "la nota: con un layout, sin nombrarlo; con varios, todos por su nombre; sin ninguno, vacía" $ do
      unfitNote ["Qualy"]
        `shouldBe` "Volvió a la configuración predeterminada: lo guardado ya no encaja con el diseño de hoy. \
                   \(Pulsa para cerrar; el asterisco se queda hasta pulsar «✎ Editar layout».)"
      unfitNote ["Race Overview", "Qualy"]
        `shouldBe` "Race Overview y Qualy volvieron a la configuración predeterminada: lo guardado ya no encaja \
                   \con el diseño de hoy. \
                   \(Pulsa para cerrar; los asteriscos se quedan hasta pulsar «✎ Editar layout».)"
      T.takeWhile (/= ':') (unfitNote ["A", "B", "C"])
        `shouldBe` "A, B y C volvieron a la configuración predeterminada"
      unfitNote [] `shouldBe` ""

  describe "los layouts fijos de Pages.Dashboard" $ do
    it "los seis widgets caben donde dicen estar" $
      filter (not . fitsAt) (raceOverviewFixture <> qualyFixture) `shouldBe` []

    it "clampToMin no cambia ninguno: los seis respetan ya su ancho mínimo" $
      map clampToMin (raceOverviewFixture <> qualyFixture)
        `shouldBe` (raceOverviewFixture <> qualyFixture)

    it "ninguno baja de su alto mínimo" $
      filter (\w -> wcH w < minHeightFor (widgetType w))
          (raceOverviewFixture <> qualyFixture)
        `shouldBe` []

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

    -- Los mismos seis rectángulos, ahora vistos por el lado que la página
    -- consume. Los dos casos de arriba dicen que los rectángulos son legales;
    -- este dice CUÁLES son, que es lo único que caza un 35 escrito donde iba
    -- un 30.
    it "los seis slots traducen a su rectángulo" $
      map slotStyle (raceOverviewFixture <> qualyFixture)
        `shouldBe` map expectedSlot
             [ (  0,  0,  60,  90)
             , ( 60,  0,  60,  35)
             , ( 60, 35,  60,  50)
             , (  0, 90,  60,  30)
             , ( 60, 90,  60,  30)
             , (  0,  0, 120, 120)
             ]

    it "las coordenadas caen todas en celda del imán" $
      let coords w = [wcX w, wcY w, wcW w, wcH w]
       in filter ((/= 0) . (`mod` 5)) (concatMap coords (raceOverviewFixture <> qualyFixture))
            `shouldBe` []

    -- Quién queda debajo del botón de plegar la cabecera, que es `fixed` en la
    -- esquina de la ventana. El caso vale por lo que NOMBRA: si mañana alguien
    -- mueve `telemetry` a x=55, el hueco se quedaría en un widget que ya no lo
    -- necesita y le faltaría al que sí, y eso no se ve compilando.
    it "solo telemetry y el live timing de Qualy tocan la esquina superior derecha" $
      map widgetId (filter touchesTopRight (raceOverviewFixture <> qualyFixture))
        `shouldBe` [WidgetId "telemetry", WidgetId "qualy-live-timing"]

    -- Las dos mitades de la condición, cada una por su lado: `live-timing`
    -- empieza arriba pero acaba en 60, y `constructor-stats` acaba en el borde
    -- derecho pero empieza abajo. Ninguno de los dos toca la esquina, y son los
    -- vecinos que la delatarían si la condición perdiera una de sus dos mitades.
    it "ni empezar arriba ni acabar a la derecha bastan por separado" $
      map touchesTopRight [rect LiveTiming (0, 0, 60, 90), rect ConstructorStats (60, 90, 60, 30)]
        `shouldBe` [False, False]

  describe "Common.Origin" $ do
    it "cada procedencia tiene su valor de cabecera, y son distintos entre sí" $
      -- El orden es el del `Ord`, que es la escalera de mejor a peor: `recent` va
      -- entre las dos porque un dato que nadie quiso repetir es peor que uno recién
      -- traído y mejor que uno servido porque no hubo otra.
      map originLabel [minBound .. maxBound]
        `shouldBe` ["fresh", "recent", "cached", "sample"]

    it "lee el valor tal cual lo emite el backend" $
      map originFrom ["fresh", "recent", "cached", "sample"]
        `shouldBe` [Just Fresh, Just Recent, Just Cached, Just Sample]

    it "tolera espacios y mayúsculas de por medio" $
      map originFrom ["  CACHED ", "Sample", "FrEsH", " ReCeNt"]
        `shouldBe` [Just Cached, Just Sample, Just Fresh, Just Recent]

    it "no adivina: lo que no reconoce es Nothing" $
      map originFrom ["", "   ", "live", "cache", "dummy"]
        `shouldBe` [Nothing, Nothing, Nothing, Nothing, Nothing]

    it "el dato fresco no genera aviso, con hora o sin ella" $
      [originNotice Fresh Nothing, originNotice Fresh (Just "14:32")]
        `shouldBe` [Nothing, Nothing]

    it "el dato guardado avisa y lleva la hora dentro" $
      originNotice Cached (Just "14:32")
        `shouldBe` Just "Dato guardado: la fuente no responde ahora mismo (14:32)"

    it "el reciente NO dice que la fuente no responda, que es de lo que se trata" $
      -- Es la razón de existir del cuarto valor: con el backend frenándose a sí
      -- mismo, «la fuente no responde» sería falso la mayor parte del tiempo, y con
      -- él la única señal de fallo que tiene la página.
      originNotice Recent (Just "14:32")
        `shouldBe` Just "Dato reciente: no se ha vuelto a preguntar (14:32)"

    it "el reciente sin hora también avisa, y sin paréntesis vacío" $
      -- Mismo trato que el guardado, y del mismo sitio: el paréntesis es del hecho
      -- de estar guardado, no del motivo.
      [originNotice Recent Nothing, originNotice Recent (Just "  ")]
        `shouldBe` [ Just "Dato reciente: no se ha vuelto a preguntar"
                   , Just "Dato reciente: no se ha vuelto a preguntar"
                   ]

    it "el dato guardado sin hora sigue avisando, y sin paréntesis vacío" $
      [originNotice Cached Nothing, originNotice Cached (Just "  ")]
        `shouldBe` [ Just "Dato guardado: la fuente no responde ahora mismo"
                   , Just "Dato guardado: la fuente no responde ahora mismo"
                   ]

    it "el dato de ejemplo avisa siempre, y la hora no le añade nada" $
      [originNotice Sample Nothing, originNotice Sample (Just "14:32")]
        `shouldBe` [ Just "Datos de ejemplo: la fuente nunca ha respondido"
                   , Just "Datos de ejemplo: la fuente nunca ha respondido"
                   ]

    prop "originFrom es inversa de originLabel para todas" originRoundTrips
    prop "solo Fresh calla; los otros tres avisan siempre" onlyFreshIsSilent

  -- El segundo eje del módulo, y va aparte porque es una pregunta distinta: el
  -- peldaño dice qué sirvió el dato y la fuente de dónde salió. Las dos fuentes son
  -- complementarias —el feed publica mientras la sesión rueda y OpenF1 después—, así
  -- que ningún valor de un eje implica uno del otro.
  describe "Common.Origin — la fuente" $ do
    it "cada fuente tiene su valor de cabecera, y son distintos entre sí" $
      map sourceLabel [minBound .. maxBound] `shouldBe` ["feed", "openf1"]

    it "lee el valor tal cual lo emite el backend" $
      map sourceFrom ["feed", "openf1"] `shouldBe` [Just Feed, Just OpenF1]

    it "tolera espacios y mayúsculas, como la procedencia" $
      map sourceFrom ["  FEED ", "OpenF1"] `shouldBe` [Just Feed, Just OpenF1]

    it "no adivina: lo que no reconoce es Nothing" $
      map sourceFrom ["", "   ", "open f1", "fastf1", "sample"]
        `shouldBe` [Nothing, Nothing, Nothing, Nothing, Nothing]

    -- Uno lo lee una máquina y el otro una persona; si coincidieran, el texto de la
    -- pantalla quedaría atado al valor del protocolo.
    it "el nombre que se lee no es el valor que viaja" $
      map sourceName [minBound .. maxBound] `shouldBe` ["Feed oficial", "OpenF1"]

    -- Los tres nombres los leen los dos extremos, así que clavarlos aquí es lo que
    -- impide renombrar uno de un lado y dejar al otro buscando el viejo.
    it "las tres cabeceras tienen nombres distintos, y son éstos" $
      [originHeader, fetchedAtHeader, sourceHeader]
        `shouldBe` ["X-Data-Origin", "X-Data-Fetched-At", "X-Data-Source"]

    prop "sourceFrom es inversa de sourceLabel para las dos" sourceRoundTrips

  -- El nombre de cada cabecera vive dos veces —'Text' en 'Common.Origin', 'Symbol'
  -- en el tipo de Servant— y si divergen el widget no reconoce la cabecera y calla
  -- sin error. El primer caso es el que lo impide.
  describe "Provenance — procedencia en cabeceras" $ do
    it "los nombres del tipo de Servant son los de Common.Origin" $
      map T.pack [ symbolVal (Proxy :: Proxy OriginHeaderName)
                 , symbolVal (Proxy :: Proxy FetchedAtHeaderName)
                 , symbolVal (Proxy :: Proxy SourceHeaderName)
                 ]
        `shouldBe` [originHeader, fetchedAtHeader, sourceHeader]

    it "el dato fresco del feed lleva procedencia y fuente, y no el instante" $
      headersOf (withProvenance (Provenanced Fresh (Just Feed) Nothing liveTableFixture))
        `shouldBe` (Header "fresh", MissingHeader, Header "feed")

    it "el dato fresco de OpenF1 dice que es de OpenF1, con la misma procedencia" $
      -- La mitad que hace falta la cabecera: los dos peldaños son `fresh` y sin
      -- ella la página no puede distinguir la sesión en marcha de la terminada.
      headersOf
        (withProvenance (Provenanced Fresh (Just OpenF1) Nothing namelessTableFixture))
        `shouldBe` (Header "fresh", MissingHeader, Header "openf1")

    it "el dato guardado lleva la procedencia, el instante y la fuente que tenía" $
      -- La fuente sale de la caja de la cache, no se adivina: lo guardado conserva
      -- de dónde salió, o el tooltip afirmaría una fuente que no es.
      headersOf
        (withProvenance (Provenanced Cached (Just OpenF1) (Just fetchInstant) liveTableFixture))
        `shouldBe` (Header "cached", Header "2026-09-11T14:03:22Z", Header "openf1")

    it "el reciente viaja como lo guardado, pero con su propio sello" $
      -- Lo que el cuarto sello cambia en el cable es solo la primera cabecera: el
      -- instante y la fuente son los de lo guardado, porque es lo guardado.
      headersOf
        (withProvenance (Provenanced Recent (Just OpenF1) (Just fetchInstant) liveTableFixture))
        `shouldBe` (Header "recent", Header "2026-09-11T14:03:22Z", Header "openf1")

    it "el dato de ejemplo no lleva instante ni fuente, porque no tuvo ninguno" $
      headersOf (withProvenance (Provenanced Sample Nothing Nothing namelessTableFixture))
        `shouldBe` (Header "sample", MissingHeader, MissingHeader)

    it "el cuerpo es la tabla entera, sesión incluida y sin tocar" $
      -- El envoltorio viaja en el CUERPO y no en cabeceras (2026-09-13 (d)), así
      -- que `withProvenance` no puede tocarlo: lo que entra sale.
      getResponse
        (withProvenance (Provenanced Cached (Just Feed) (Just fetchInstant) liveTableFixture))
        `shouldBe` liveTableFixture

    it "el instante sale en UTC y sin fracción de segundo" $
      fetchedAtText fetchInstant `shouldBe` "2026-09-11T14:03:22Z"

  -- Lo que puede salir mal en un reloj que pide solo —dos peticiones a la vez, una
  -- tabla que se borra por un fallo puntual— vive aquí y no en 'Widgets.LiveTiming',
  -- que es ciego.
  describe "Common.Shown (refresco)" $ do
    it "arranca sin nada en vuelo, nada que enseñar y ningún fallo" $
      (pollIdle :: Poll Int) `shouldBe` Poll False Nothing False

    it "arranca pudiendo pedir" $
      canRequest (pollIdle :: Poll Int) `shouldBe` True

    it "con una petición en vuelo, el tic no puede lanzar otra" $
      canRequest (pollStep Sent (pollIdle :: Poll Int)) `shouldBe` False

    it "pedir no toca lo enseñado ni el fallo" $
      pollStep Sent (Poll False (Just (1 :: Int)) True)
        `shouldBe` Poll True (Just 1) True

    it "una respuesta buena sustituye lo enseñado y libera el reloj" $
      pollStep (Arrived (Just (2 :: Int))) (Poll True (Just 1) False)
        `shouldBe` Poll False (Just 2) False

    it "un fallo conserva lo enseñado, lo marca y libera el reloj" $
      pollStep (Arrived Nothing) (Poll True (Just (1 :: Int)) False)
        `shouldBe` Poll False (Just 1) True

    it "un fallo sin nada enseñado queda vacío con fallo, que es el «Error al cargar»" $
      pollStep (Arrived Nothing) (Poll True (Nothing :: Maybe Int) False)
        `shouldBe` Poll False Nothing True

    it "una respuesta buena tras un fallo limpia el fallo" $
      pollStep (Arrived (Just (3 :: Int))) (Poll True (Just 1) True)
        `shouldBe` Poll False (Just 3) False

  -- El retraso contra el spoiler: qué se enseña con N segundos de retraso, qué se
  -- guarda, y cómo se lee lo tecleado. Los segundos cuentan desde que se abrió la
  -- página.
  describe "Common.Shown (retraso)" $ do
    let arrivals = [(20, 'c'), (10, 'b'), (0, 'a')] :: Arrivals Char
    it "lee segundos a secas y m:ss" $ do
      map readDelay ["41", "0:41", "0", "45:00", "2700", "1:05"]
        `shouldBe` map Just [41, 41, 0, 2700, 2700, 65]

    it "lo que no tiene la forma, o pasa de 45 min, no vale" $
      map readDelay ["", "abc", "-5", "1:5", "0:75", "45:01", "2701", " 41", "1:2:03", "99999999999999999999"]
        `shouldBe` replicate 10 Nothing

    it "enseña lo más nuevo que tenga al menos N segundos" $ do
      delayedShown 15 30 arrivals `shouldBe` Just 'b'
      delayedShown 10 30 arrivals `shouldBe` Just 'c'
      delayedShown 31 30 arrivals `shouldBe` Nothing

    it "la edad de lo enseñado: lo retrasado, o lo más nuevo si espera o no hay retraso" $ do
      shownAge 15 30 arrivals `shouldBe` Just 20
      shownAge 10 30 arrivals `shouldBe` Just 10
      shownAge 31 30 arrivals `shouldBe` Just 10
      shownAge 0 30 arrivals `shouldBe` Just 10
      shownAge 41 5 ([] :: Arrivals Char) `shouldBe` Nothing

    it "la edad es la de lo que se enseña, retraso a retraso" $
      [shownAge n 30 arrivals >>= \age -> lookup (30 - age) arrivals | n <- [1 .. 40]]
        `shouldBe` [Just (fromMaybe 'c' (delayedShown n 30 arrivals)) | n <- [1 .. 40]]

    it "sin retraso, el refresco tal cual" $
      delayedPoll succ 0 30 arrivals (Poll False (Just 'c') False)
        `shouldBe` Poll False (Just 'c') False

    it "con retraso, lo enseñado se retrasa y el fallo se ve al momento" $
      delayedPoll succ 15 30 arrivals (Poll True (Just 'c') True)
        `shouldBe` Poll True (Just 'b') True

    it "mientras espera, enseña lo último que llegó pasado por lo que se puede ver" $ do
      delayedPoll succ 41 30 arrivals (Poll False (Just 'c') False)
        `shouldBe` Poll False (Just 'd') False
      delayedPoll succ 41 5 [] (Poll True (Nothing :: Maybe Char) False)
        `shouldBe` Poll True Nothing False

    it "una llegada es un refresco que volvió bien; el envío y el fallo no lo son" $ do
      landed (Poll False (Just 'c') False) `shouldBe` Just 'c'
      landed (Poll True (Just 'c') False) `shouldBe` Nothing
      landed (Poll False (Just 'c') True) `shouldBe` Nothing
      landed (Poll False Nothing False :: Poll Char) `shouldBe` Nothing

    it "la dirección da el retraso en segundos o en m:ss, con los dos puntos escapados o no" $
      map delayFromUrl
        [ "http://localhost:3000/?retraso=0:41"
        , "http://localhost:3000/?retraso=38"
        , "http://localhost:3000/?retraso=0%3A41"
        , "http://localhost:3000/?x=1&retraso=45:00#arriba"
        ]
        `shouldBe` map Just [41, 38, 41, 2700]

    it "sin retraso en la dirección, o con uno que no vale, nada" $
      map delayFromUrl
        [ "http://localhost:3000/"
        , "http://localhost:3000/?retraso"
        , "http://localhost:3000/?retraso=1:5"
        , "http://localhost:3000/?otro=41"
        ]
        `shouldBe` replicate 4 Nothing

    it "la espera cuenta desde lo más viejo que llegó, o desde ahora si no llegó nada" $ do
      delayWait 41 30 arrivals `shouldBe` Just 11
      delayWait 41 5 ([] :: Arrivals Char) `shouldBe` Just 41
      delayWait 15 30 arrivals `shouldBe` Nothing
      delayWait 0 0 ([] :: Arrivals Char) `shouldBe` Nothing

    it "al guardar se poda lo que ningún retraso aceptado puede enseñar" $
      map fst (recordArrival 2800 'e' [(2750, 'd'), (90, 'c'), (80, 'b'), (0, 'a')])
        `shouldBe` [2800, 2750, 90]

    it "los textos de la espera y del tooltip" $ do
      delayWaitLabel 41 32 `shouldBe` "En espera · diferido 0:41 · empieza en 32 s"
      delayNote 41 "feed · En vivo" `shouldBe` "feed · En vivo · diferido 0:41"
      delayNote 0 "feed · En vivo" `shouldBe` "feed · En vivo"

    it "el retraso por defecto y el tope se leen como se escriben" $
      (readDelay "0:41", readDelay "45:00") `shouldBe` (Just delayDefaultSeconds, Just delayMaxSeconds)

    prop "sin retraso se enseña lo último que llegó" delayZeroShowsNewest

  -- La vuelta y el reloj de la banda, y lo que se calla mientras se espera.
  describe "lapLabel, showsClock, clockLabel y tickClock" $ do
    it "la vuelta" $
      lapLabel (LapProgress 23 57) `shouldBe` "Vuelta 23/57"

    it "ni la carrera ni la Sprint enseñan reloj; libres y clasificación, sí" $ do
      showsClock raceSessionFixture `shouldBe` False
      showsClock ((namedSession "Race" "Sprint" "Chinese Grand Prix") {siLaps = Nothing})
        `shouldBe` False
      showsClock ((namedSession "Qualifying" "Qualifying" "Azerbaijan Grand Prix") {siLaps = Nothing})
        `shouldBe` True
      showsClock ((namedSession "Practice" "Practice 3" "Azerbaijan Grand Prix") {siLaps = Nothing})
        `shouldBe` True

    it "una sesión que publica vueltas no enseña reloj, se llame como se llame" $
      showsClock (namedSession "Sprint" "Sprint" "Chinese Grand Prix") `shouldBe` False

    it "el reloj, compacto y con horas solo a partir de una" $ do
      clockLabel (SessionClock 754 True) `shouldBe` "Quedan 12:34"
      clockLabel (SessionClock 3600 True) `shouldBe` "Quedan 1:00:00"

    it "el reloj baja solo si corre, y no baja de cero" $ do
      tickClock (SessionClock 60 True) `shouldBe` SessionClock 59 True
      tickClock (SessionClock 60 False) `shouldBe` SessionClock 60 False
      tickClock (SessionClock 0 True) `shouldBe` SessionClock 0 True

    it "mientras espera, la sesión se nombra pero no dice estado, vuelta, reloj ni parte" $
      waitingSession raceSessionFixture {siPart = Just 2}
        `shouldBe` raceSessionFixture {siState = Nothing, siLaps = Nothing, siClock = Nothing}

    it "la banda calla el reloj donde showsClock lo calla" $ do
      shownClock raceSessionFixture `shouldBe` Nothing
      shownClock ((namedSession "Qualifying" "Qualifying" "Azerbaijan Grand Prix") {siLaps = Nothing})
        `shouldBe` Just (SessionClock 5400 True)

    it "mientras la sesión rueda, la derecha dice la vuelta o, sin ella, el reloj" $ do
      bandRight 0 NextSilent (Just (LapProgress 23 57)) Nothing `shouldBe` "Vuelta 23/57"
      bandRight 0 NextSilent Nothing (Just (SessionClock 754 True)) `shouldBe` "Quedan 12:34"
      bandRight 0 NextSilent Nothing Nothing `shouldBe` ""

    it "si no rueda, la derecha dice la próxima sesión aunque haya vuelta" $
      bandRight 0 (NextStartsIn (12 * 60)) (Just (LapProgress 57 57)) Nothing
        `shouldBe` "empieza en 12 min"

    it "mientras espera, la tabla no tiene filas pero sí dice qué viene después" $
      waitingTable liveTableFixture {liveNext = NextStartsIn 60}
        `shouldBe` LiveTable (Just (waitingSession raceSessionFixture)) [] (NextStartsIn 60)

  -- Una respuesta 200 que no nombra su sesión no es un fallo, así que 'pollStep' no
  -- la conserva: la tabla llega entera y lo que falta es un campo de dentro. Lo que
  -- aquí se prueba es qué queda en pantalla cuando eso pasa, y que se pueda cablear
  -- a un refresco que cambia dos veces por ciclo sin filtrar antes.
  describe "Common.Shown (lo conservado)" $ do
    it "antes de la primera llegada buena no hay nada que enseñar ni que marcar" $
      (keptNothing :: Kept Int) `shouldBe` Kept Nothing False

    it "una llegada con dato sustituye y deja de marcar" $
      keepLast (Just (2 :: Int)) (Kept (Just 1) True) `shouldBe` Kept (Just 2) False

    it "una llegada sin dato conserva lo anterior y lo marca" $
      keepLast Nothing (Kept (Just (1 :: Int)) False) `shouldBe` Kept (Just 1) True

    it "una llegada sin dato sobre un vacío no marca el vacío" $
      keepLast Nothing (keptNothing :: Kept Int) `shouldBe` Kept Nothing False

    it "dos llegadas vacías seguidas conservan la última buena, no la penúltima" $
      let good = keepLast (Just (7 :: Int)) (Kept (Just 1) False)
       in keepLast Nothing (keepLast Nothing good) `shouldBe` Kept (Just 7) True

    it "repetir la misma llegada con dato no cambia lo conservado" $
      let once = keepLast (Just (5 :: Int)) keptNothing
       in keepLast (Just 5) once `shouldBe` once

    it "repetir una llegada sin dato no cambia lo conservado" $
      let once = keepLast Nothing (Kept (Just (5 :: Int)) False)
       in keepLast Nothing once `shouldBe` once

    -- El título y el estado de la banda salen del MISMO campo, así que conservar la
    -- sesión entera cuesta lo mismo que conservar solo el nombre y arregla las dos
    -- mitades a la vez. Este caso es lo que lo afirma.
    it "lo conservado arrastra el estado que va dentro de la sesión" $
      let shown = keepLast (Just (stateOf SessionFinalised)) keptNothing
          gap   = keepLast Nothing shown
       in (siState =<< keptValue gap, keptStale gap)
            `shouldBe` (Just (StateReading SessionFinalised Heard), True)

  describe "sourcedFrom" $ do
    it "lee la procedencia y el instante de sus cabeceras, recortando" $
      sourcedFrom
        (`lookup` [("X-Data-Origin", "cached"), ("X-Data-Fetched-At", " 2026-09-11T14:03:22Z ")])
        ()
        `shouldBe` Sourced (Just Cached) Nothing (Just "2026-09-11T14:03:22Z") ()

    it "lee también la fuente, que es la tercera cabecera" $
      sourcedFrom
        (`lookup` [("X-Data-Origin", "fresh"), ("X-Data-Source", " FEED ")])
        ()
        `shouldBe` Sourced (Just Fresh) (Just Feed) Nothing ()

    it "sin cabeceras no adivina: procedencia, fuente e instante en Nothing" $
      sourcedFrom (`lookup` []) () `shouldBe` Sourced Nothing Nothing Nothing ()

    it "una procedencia irreconocible es Nothing, y el valor llega igual" $
      sourcedFrom (`lookup` [("X-Data-Origin", "live")]) 'x'
        `shouldBe` Sourced Nothing Nothing Nothing 'x'

    -- El dato de ejemplo no sale de ninguna fuente, así que su respuesta no lleva
    -- la cabecera: ausente y desconocida se leen igual, y es lo correcto.
    it "un dato con procedencia pero sin fuente es un caso normal, no un fallo" $
      sourcedFrom (`lookup` [("X-Data-Origin", "sample")]) ()
        `shouldBe` Sourced (Just Sample) Nothing Nothing ()

    -- Pedir y leer son dos sitios: un cliente XHR solo recibe las cabeceras que
    -- declaró, y una que se lea sin pedirse llega SIEMPRE ausente — que aquí
    -- significa duda y no error, así que nadie se entera. `sourcedHeaders` existe
    -- para que sea una sola lista, y este caso es lo que lo comprueba: alimenta a
    -- `sourcedFrom` con lo que esa lista nombra y NADA más, de modo que un campo
    -- cuya cabecera quedara fuera sale `Nothing` y esto se pone rojo.
    --
    -- Es la red que el paquete `frontend` no puede tener, porque no tiene suite.
    it "pidiendo solo sourcedHeaders, sourcedFrom puebla sus tres campos" $
      let served = [ (originHeader,    "cached")
                   , (sourceHeader,    "feed")
                   , (fetchedAtHeader, "2026-09-11T14:03:22Z")
                   ]
          onlyRequested n =
            if n `elem` sourcedHeaders then lookup n served else Nothing
       in sourcedFrom onlyRequested ()
            `shouldBe` Sourced (Just Cached) (Just Feed) (Just "2026-09-11T14:03:22Z") ()

  -- El indicador cruza las dos preguntas que 'Common.Origin' y el refresco
  -- responden por separado —de dónde salió lo que se ve, y si lo último que se
  -- pidió volvió—, y es el único sitio donde se cruzan. Lo que aquí se prueba es
  -- el reparto: el color dice la procedencia y el parpadeo dice «ahora mismo»,
  -- así que un fallo NO puede cambiar el color, y «en vivo» SÍ tiene que dejar
  -- de decirse.
  describe "Common.Shown (indicador)" $ do
    it "recoge la procedencia, la fuente, el instante y el fallo de lo que se está enseñando" $
      indicatorFrom True True
        (Poll False (Just (Sourced (Just Cached) (Just OpenF1) (Just fetchedAtIso) [1 :: Int])) True)
        `shouldBe` Indicator True (Just Cached) (Just OpenF1) (Just fetchedAtIso) True True True

    it "antes de la primera respuesta no hay nada que enseñar ni procedencia" $
      indicatorFrom False False (pollIdle :: Poll (Sourced [Int]))
        `shouldBe` Indicator False Nothing Nothing Nothing False False False

    it "la sesión rodando entra por argumento y no sale del refresco" $
      -- El mismo `Poll` con las dos respuestas: nada de lo que el refresco trae lo
      -- decide, que es lo que permite que `Common.Shown` no conozca el dominio.
      map (\r -> indicatorFrom r False (pollIdle :: Poll (Sourced [Int]))) [True, False]
        `shouldBe` [ Indicator False Nothing Nothing Nothing False True False
                   , Indicator False Nothing Nothing Nothing False False False
                   ]

    it "con la sesión rodando, los seis estados del punto con su modificador" $
      map indicatorClass
        [ shownAs (Just Fresh)  Nothing             False
        , shownAs (Just Fresh)  Nothing             True
        , shownAs (Just Recent) (Just fetchedAtIso) False
        , shownAs (Just Cached) (Just fetchedAtIso) False
        , shownAs (Just Sample) Nothing             False
        , shownAs Nothing       Nothing             False
        ]
        `shouldBe` [ "widget__badge widget__badge--live"
                   , "widget__badge widget__badge--stalled"
                   , "widget__badge widget__badge--recent"
                   , "widget__badge widget__badge--saved"
                   , "widget__badge widget__badge--sample"
                   , "widget__badge widget__badge--unknown"
                   ]

    -- El séptimo modificador, y el motivo de que sea uno y no dos: fuera de sesión
    -- el backend se frena, así que la respuesta llega `fresh` y `recent` un ciclo sí
    -- y otro no. Si cada sello conservara su punto, el punto latiría cada diez
    -- segundos, que es el movimiento que este modificador existe para quitar.
    it "sin sesión, los dos sellos de refresco bueno caen en el mismo punto apagado" $
      map (indicatorClass . offAir)
        [ shownAs (Just Fresh)  Nothing             False
        , shownAs (Just Recent) (Just fetchedAtIso) False
        ]
        `shouldBe` [ "widget__badge widget__badge--idle"
                   , "widget__badge widget__badge--idle"
                   ]

    -- La otra mitad de la decisión, y la que impide que apagar tape un fallo: sin
    -- sesión, lo que salió mal se sigue pintando como lo que salió mal.
    it "sin sesión, los puntos que avisan de un fallo no se apagan" $
      map (indicatorClass . offAir)
        [ shownAs (Just Fresh)  Nothing             True
        , shownAs (Just Recent) (Just fetchedAtIso) True
        , shownAs (Just Cached) (Just fetchedAtIso) False
        , shownAs (Just Sample) Nothing             False
        , shownAs Nothing       Nothing             False
        ]
        `shouldBe` [ "widget__badge widget__badge--stalled"
                   , "widget__badge widget__badge--stalled"
                   , "widget__badge widget__badge--saved"
                   , "widget__badge widget__badge--sample"
                   , "widget__badge widget__badge--unknown"
                   ]

    -- Seis modificadores para cuatro procedencias, porque no hay biyección: un dato
    -- reciente cuyo refresco no volvió se lee igual que uno fresco en la misma
    -- situación, así que los dos caen en `--stalled`. Es lo que impide que el punto
    -- siga afirmando que la página se está actualizando cuando ya no lo hace.
    it "un refresco fallido lleva al mismo punto venga de fresco o de reciente" $
      map indicatorClass
        [ shownAs (Just Fresh)  Nothing             True
        , shownAs (Just Recent) (Just fetchedAtIso) True
        ]
        `shouldBe` [ "widget__badge widget__badge--stalled"
                   , "widget__badge widget__badge--stalled"
                   ]

    -- La mitad del reparto que no se ve mirando: la clase `--live` es de UN estado
    -- de todos los que `everyIndicator` enumera. Escrito así, un estado nuevo que se
    -- colara en ella rompe el caso sin que nadie tenga que acordarse. Y es la única
    -- que se mueve: el parpadeo afirma que hay sesión rodando y que el refresco está
    -- volviendo, o sea las dos cosas a la vez.
    it "solo el dato fresco, con el refresco volviendo y la sesión rodando, lleva la clase del directo" $
      filter ((== "widget__badge widget__badge--live") . indicatorClass) everyIndicator
        `shouldBe` [shownAs (Just Fresh) Nothing False]

    -- El mismo barrido para el apagado, que es lo que impide que se lo coma un
    -- estado más: son exactamente dos y los dos son sin sesión.
    it "solo los dos sellos de refresco bueno sin sesión llevan la clase del apagado" $
      filter ((== "widget__badge widget__badge--idle") . indicatorClass) everyIndicator
        `shouldBe` [ offAir (shownAs (Just Fresh)  Nothing             False)
                   , offAir (shownAs (Just Recent) (Just fetchedAtIso) False)
                   ]

    it "un refresco fallido no cambia el punto del dato guardado ni el del de ejemplo" $
      map indicatorClass
        [ shownAs (Just Cached) (Just fetchedAtIso) True
        , shownAs (Just Sample) Nothing             True
        ]
        `shouldBe` [ "widget__badge widget__badge--saved"
                   , "widget__badge widget__badge--sample"
                   ]

    it "el dato fresco dice que está en vivo, y con el periodo real del refresco" $
      indicatorTooltip (shownAs (Just Fresh) Nothing False)
        `shouldBe` ("En vivo: se actualiza cada " <> T.pack (show liveRefreshSeconds) <> " s")

    -- No se compone: «en vivo» dejó de ser cierto en cuanto el refresco falló,
    -- así que decirlo además del fallo sería decir las dos cosas a la vez.
    it "el dato fresco que no se pudo recargar sustituye su aviso, no lo acumula" $
      indicatorTooltip (shownAs (Just Fresh) Nothing True)
        `shouldBe` "No se pudo recargar: se muestra la tabla anterior"

    -- Fuera de sesión «en vivo» es falso y el periodo no: la página pregunta igual,
    -- y quien se frena por detrás es el backend. Por eso lo que cambia es la cabeza
    -- de la frase y no el número, que sigue saliendo de `liveRefreshSeconds`.
    it "sin sesión, el dato fresco dice que no hay sesión y conserva el periodo" $
      indicatorTooltip (offAir (shownAs (Just Fresh) Nothing False))
        `shouldBe` ("Sin sesión en marcha: se actualiza cada "
                      <> T.pack (show liveRefreshSeconds) <> " s")

    -- El punto es el mismo que el del fresco sin sesión y el aviso NO: el punto se
    -- ve sin querer y tiene que estar quieto; el aviso solo sale al apuntarlo, y ahí
    -- decir de cuándo es el dato vale más que repetir que no hay carrera.
    it "sin sesión, el reciente comparte punto con el fresco pero conserva su aviso" $
      ( indicatorClass (offAir (shownAs (Just Recent) (Just fetchedAtIso) False))
      , indicatorTooltip (offAir (shownAs (Just Recent) (Just fetchedAtIso) False))
      )
        `shouldBe` ( "widget__badge widget__badge--idle"
                   , "Dato reciente: no se ha vuelto a preguntar (14:03 UTC)"
                   )

    it "el dato guardado lleva la hora ya legible, y no el instante tal cual viaja" $
      indicatorTooltip (shownAs (Just Cached) (Just fetchedAtIso) False)
        `shouldBe` "Dato guardado: la fuente no responde ahora mismo (14:03 UTC)"

    it "el reciente lleva su hora y NO acusa a la fuente de no responder" $
      -- El motivo entero de que el cuarto sello exista: cuando el backend se frena a
      -- sí mismo, el aviso del guardado sería falso la mayor parte del tiempo.
      indicatorTooltip (shownAs (Just Recent) (Just fetchedAtIso) False)
        `shouldBe` "Dato reciente: no se ha vuelto a preguntar (14:03 UTC)"

    it "reciente y fallo también son dos hechos, y se componen igual" $
      -- Compone por el mismo camino que el guardado: `indicatorTooltip` no nombra a
      -- ninguno de los dos, los deja caer en su rama común.
      indicatorTooltip (shownAs (Just Recent) (Just fetchedAtIso) True)
        `shouldBe` "Dato reciente: no se ha vuelto a preguntar (14:03 UTC). \
                   \No se pudo recargar: se muestra la tabla anterior"

    it "guardado y fallo son dos hechos, y el tooltip los dice los dos" $
      indicatorTooltip (shownAs (Just Cached) (Just fetchedAtIso) True)
        `shouldBe` "Dato guardado: la fuente no responde ahora mismo (14:03 UTC). \
                   \No se pudo recargar: se muestra la tabla anterior"

    -- La otra punta del 59: el feed ya dio la sesión por finalizada y lo guardado es
    -- su última tabla. El feed sí responde; quien todavía no publica es OpenF1.
    it "lo guardado del feed con la sesión finalizada lo dice, y no acusa a la fuente" $
      indicatorTooltip (finalisedFeed False)
        `shouldBe` "Feed oficial · Sesión finalizada: la última tabla del feed (14:03 UTC). \
                   \OpenF1 todavía no publica"

    it "finalizada pero de OpenF1, o del feed sin finalizar, sigue con el aviso de siempre" $
      -- Se siembra también el caso que sí cambia, para que la aserción no pase con la
      -- rama nueva sin escribir.
      map indicatorTooltip
          [ (shownFrom OpenF1 (Just Cached) (Just fetchedAtIso) False) {indFinalised = True}
          , shownFrom Feed (Just Cached) (Just fetchedAtIso) False
          , finalisedFeed False
          ]
        `shouldBe`
          [ "OpenF1 · Dato guardado: la fuente no responde ahora mismo (14:03 UTC)"
          , "Feed oficial · Dato guardado: la fuente no responde ahora mismo (14:03 UTC)"
          , "Feed oficial · Sesión finalizada: la última tabla del feed (14:03 UTC). \
            \OpenF1 todavía no publica"
          ]

    it "con el refresco caído son dos hechos, y se componen como los demás" $
      indicatorTooltip (finalisedFeed True)
        `shouldBe` "Feed oficial · Sesión finalizada: la última tabla del feed (14:03 UTC). \
                   \OpenF1 todavía no publica. No se pudo recargar: se muestra la tabla anterior"

    it "el punto no cambia: sigue siendo el de lo guardado" $
      map (indicatorClass . finalisedFeed) [False, True]
        `shouldBe` replicate 2 "widget__badge widget__badge--saved"

    it "el dato de ejemplo avisa de que lo es, falle o no el refresco" $
      map (indicatorTooltip . shownAs (Just Sample) Nothing) [False, True]
        `shouldBe` [ "Datos de ejemplo: la fuente nunca ha respondido"
                   , "Datos de ejemplo: la fuente nunca ha respondido. \
                     \No se pudo recargar: se muestra la tabla anterior"
                   ]

    it "sin procedencia reconocible lo dice, y compone igual con el fallo" $
      map (indicatorTooltip . shownAs Nothing Nothing) [False, True]
        `shouldBe` [ "Procedencia desconocida"
                   , "Procedencia desconocida. No se pudo recargar: se muestra la tabla anterior"
                   ]

    -- El caso del fallo en la PRIMERA carga, que es el que obliga a que el
    -- indicador sepa si hay tabla: el cuerpo de la tarjeta ya pinta su «Error al
    -- cargar», y prometer «se muestra la tabla anterior» sin tabla es mentir.
    it "sin nada en pantalla, el fallo no promete una tabla anterior" $
      indicatorTooltip ((shownAs Nothing Nothing True) {indShown = False})
        `shouldBe` "Procedencia desconocida"

    it "un instante ilegible deja el tooltip sin hora, pero sigue avisando" $
      indicatorTooltip (shownAs (Just Cached) (Just "ayer por la tarde") False)
        `shouldBe` "Dato guardado: la fuente no responde ahora mismo"

    -- La fuente es el segundo eje y el punto ya pinta el primero: si el color
    -- cambiara con ella, dos señales distintas compartirían pintura.
    it "la fuente no cambia el punto: el color sigue siendo el del peldaño" $
      map indicatorClass
        [ shownFrom Feed   (Just Fresh)  Nothing             False
        , shownFrom OpenF1 (Just Fresh)  Nothing             False
        , shownFrom OpenF1 (Just Cached) (Just fetchedAtIso) False
        ]
        `shouldBe` [ "widget__badge widget__badge--live"
                   , "widget__badge widget__badge--live"
                   , "widget__badge widget__badge--saved"
                   ]

    it "la fuente va delante y con su nombre legible, no con el valor de la cabecera" $
      map (\s -> indicatorTooltip (shownFrom s (Just Fresh) Nothing False)) [Feed, OpenF1]
        `shouldBe` [ "Feed oficial · En vivo: se actualiza cada "
                       <> T.pack (show liveRefreshSeconds) <> " s"
                   , "OpenF1 · En vivo: se actualiza cada "
                       <> T.pack (show liveRefreshSeconds) <> " s"
                   ]

    -- El caso largo, que es el que la fuente podía empeorar: dos frases compuestas
    -- más la etiqueta. Por eso la fuente va delante y separada por «·».
    it "guardado, fallo y fuente caben los tres, y la fuente no encadena otra frase" $
      indicatorTooltip (shownFrom OpenF1 (Just Cached) (Just fetchedAtIso) True)
        `shouldBe` "OpenF1 · Dato guardado: la fuente no responde ahora mismo (14:03 UTC). \
                   \No se pudo recargar: se muestra la tabla anterior"

    it "el dato fresco que no se pudo recargar conserva su fuente" $
      indicatorTooltip (shownFrom Feed (Just Fresh) Nothing True)
        `shouldBe` "Feed oficial · No se pudo recargar: se muestra la tabla anterior"

    -- El respaldo estático nunca salió de una fuente, así que su respuesta no trae
    -- la cabecera y su tooltip no gana etiqueta: es la razón de que el campo sea
    -- 'Maybe' y no un tercer valor de 'Source'.
    it "el dato de ejemplo no lleva fuente, porque no la tuvo" $
      indicatorTooltip (shownAs (Just Sample) Nothing False)
        `shouldBe` "Datos de ejemplo: la fuente nunca ha respondido"

    it "una fuente conocida con la procedencia desconocida sigue diciéndose" $
      indicatorTooltip (shownFrom Feed Nothing Nothing False)
        `shouldBe` "Feed oficial · Procedencia desconocida"

  describe "fetchedAtLabel" $ do
    it "saca la hora y el minuto del instante que emite el backend" $
      fetchedAtLabel fetchedAtIso `shouldBe` Just "14:03 UTC"

    it "la fracción de segundo no le estorba, y los espacios tampoco" $
      map fetchedAtLabel ["2026-09-11T14:03:22.512Z", "  2026-09-11T14:03:22Z  "]
        `shouldBe` [Just "14:03 UTC", Just "14:03 UTC"]

    -- La medianoche es el caso que un recorte mal hecho convierte en `Nothing`
    -- una vez al día y solo una vez al día.
    it "la medianoche es una hora como las demás" $
      fetchedAtLabel "2026-09-11T00:00:00Z" `shouldBe` Just "00:00 UTC"

    it "lo que no tiene esa forma no se adivina" $
      map fetchedAtLabel ["", "   ", "2026-09-11", "ayer", "2026-09-11T4:03:22Z"]
        `shouldBe` [Nothing, Nothing, Nothing, Nothing, Nothing]

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
-- cae dentro del lienzo, con cualquiera de los dos escalados. Cubre de golpe las dos divisiones por cero y los
-- desbordamientos de escala que ningún caso concreto va a adivinar.
--
-- El 'Arbitrary' de 'Double' de QuickCheck no genera @NaN@\/@Infinity@ (mismo
-- supuesto que 'roundTripsDouble'), así que la serie generada es siempre finita —
-- que es también lo que garantiza el @_num@ del microservicio.
staysInsideViewBox :: ([Double] -> [(Double, Double)]) -> [Double] -> Bool
staysInsideViewBox points xs = all inside (points xs)
  where
    inside (x, y) =
      x >= 0 && x <= chartWidth && y >= chartPad && y <= chartHeight - chartPad

-- | El tope de marcas se cumple en cualquier serie, y el cero, que es «iban
-- empatados», no falta nunca mientras haya datos.
-- | Con retraso cero, lo enseñado es lo último que llegó, sea cual sea el ritmo de
-- las llegadas (varias en el mismo segundo incluidas).
delayZeroShowsNewest :: [(NonNegative Int, Char)] -> Property
delayZeroShowsNewest steps = delayedShown 0 now xs === newest
  where
    times  = scanl1 (+) (map (getNonNegative . fst) steps)
    xs     = reverse (zip times (map snd steps))
    now    = if null times then 0 else last times
    newest = case xs of
      (_, x) : _ -> Just x
      []         -> Nothing

fewTicksWithZero :: [Double] -> Property
fewTicksWithZero xs =
  (length ticks <= 8) .&&. (null xs || 0 `elem` [v | (v, _, _) <- ticks])
  where
    ticks = axisTicks xs

-- | Alargar solo puede ensanchar: la curva escalada con el rango del eje nunca se
-- sale de él.
axisRangeContainsDelta :: [Double] -> Bool
axisRangeContainsDelta xs = alo <= dlo && ahi >= dhi
  where
    (alo, ahi) = axisRange xs
    (dlo, dhi) = deltaRange xs

-- | Pintar la fila solo añade su alto al contenido, así que el veredicto no cambia
-- con ella, tenga una línea, dos o ninguna: es lo que impide que «Eje y valores» se
-- apague y se encienda sola.
--
-- En px enteros, para que sumar y restar el alto de la fila sea exacto.
measuredFitAgrees :: NonNegative Int -> NonNegative Int -> Bool
measuredFitAgrees (NonNegative c) (NonNegative x) =
  all (== valuesFitMeasured client content 0)
    [ valuesFitMeasured client (content + row) row
    | row <- [singleRowHeight, valuesRowHeight] ]
  where
    client  = fromIntegral (5 * c)
    content = fromIntegral (5 * x)

-- | Con la tarjeta en dos columnas no sobra ni falta ancho.
-- Los anchos generados se multiplican por 10 para cubrir tarjetas reales (0–1000
-- px): el 'Arbitrary' de 'Double' se queda cerca de 100.
twoColumnsAddUp :: NonNegative Double -> Bool
twoColumnsAddUp (NonNegative x) =
  clStacked l || abs (clControl l + columnGap + clChart l - inner) < 1e-9
  where
    inner = 10 * x
    l     = cardLayout inner

controlWithinBounds :: NonNegative Double -> Bool
controlWithinBounds (NonNegative x) =
  w >= carSelectWidth && w <= controlMaxWidth
  where
    w = controlWidth (10 * x)

-- | Comprobado por muestreo y no con la cuenta del módulo: 200 puntos por tramo de
-- la curva, ninguno dentro de la caja de un número.
insideLabelsClear :: Bool -> NonNegative Double -> [Double] -> Bool
insideLabelsClear right (NonNegative x) xs = all ok (insideAxisLabels side width xs)
  where
    side  = if right then SideRight else SideLeft
    width = 60 + 10 * x
    curve = [ (curveInset + px / chartWidth * (width - 2 * curveInset), py)
            | (px, py) <- axisPoints xs ]
    samples =
      curve
        ++ [ (x1 + t * (x2 - x1), y1 + t * (y2 - y1))
           | ((x1, y1), (x2, y2)) <- zip curve (drop 1 curve)
           , k <- [0 .. 200 :: Int]
           , let t = fromIntegral k / 200
           ]
    ok (a, y, _) =
      a >= lowest - 1e-9 && a + valueWidth <= highest + 1e-9
        && not (any (inside a y) samples)
    (lowest, highest) = if right then (width / 4, width) else (0, width * 3 / 4)
    inside a y (sx, sy) =
      sx > a + 1e-6 && sx < a + valueWidth - 1e-6 && abs (sy - y) < valueHeight / 2

-- | Lo que hace que apilar y meter el eje sean umbrales y no intervalos sueltos.
valuesFitMonotone :: NonNegative Double -> NonNegative Double -> Bool
valuesFitMonotone (NonNegative x) (NonNegative d) =
  valuesFit (10 * x) <= valuesFit (10 * x + d)

-- | Lo que hace del «VS» al lado un umbral: al ensanchar la tabla no vuelve a bajar.
vsBesideMonotone :: NonNegative Double -> NonNegative Double -> Bool
vsBesideMonotone (NonNegative x) (NonNegative d) =
  vsBeside (10 * x) <= vsBeside (10 * x + d)

-- | Lo que hace legible el eje: cada marca más abajo que la anterior, todas dentro
-- del lienzo (con la holgura de 'axisTicks' en los extremos) y ninguna etiqueta
-- repetida, que es lo que el paso mínimo de @0.001@ garantiza con tres decimales.
ticksReadable :: [Double] -> Bool
ticksReadable xs =
  and (zipWith (<) ys (drop 1 ys))
    && all inside ys
    && length (nub labels) == length labels
  where
    ticks  = axisTicks xs
    ys     = [y | (_, y, _) <- ticks]
    labels = [label | (_, _, label) <- ticks]
    inside y = y >= chartPad - 1e-6 && y <= chartHeight - chartPad + 1e-6

-- | Con la ventana del feed abierta el veredicto no depende de nada más: ni de
-- cuándo preguntó el último lector, ni de si preguntó alguna vez.
--
-- Es el invariante que protege el presupuesto durante una carrera, que es cuando
-- OpenF1 contesta @401@ y cada bajada sería gasto en balde. Los casos de ejemplo
-- fijan dos instantes; esto recorre los pares que a nadie se le ocurriría escribir,
-- incluidos los que ponen al lector en el futuro.
-- | Con una sola sesión cuya ventana ya abrió, la ventana está abierta si y solo si
-- no se vio finalización o se vio antes de la hora de arranque. Los desplazamientos
-- son segundos: desde la apertura para el instante, desde la hora para la señal.
closesOnlyFromStart :: NonNegative Int -> Maybe Int -> Property
closesOnlyFromStart (NonNegative sinceOpening) finalisedOffset =
  feedWindowOpen now [malasiaP1] finalisedAt === maybe True (< 0) finalisedOffset
  where
    now         = addUTCTime (fromIntegral sinceOpening) opening
    opening     = addUTCTime (negate feedWindowLead) malasiaP1
    finalisedAt = (\s -> addUTCTime (fromIntegral s) malasiaP1) <$> finalisedOffset

neverAsksInsideFeedWindow :: Int -> Maybe Int -> Bool
neverAsksInsideFeedWindow nowOffset askedOffset =
  clockVerdict now True lastAsked `elem` [ClockFeedPhoto, ClockFeedAsked]
  where
    now       = secondsFromRaceStart nowOffset
    lastAsked = secondsFromRaceStart <$> askedOffset

    secondsFromRaceStart s = addUTCTime (fromIntegral s) raceStartsAt

-- | Con la ventana abierta, el reloj se salta la foto si y solo si la página
-- preguntó hace entre 0 y menos de un periodo. Los desplazamientos son segundos
-- desde la salida de la carrera.
skipsPhotoOnlyWhenAskedThisPeriod :: Int -> Maybe Int -> Property
skipsPhotoOnlyWhenAskedThisPeriod nowOffset askedOffset =
  (clockVerdict now True lastAsked == ClockFeedAsked)
    === maybe False (\a -> let d = nowOffset - a in d >= 0 && d < 20) askedOffset
  where
    now       = secondsFromRaceStart nowOffset
    lastAsked = secondsFromRaceStart <$> askedOffset

    secondsFromRaceStart s = addUTCTime (fromIntegral s) raceStartsAt

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

-- | Cualquier gesto sobre Race Overview, mover o estirar: o no se deja, o deja los
-- mismos widgets en el mismo orden, sin solapes y cabiendo en el lienzo.
dragKeepsLayoutValid :: Int -> Bool -> Int -> Int -> Bool
dragKeepsLayoutValid i resize a b =
  case applyDrag gridDivisions raceOverviewFixture drag of
    Nothing -> True
    Just l  ->
      map widgetId l == map widgetId raceOverviewFixture
        && all fitsAt l
        && and [ not (overlaps x y) | (m, x) <- zip [0 :: Int ..] l, (n, y) <- zip [0 ..] l, m < n ]
  where
    held = raceOverviewFixture !! (i `mod` length raceOverviewFixture)
    drag
      | resize    = ResizeTo (widgetId held) (a `mod` 130) (b `mod` 130)
      | otherwise = MoveTo (widgetId held) (a `mod` 140 - 10) (b `mod` 140 - 10)

-- | La tarjeta que se lleva no encoge nunca y acaba donde se pidió, recortado al
-- lienzo.
moveKeepsHeld :: Int -> Int -> Int -> Bool
moveKeepsHeld i a b =
  case applyDrag gridDivisions raceOverviewFixture (MoveTo (widgetId held) x y) of
    Nothing -> True
    Just l  -> case filter ((== widgetId held) . widgetId) l of
      [h] -> wcW h == wcW held && wcH h == wcH held
               && wcX h == max 0 (min (canvasSpan - wcW held) x)
               && wcY h == max 0 (min (canvasSpan - wcH held) y)
      _   -> False
  where
    held = raceOverviewFixture !! (i `mod` length raceOverviewFixture)
    x = a `mod` 140 - 10
    y = b `mod` 140 - 10

-- | Se coja la tarjeta que se coja de Race Overview, por el título o por la esquina,
-- y se lleve a donde se lleve, con el imán o sin él: si se deja, el contorno es donde
-- queda la que se lleva y soltar deja lo que se pinta; si no, soltar deja la foto.
carryShowsDrop :: Int -> Bool -> Bool -> Bool -> Int -> Int -> Bool
carryShowsDrop i corner magnet alt a b =
  case sceneHeld s of
    Just h | heldFits h ->
      dropped == sceneCards s
        && sceneTarget s == find ((== heldId h) . widgetId) (sceneCards s)
    _ -> dropped == raceOverviewFixture
  where
    (s, dropped) = dragOnRace i corner magnet alt a b

-- | Lo guardado de cualquier layout que deje el arrastre vuelve tal cual.
savedDropRoundTrips :: Int -> Bool -> Bool -> Bool -> Int -> Int -> Bool -> Bool
savedDropRoundTrips i corner magnet alt a b right =
  restoreLayout raceOverviewFixture (Just (saveLayout sides dropped)) == FromSaved dropped sides
  where
    (_, dropped) = dragOnRace i corner magnet alt a b
    sides        = Map.map (\c -> if right then c { ccSide = otherSide (ccSide c) } else c)
                     (factoryControls raceOverviewFixture)

-- | Coger la tarjeta @i@ de Race Overview por el título o por la esquina, llevar el
-- puntero a un sitio cualquiera (también fuera del lienzo) y soltar: lo que se pinta
-- justo antes de soltar y lo que queda.
dragOnRace :: Int -> Bool -> Bool -> Bool -> Int -> Int -> (Scene, [WidgetConfig])
dragOnRace i corner magnet alt a b = (scene magnet moved, boardLayout (stepBoard magnet Release moved))
  where
    held    = widgetId (raceOverviewFixture !! (i `mod` length raceOverviewFixture))
    grip    = if corner then ByCorner else ByTitle
    grabbed = stepBoard magnet (Press held grip (700, 500) (1200, 600)) (boardOf raceOverviewFixture)
    moved   = stepBoard magnet (Point (fromIntegral (a `mod` 2000 - 400), fromIntegral (b `mod` 1000 - 200)) alt) grabbed

-- | Tras 'clampToMin' el ancho y el alto cumplen los mínimos del tipo, venga como
-- venga la entrada. Es la garantía entera de la función; lo que NO garantiza —que
-- el widget quepa— es de 'fitsAt' (2026-09-04 c).
clampReachesMin :: Int -> Int -> Int -> Int -> Bool
clampReachesMin x y w h =
  wcW c >= minWidthFor (widgetType r) && wcH c >= minHeightFor (widgetType r)
  where
    r = rect LiveTiming (x, y, w, h)
    c = clampToMin r

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

-- | El estilo que un rectángulo __debe__ producir, escrito a mano y __no__ con
-- 'spanCss': si el esperado llamara a la función bajo prueba, cambiar el
-- denominador o el orden de las declaraciones dejaría el caso verde. Aquí el
-- @120@, el orden y el separador son literales, así que cualquiera de las tres
-- cosas se nota.
expectedSlot :: (Int, Int, Int, Int) -> T.Text
expectedSlot (x, y, w, h) = T.intercalate "; "
  [ "left: calc("   <> n x <> " * 100% / 120)"
  , "top: calc("    <> n y <> " * 100% / 120)"
  , "width: calc("  <> n w <> " * 100% / 120)"
  , "height: calc(" <> n h <> " * 100% / 120)"
  ]
  where n = T.pack . show

-- | __Copia__ de @Pages.Dashboard.raceOverview@, y no el valor de verdad: el
-- paquete @frontend@ no está en @cabal.project@ y solo se construye con GHCJS, así
-- que esta suite no puede importarlo.
--
-- __Es deuda, y conviene decirlo aquí donde se ve:__ si las coordenadas cambian
-- allí y no aquí, estos casos siguen verdes midiendo un layout que ya no existe.
-- Se acepta porque la alternativa —no probarlos— deja los seis rectángulos
-- escritos a mano sin nada que cace un typo, que es el riesgo que este bloque
-- existe para cubrir.
raceOverviewFixture :: [WidgetConfig]
raceOverviewFixture =
  [ rectNamed "live-timing"       LiveTiming       (  0,  0, 60, 90)
  , rectNamed "telemetry"         Telemetry        ( 60,  0, 60, 35)
  , rectNamed "lap-comparison"    LapComparison    ( 60, 35, 60, 50)
  , rectNamed "driver-stats"      HistoricalStats  (  0, 90, 60, 30)
  , rectNamed "constructor-stats" ConstructorStats ( 60, 90, 60, 30)
  ]

-- | Copia de @Pages.Dashboard.qualy@, con la misma advertencia que
-- 'raceOverviewFixture'. Es el caso límite del rectángulo: el lienzo entero.
qualyFixture :: [WidgetConfig]
qualyFixture = [rectNamed "qualy-live-timing" LiveTiming (0, 0, 120, 120)]

-- | El instante tal cual lo emite @\/api\/live@ en la cabecera @X-Data-Fetched-At@
-- (2026-09-11 (b)): UTC, sin fracción de segundo. Es el mismo que produce
-- 'fetchInstant' del bloque de @Handler.Live@, aquí como texto porque es lo que
-- el widget recibe.
fetchedAtIso :: T.Text
fetchedAtIso = "2026-09-11T14:03:22Z"

-- | Indicador de una tarjeta __con algo en pantalla y sin fuente__, que es el caso
-- normal. El que no tiene nada se escribe entero, porque es la excepción y conviene
-- que se lea como tal; los que llevan fuente usan 'shownFrom'.
--
-- __Trae la sesión rodando__, que es lo que hace significativos los modificadores
-- del directo. El caso contrario se escribe con 'offAir' encima, para que cada caso
-- enseñe qué es lo que cambia.
shownAs :: Maybe Origin -> Maybe T.Text -> Bool -> Indicator
shownAs origin fetched failed =
  Indicator
    { indShown     = True
    , indOrigin    = origin
    , indSource    = Nothing
    , indFetched   = fetched
    , indFailed    = failed
    , indRunning   = True
    , indFinalised = False
    }

shownFrom :: Source -> Maybe Origin -> Maybe T.Text -> Bool -> Indicator
shownFrom source origin fetched failed =
  (shownAs origin fetched failed) {indSource = Just source}

-- | El mismo indicador sin sesión rodando, que es el estado normal entre grandes
-- premios.
offAir :: Indicator -> Indicator
offAir i = i {indRunning = False}

-- | Lo que el punto ve en la otra punta: lo guardado del feed, con la sesión
-- finalizada y sin rodar, según si el último refresco falló.
finalisedFeed :: Bool -> Indicator
finalisedFeed failed =
  (offAir (shownFrom Feed (Just Cached) (Just fetchedAtIso) failed)) {indFinalised = True}

-- | Todos los estados que el __punto__ distingue: las cuatro procedencias (contando
-- la desconocida) y el hueco de antes de la primera respuesta, cada uno por si el
-- último refresco volvió o no, y todo ello por si hay sesión rodando.
--
-- __El total no se escribe aquí a propósito.__ Un número en la prosa envejece al
-- añadir una dimensión y sigue cuadrando consigo mismo: los casos preguntan por la
-- lista, no por su tamaño.
--
-- __La sesión rodando dobla la lista aunque no todas las ramas la miren__, y ahí
-- está su utilidad: un caso que pregunte «¿cuántos de TODOS llevan la clase del
-- directo?» solo puede contestar bien si los que no deberían llevarla también están
-- dentro.
--
-- __La fuente no entra en la lista__, y no por olvido: 'indicatorClass' no la lee, y
-- meterla duplicaría cada estado sin añadir ninguno. Que no la lea lo afirma su
-- propio caso, no esta lista.
--
-- Existe para que los casos puedan preguntar «¿cuántos de TODOS hacen X?» en vez
-- de enumerar los que se espera que lo hagan, que es lo que deja fuera al estado
-- que alguien añada mañana.
everyIndicator :: [Indicator]
everyIndicator = concatMap bothWays withSession
  where
    bothWays i = [i, offAir i]

    withSession =
      [ shownAs (Just Fresh)  Nothing             failed | failed <- [False, True] ]
        <> [ shownAs (Just Recent) (Just fetchedAtIso) failed | failed <- [False, True] ]
        <> [ shownAs (Just Cached) (Just fetchedAtIso) failed | failed <- [False, True] ]
        <> [ shownAs (Just Sample) Nothing             failed | failed <- [False, True] ]
        <> [ shownAs Nothing       Nothing             failed | failed <- [False, True] ]
        <> [ (shownAs Nothing Nothing failed) {indShown = False} | failed <- [False, True] ]

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
-- que el coche sin vuelta __decodifique__ (@.:?@) para que el @Context@ decida con
-- 'comparable'. Probar 'assembleComparison' sobre un
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

-- | Contrafigura de 'decodeOf1Drivers' para el @describe@ de 'Of1Driver': devuelve
-- el 'Either' en vez de abortar, porque ahí el fallo del decode __es__ lo que se
-- prueba. Las dos conviven a propósito: para 'stintsOf' y 'rowsOf' la parrilla es
-- un supuesto y un fixture roto es error del test; aquí es el sujeto.
tryOf1Drivers :: ByteString -> Either String [Of1Driver]
tryOf1Drivers = eitherDecodeStrict

-- | Espejo de 'tryOf1Drivers' para la tabla del feed, y por el mismo motivo: lo que
-- se prueba aquí incluye __que un fixture no decodifique__, así que abortar ante el
-- 'Left' pondría verde el caso por la razón contraria.
tryFeedRows :: ByteString -> Either String [FeedRow]
tryFeedRows = eitherDecodeStrict

-- | Los dos espejos para las respuestas que nombran la sesión en OpenF1. Mismo
-- motivo que los anteriores: sus ramas negativas son parte de lo que se prueba.
tryOf1Sessions :: ByteString -> Either String [Of1Session]
tryOf1Sessions = eitherDecodeStrict

tryOf1Meetings :: ByteString -> Either String [Of1Meeting]
tryOf1Meetings = eitherDecodeStrict

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
-- | Un solo piloto con los campos de puesto que se le pasen (vacío: ninguno). Es
-- HUL con sus 7 puntos de la ronda 16, el primero de los tres empatados.
withPosition :: ByteString -> ByteString
withPosition fields =
  envelope $
    ",\"DriverStandings\":[{"
      <> fields
      <> (if fields == "" then "" else ",")
      <> "\"points\":\"7\",\"wins\":\"0\",\"Driver\":\
         \{\"driverId\":\"hulkenberg\",\"code\":\"HUL\",\
         \\"givenName\":\"Nico\",\"familyName\":\"H\\u00fclkenberg\"}}]"

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

-- | Recorte de @GET \/fastf1\/comparison\/{session_key}?drivers=16,1&samples=…@:
-- __un objeto__ con los coches en el orden pedido, la referencia primero. La
-- traza y las fronteras del primero están recortadas a mano; el segundo llega sin
-- ellas, como con @samples=0@.
comparisonObject :: ByteString
comparisonObject =
  "{\"lcSamples\":2,\"lcEntries\":[\
  \{\"ceCar\":\"16\",\"ceDriver\":\"LEC\",\"ceLap\":\"1:29.512\",\"cePart\":\"Q3\",\
  \\"ceSectors\":[29.0,31.0,29.512],\"ceFrontiers\":[1210.5,2650.25],\
  \\"ceTrace\":[{\"ctTime\":0.0,\"ctDistance\":0.0,\"ctSpeed\":287.0,\"ctThrottle\":1.0,\"ctBrake\":0.0},\
  \{\"ctTime\":89.512,\"ctDistance\":5100.0,\"ctSpeed\":301.0,\"ctThrottle\":1.0,\"ctBrake\":0.0}]},\
  \{\"ceCar\":\"1\",\"ceDriver\":\"NOR\",\"ceLap\":\"1:29.345\",\"cePart\":\"Q3\",\
  \\"ceSectors\":[29.048,30.871,29.426],\"ceFrontiers\":null,\"ceTrace\":[]}]}"

-- | Un coche sin vuelta (la referencia), tal como lo emite el servicio: los
-- sectores a @null@ y el tiempo vacío, y el otro coche entero.
comparisonWithoutLap :: ByteString
comparisonWithoutLap =
  "{\"lcSamples\":0,\"lcEntries\":[\
  \{\"ceCar\":\"16\",\"ceDriver\":\"LEC\",\"ceLap\":\"\",\"cePart\":null,\
  \\"ceSectors\":null,\"ceFrontiers\":null,\"ceTrace\":[]},\
  \{\"ceCar\":\"1\",\"ceDriver\":\"NOR\",\"ceLap\":\"1:29.345\",\"cePart\":null,\
  \\"ceSectors\":[29.048,30.871,29.426],\"ceFrontiers\":null,\"ceTrace\":[]}]}"

-- | Ningún coche con vuelta, y las claves opcionales __ausentes__ y no a @null@:
-- tiene que decodificar para que sea 'comparable' quien la descarte, y no una
-- excepción de parseo.
comparisonWithoutLaps :: ByteString
comparisonWithoutLaps =
  "{\"lcEntries\":[{\"ceCar\":\"16\",\"ceDriver\":\"LEC\"},{\"ceCar\":\"1\",\"ceDriver\":\"NOR\"}]}"

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
-- El servicio corre en un @venv@ arrancado a mano y no se despliega con el backend
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

-- | La tabla tal cual la emite @GET \/fastf1\/live@: siete claves por fila, con el
-- líder ya marcado y el estado como el nombre del constructor.
feedTable :: ByteString
feedTable =
  "[{\"ltPosition\":1,\"ltDriver\":\"VER\",\"ltTeam\":\"Red Bull\",\
  \\"ltGap\":\"LEADER\",\"ltInterval\":\"-\",\"ltLastLap\":\"1:29.345\",\
  \\"ltStatus\":\"Running\"},\
  \{\"ltPosition\":2,\"ltDriver\":\"LEC\",\"ltTeam\":\"Ferrari\",\
  \\"ltGap\":\"+1.234\",\"ltInterval\":\"+1.234\",\"ltLastLap\":\"1:29.512\",\
  \\"ltStatus\":\"Dnf\"}]"

-- | Tres filas en orden 3-1-2. No es una forma que el microservicio emita hoy —ya
-- ordena—: ancla que el orden de la tabla lo decide este lado.
feedTableUnordered :: ByteString
feedTableUnordered =
  "[{\"ltPosition\":3,\"ltDriver\":\"NOR\"},\
  \{\"ltPosition\":1,\"ltDriver\":\"VER\"},\
  \{\"ltPosition\":2,\"ltDriver\":\"LEC\"}]"

-- | Lo mínimo que una fila puede traer sin dejar de ser fila.
feedTableMinimal :: ByteString
feedTableMinimal = "[{\"ltPosition\":4,\"ltDriver\":\"ANT\"}]"

feedTableWithoutPosition :: ByteString
feedTableWithoutPosition =
  "[{\"ltPosition\":1,\"ltDriver\":\"VER\"},{\"ltDriver\":\"LEC\"}]"

feedTableWithoutDriver :: ByteString
feedTableWithoutDriver =
  "[{\"ltPosition\":1,\"ltDriver\":\"VER\"},{\"ltPosition\":2}]"

trySession :: ByteString -> Either String FeedSession
trySession = eitherDecodeStrict

tryLive :: ByteString -> Either String FeedLive
tryLive = eitherDecodeStrict

-- La respuesta completa de @GET /fastf1/live@: las dos mitades de la MISMA foto.
feedLiveFull :: ByteString
feedLiveFull =
  "{\"session\":" <> feedSessionRace <> ",\"rows\":" <> feedTable <> "}"

-- El feed contesta pero no anuncia sesión. No se ha observado en ninguna de las
-- dos grabaciones; el cable tiene que poder decirlo igual.
feedLiveWithoutSession :: ByteString
feedLiveWithoutSession = "{\"session\":null,\"rows\":" <> feedTable <> "}"

feedLiveSessionAbsent :: ByteString
feedLiveSessionAbsent = "{\"rows\":" <> feedTable <> "}"

-- Ninguna sesión rodando: es la señal con la que la escalera baja a OpenF1.
feedLiveEmpty :: ByteString
feedLiveEmpty = "{\"session\":null,\"rows\":[]}"

-- Un contrato roto, que NO es lo mismo que una tabla vacía.
feedLiveRowsAbsent :: ByteString
feedLiveRowsAbsent = "{\"session\":" <> feedSessionRace <> "}"

-- Una sesión ya finalizada que aun así llega con su tabla: es lo que el feed sirvió
-- durante horas tras la bandera, y lo que hace falta para ejercitar ese caso.
-- El estado sale de la clasificación 11365 y es el REAL; medidos sobre la grabación
-- de la carrera, los cuatro mensajes de `SessionInfo` dan `Inactive`, `Started`,
-- `Finalised` y `Finalised` — o sea que el campo repite, y por eso lo que se lee es
-- un estado y no una transición.
feedLiveFinalised :: ByteString
feedLiveFinalised =
  "{\"session\":" <> feedSessionQualy <> ",\"rows\":" <> feedTable <> "}"

-- | 'feedTable' ya mapeada. El líder llega con @\"LEADER\"@ y @\"-\"@ puestos por el
-- microservicio, y el segundo con su abandono.
feedRowsFixture :: [LiveTimingRow]
feedRowsFixture =
  [ LiveTimingRow 1 "VER" "Red Bull" "LEADER" "-" "1:29.345" Running "" "" [] False False
  , LiveTimingRow 2 "LEC" "Ferrari" "+1.234" "+1.234" "1:29.512" Dnf "" "" [] False False
  ]

-- El instante en que se sirve la sesión de carrera: media hora después de que el
-- feed publicara su reloj (13:04:05), para que la resta dé un número que se puede
-- comprobar a mano. 13:34:05 UTC = 48845 s.
raceServedAt :: UTCTime
raceServedAt = UTCTime (fromGregorian 2026 9 13) 48845

-- Servir al día siguiente no es un caso rebuscado: el feed no calla al acabar la
-- sesión (2026-09-13 (b)) y sigue devolviendo su última foto indefinidamente.
dayAfterRace :: UTCTime
dayAfterRace = UTCTime (fromGregorian 2026 9 14) 48845

-- La sesión de la carrera 11369 tal como el microservicio la entregaría: los
-- campos de identidad salen del tema de información de sesión y el reloj del suyo,
-- con los valores REALES de la grabación —el reloj se publicó a las 13:04:05 con
-- 01:59:59 por delante, y no se volvió a publicar en toda la carrera—.
feedSessionRace :: ByteString
feedSessionRace =
  "{\"siType\":\"Race\",\"siName\":\"Race\",\
  \\"siMeeting\":\"Spanish Grand Prix\",\"siCircuit\":\"Madring\",\
  \\"siState\":\"Started\",\
  \\"siCurrentLap\":12,\"siTotalLaps\":57,\
  \\"siClockUtc\":\"2026-09-13T13:04:05.01Z\",\
  \\"siClockRemaining\":\"01:59:59\",\"siClockRunning\":true}"

-- La clasificación 11365, que no publica vueltas.
feedSessionQualy :: ByteString
feedSessionQualy =
  "{\"siType\":\"Qualifying\",\"siName\":\"Qualifying\",\
  \\"siMeeting\":\"Spanish Grand Prix\",\"siCircuit\":\"Madring\",\
  \\"siState\":\"Finalised\"}"

-- Un estado que el feed no ha emitido en ninguna de las dos grabaciones. Existe
-- para comprobar que llega hasta el otro lado con su texto y no como un hueco.
feedSessionAborted :: ByteString
feedSessionAborted = "{\"siState\":\"Aborted\"}"

feedSessionLapNoTotal :: ByteString
feedSessionLapNoTotal = "{\"siCurrentLap\":12}"

-- La foto inicial de la carrera, con el reloj aún parado en las dos horas.
feedSessionFrozen :: ByteString
feedSessionFrozen =
  "{\"siClockUtc\":\"2026-09-13T12:58:15.4797492Z\",\
  \\"siClockRemaining\":\"02:00:00\",\"siClockRunning\":false}"

-- Sin la marca: la forma de los dos mensajes que el feed mandó al arrancar un
-- segmento de la clasificación, con el reloj todavía quieto.
feedSessionNoMark :: ByteString
feedSessionNoMark =
  "{\"siClockUtc\":\"2026-09-12T14:24:00.04Z\",\"siClockRemaining\":\"15:00\"}"

feedSessionRunningNoUtc :: ByteString
feedSessionRunningNoUtc =
  "{\"siClockRemaining\":\"01:59:59\",\"siClockRunning\":true}"

feedSessionUtcOnly :: ByteString
feedSessionUtcOnly = "{\"siClockUtc\":\"2026-09-13T13:04:05.01Z\"}"

-- | 'openF1Grid' sin @team_name@ en el segundo coche. Espejo de 'gridWithoutTeam'
-- para el otro @\/drivers@, y con el desenlace __contrario__: allí el equipo es
-- prescindible y la lista sobrevive; aquí es @.:@ y no decodifica ninguno de los
-- dos, porque lo que se perdería con el equipo es la traducción
-- @driver_number → name_acronym@ que las dos áreas consumen.
openF1GridWithoutTeam :: ByteString
openF1GridWithoutTeam =
  "[{\"driver_number\":1,\"name_acronym\":\"NOR\",\"team_name\":\"McLaren\"},\
  \{\"driver_number\":16,\"name_acronym\":\"LEC\"}]"

-- | 'openF1Grid' con @driver_number@ como cadena. No es una forma que OpenF1 emita:
-- es la del __otro__ @\/drivers@, el de FastF1, que publica el número como texto
-- (ver 'driverGrid'). Los dos servicios discrepan en el tipo del mismo concepto, y
-- este fixture ancla que confundirlos no pase por bueno.
openF1GridNumberAsText :: ByteString
openF1GridNumberAsText =
  "[{\"driver_number\":\"1\",\"name_acronym\":\"NOR\",\"team_name\":\"McLaren\"}]"

-- | La hora de arranque prevista de la carrera 11369, tal como OpenF1 la publica.
raceStartsAt :: UTCTime
raceStartsAt = UTCTime (fromGregorian 2026 9 13) (13 * 3600)

-- | La hora de fin __prevista__ de la misma carrera: dos horas justas después. La
-- real fue trece minutos antes, y esa diferencia es la que obliga a 'endMargin'.
raceEndsAt :: UTCTime
raceEndsAt = UTCTime (fromGregorian 2026 9 13) (15 * 3600)

-- | El Sprint de Singapur, del calendario real medido el 2026-09-17: el 10 de
-- octubre de 09:00 a 10:00 UTC, con la clasificación siguiente a las 13:00.
--
-- __Es el caso que decidió que el margen lo eligiera el nombre y no el tipo:__ su
-- @session_type@ es @\"Race\"@ igual que el de la carrera larga, y dura la mitad.
sprintStartsAt :: UTCTime
sprintStartsAt = UTCTime (fromGregorian 2026 10 10) (9 * 3600)

sprintEndsAt :: UTCTime
sprintEndsAt = UTCTime (fromGregorian 2026 10 10) (10 * 3600)

-- | Una sesión del calendario armada a mano, con el tipo y el nombre a la vista.
--
-- __El tipo entra aunque 'endMargin' no lo mire__, y es a propósito: los casos del
-- Sprint existen para enseñar que el tipo dice @\"Race\"@ y aun así el margen es el
-- corto. Con el tipo escondido en el helper no se vería.
--
-- La clave del gran premio es la de España, que es la que no miran los casos del
-- margen. Los de 'schedule' sí la miran y usan 'scheduledIn'.
scheduled :: T.Text -> T.Text -> UTCTime -> UTCTime -> Of1Session
scheduled = scheduledIn 1294

-- | La misma, con la clave del gran premio a la vista.
--
-- __Existe porque un helper que la fijara no podía expresar dos grandes premios__, y
-- con uno solo el caso de 'schedule' que afirma «el suyo y no el del primero» pasaba
-- por el motivo equivocado. Lo destapó la prueba al ponerse roja.
scheduledIn :: Int -> T.Text -> T.Text -> UTCTime -> UTCTime -> Of1Session
scheduledIn key sType name start end = Of1Session sType name key start end Nothing

-- | Las dos primeras sesiones de Bakú y los instantes que rodean a la primera,
-- tomados del calendario real el 2026-09-15: P1 el 24 a las 08:30 UTC y P2 el mismo
-- día a las 12:00.
--
-- __Se usan horas reales y no redondas inventadas__ para que los casos de la
-- ventana hablen del calendario que el backend va a leer. Con el margen de 15 min,
-- P1 abre a las 08:15 y P2 a las 11:45, y los instantes de abajo caen a cada lado
-- de esas dos fronteras.
bakuP1, bakuP2 :: UTCTime
bakuP1 = UTCTime (fromGregorian 2026 9 24) (8 * 3600 + 30 * 60)
bakuP2 = UTCTime (fromGregorian 2026 9 24) (12 * 3600)

-- | Y la hora de fin prevista de P1: 09:30, o sea los 60 min que dura una práctica.
bakuP1End :: UTCTime
bakuP1End = UTCTime (fromGregorian 2026 9 24) (9 * 3600 + 30 * 60)

-- | El fin de semana de Bakú tal como el backend lo guarda: P1 y P2, las dos del
-- gran premio de Azerbaiyán. __P2 va primero__ para que ningún caso de 'upNext'
-- pueda pasar cogiendo la primera de la lista en vez de la más próxima.
bakuWeekend :: [ScheduledSession]
bakuWeekend =
  [ ScheduledSession "Practice 2" 1295 "Azerbaijan Grand Prix" bakuP2 bakuP2End
  , ScheduledSession "Practice 1" 1295 "Azerbaijan Grand Prix" bakuP1 bakuP1End
  ]

bakuP2End :: UTCTime
bakuP2End = UTCTime (fromGregorian 2026 9 24) (13 * 3600)

-- | El mismo, sin nombres de gran premio: lo que queda si @\/meetings@ no contesta.
namelessWeekend :: [ScheduledSession]
namelessWeekend = map (\s -> s {ssGrandPrix = ""}) bakuWeekend

-- | Una sesión enseñándose con ese estado, oído. El gran premio es el de España,
-- o sea __distinto__ del de las sesiones de 'bakuWeekend': así los casos que
-- comparan los dos lados no pasan por coincidencia.
stateOf :: SessionState -> SessionInfo
stateOf = sessionAt "Spanish Grand Prix"

-- | La misma, con el gran premio a la vista: hace falta para el caso que comprueba
-- qué pasa cuando los dos lados hablan del MISMO gran premio.
sessionAt :: T.Text -> SessionState -> SessionInfo
sessionAt gp st = (stateless gp) {siState = Just (StateReading st Heard)}

-- | Y una sin estado ninguno, que es lo que sirve OpenF1 en el borde.
stateless :: T.Text -> SessionInfo
stateless gp = SessionInfo "Race" "Race" gp Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing [] Nothing

-- | 07:00 — hora y cuarto __antes__ de que la ventana de P1 abra.
bakuLongBefore :: UTCTime
bakuLongBefore = UTCTime (fromGregorian 2026 9 24) (7 * 3600)

-- | 08:20 — dentro del margen y aún antes de la hora prevista de P1.
bakuInLead :: UTCTime
bakuInLead = UTCTime (fromGregorian 2026 9 24) (8 * 3600 + 20 * 60)

-- | 09:00 — P1 rodando.
bakuDuringP1 :: UTCTime
bakuDuringP1 = UTCTime (fromGregorian 2026 9 24) (9 * 3600)

-- | 09:25 y 09:26 — el feed dando P1 por finalizada, y repitiéndolo. El segundo
-- existe porque el campo de estado __repite__ (2026-09-14 (k)).
bakuP1Finalised, bakuP1FinalisedAgain :: UTCTime
bakuP1Finalised = UTCTime (fromGregorian 2026 9 24) (9 * 3600 + 25 * 60)
bakuP1FinalisedAgain = UTCTime (fromGregorian 2026 9 24) (9 * 3600 + 26 * 60)

-- | 10:00 — P1 acabada y la ventana de P2 todavía sin abrir.
bakuAfterP1 :: UTCTime
bakuAfterP1 = UTCTime (fromGregorian 2026 9 24) (10 * 3600)

-- | 11:50 — dentro del margen de P2, con la finalización de P1 ya vista.
bakuInLeadP2 :: UTCTime
bakuInLeadP2 = UTCTime (fromGregorian 2026 9 24) (11 * 3600 + 50 * 60)

-- | La P1 de Malasia, el 2 de octubre a las 04:30 UTC, y lo que el feed dijo
-- alrededor (grabado esa noche): la carrera de Bakú por finalizada hasta anunciar
-- la P1 a las 04:16:59. 'malasiaBakuStillShown' es 04:16, aún con Bakú.
malasiaP1, malasiaBakuStillShown, malasiaInLeadP1 :: UTCTime
malasiaP1 = UTCTime (fromGregorian 2026 10 2) (4 * 3600 + 30 * 60)
malasiaBakuStillShown = UTCTime (fromGregorian 2026 10 2) (4 * 3600 + 16 * 60)
malasiaInLeadP1 = UTCTime (fromGregorian 2026 10 2) (4 * 3600 + 20 * 60)

-- | 05:35 y 05:40 — la P1 dada por finalizada, y un instante después.
malasiaP1Finalised, malasiaAfterP1 :: UTCTime
malasiaP1Finalised = UTCTime (fromGregorian 2026 10 2) (5 * 3600 + 35 * 60)
malasiaAfterP1 = UTCTime (fromGregorian 2026 10 2) (5 * 3600 + 40 * 60)

-- | @GET \/sessions?session_key=latest@ __verbatim__, medido el 2026-09-15 con la
-- carrera 11369 como última sesión. Las quince claves son las que OpenF1 emite; el
-- tipo consume tres, y que las otras doce no estorben es contrato del decode.
--
-- __Lleva @date_start@ y @date_end@ a propósito aunque el tipo aún no los lea:__ son
-- los campos con los que se decidirá cuándo mirar el feed, y el fixture tiene que
-- seguir siendo la respuesta entera cuando les llegue el turno.
openF1SessionArray :: ByteString
openF1SessionArray =
  "[{\"session_key\":11369,\"session_type\":\"Race\",\"session_name\":\"Race\",\
  \\"date_start\":\"2026-09-13T13:00:00+00:00\",\
  \\"date_end\":\"2026-09-13T15:00:00+00:00\",\"meeting_key\":1294,\
  \\"circuit_key\":153,\"circuit_short_name\":\"Madring\",\"country_key\":1,\
  \\"country_code\":\"ESP\",\"country_name\":\"Spain\",\"location\":\"Madrid\",\
  \\"gmt_offset\":\"02:00:00\",\"year\":2026,\"is_cancelled\":false}]"

-- | 'openF1SessionArray' sin @circuit_short_name@, con el resto de obligatorios.
openF1SessionNoCircuit :: ByteString
openF1SessionNoCircuit =
  "[{\"session_key\":11369,\"session_type\":\"Race\",\"session_name\":\"Race\",\
  \\"date_start\":\"2026-09-13T13:00:00+00:00\",\
  \\"date_end\":\"2026-09-13T15:00:00+00:00\",\"meeting_key\":1294}]"

-- | 'openF1SessionArray' sin @session_type@. No hay default semánticamente correcto
-- —una sesión de tipo vacío no existe—, así que tumbar la lista es lo correcto: el
-- fallo sale del 'Handler.Live.Context' como «no se sabe», sin tocar la tabla.
--
-- __Lleva el resto de campos obligatorios__, las dos horas incluidas: sin ellas
-- fallaría también por eso y el caso pasaría por el motivo equivocado.
openF1SessionNoType :: ByteString
openF1SessionNoType =
  "[{\"session_key\":11369,\"session_name\":\"Race\",\"meeting_key\":1294,\
  \\"date_start\":\"2026-09-13T13:00:00+00:00\",\
  \\"date_end\":\"2026-09-13T15:00:00+00:00\"}]"

-- | Y sin @date_start@, que es el campo del que cuelga la ventana entera: sin hora
-- de arranque esa sesión no puede decidir nada, así que tampoco entra a medias.
openF1SessionNoStart :: ByteString
openF1SessionNoStart =
  "[{\"session_key\":11369,\"session_type\":\"Race\",\"session_name\":\"Race\",\
  \\"meeting_key\":1294,\"date_end\":\"2026-09-13T15:00:00+00:00\"}]"

-- | Y sin @date_end@, que es de lo que cuelga el estado deducido. Va aparte del
-- anterior por lo mismo que aquél va aparte del de tipo: un fixture al que le falten
-- dos campos obligatorios no dice cuál de los dos lo tumbó.
openF1SessionNoEnd :: ByteString
openF1SessionNoEnd =
  "[{\"session_key\":11369,\"session_type\":\"Race\",\"session_name\":\"Race\",\
  \\"meeting_key\":1294,\"date_start\":\"2026-09-13T13:00:00+00:00\"}]"

-- | @GET \/meetings?meeting_key=1294@ __verbatim__, medido el mismo día. Diecisiete
-- claves, de las que el tipo consume una.
--
-- La eñe del nombre oficial va escapada y no como byte: el valor no lo lee nadie, y
-- un literal 'ByteString' con UTF-8 crudo se trunca por carácter.
openF1MeetingArray :: ByteString
openF1MeetingArray =
  "[{\"meeting_key\":1294,\"meeting_name\":\"Spanish Grand Prix\",\
  \\"meeting_official_name\":\
  \\"FORMULA 1 TAG HEUER GRAN PREMIO DE ESPA\\u00d1A 2026\",\
  \\"location\":\"Madrid\",\"country_key\":1,\"country_code\":\"ESP\",\
  \\"country_name\":\"Spain\",\
  \\"country_flag\":\"https://media.formula1.com/spain-flag.png\",\
  \\"circuit_key\":153,\"circuit_short_name\":\"Madring\",\
  \\"circuit_type\":\"Temporary - Street\",\
  \\"circuit_info_url\":\"https://api.multiviewer.app/api/v1/circuits/153/2026\",\
  \\"circuit_image\":\"https://media.formula1.com/Spain%20carbon.png\",\
  \\"gmt_offset\":\"02:00:00\",\
  \\"date_start\":\"2026-09-11T11:30:00+00:00\",\
  \\"date_end\":\"2026-09-13T15:00:00+00:00\",\"year\":2026,\
  \\"is_cancelled\":false}]"

-- | 'openF1MeetingArray' sin @meeting_name@. __Lleva la clave__, que es el otro
-- campo obligatorio: sin ella el caso pasaría por el motivo equivocado.
openF1MeetingNoName :: ByteString
openF1MeetingNoName = "[{\"meeting_key\":1294,\"location\":\"Madrid\"}]"

-- | Y sin @meeting_key@, que es por donde cada gran premio se junta con sus
-- sesiones. Desde que se piden todos los del año, sin clave no sirve de nada.
openF1MeetingNoKey :: ByteString
openF1MeetingNoKey =
  "[{\"meeting_name\":\"Spanish Grand Prix\",\"location\":\"Madrid\"}]"

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
-- 'Of1Result' consume cinco. Lleva los cinco que no modela —@position@ y
-- @gap_to_leader@ entre ellos— porque el decode tiene que ignorarlos: es la misma
-- razón por la que 'openF1Grid' lleva @broadcast_name@.
--
-- @duration@ entra __ya serializado__, por lo mismo que los gaps de 'interval': su
-- forma es lo que se prueba, y OpenF1 la emite como número en prácticas y carrera,
-- como arreglo de tres en Qualy y como @null@ cuando no hay tiempo.
result
  :: Int -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString
  -> ByteString
result number pos dnf dns dsq duration =
  "{\"position\":" <> pos
    <> ",\"driver_number\":" <> BC.pack (show number)
    <> ",\"number_of_laps\":72,\"points\":25.0"
    <> ",\"dnf\":" <> dnf
    <> ",\"dns\":" <> dns
    <> ",\"dsq\":" <> dsq
    <> ",\"duration\":" <> duration <> ",\"gap_to_leader\":0"
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

-- | Un 'Of1Result' con solo lo que 'classificationGaps' mira: el coche y su tiempo.
-- Las tres banderas van a 'False' porque esa función no las lee.
timedResult :: Int -> Maybe Double -> Of1Result
timedResult number duration =
  Of1Result
    { orNumber   = number
    , orDnf      = False
    , orDns      = False
    , orDsq      = False
    , orDuration = duration
    }

-- | Un arreglo JSON a partir de sus elementos. 'Data.Aeson.Array' pide un @Vector@,
-- y traerlo aquí haría depender la suite de @vector@ solo por el constructor.
jsonArray :: [Value] -> Value
jsonArray = toJSON

-- | La duración de carrera de los dos coches en los fixtures que no prueban las
-- diferencias derivadas. Es la de la 11353, y la comparten a propósito: cualquier
-- caso que las use lleva @\/intervals@ con datos, así que 'classificationGaps' no
-- se alcanza.
raceDuration :: ByteString
raceDuration = "7484.859"

-- | Clasificación sin incidencias: los dos coches con las tres banderas en @false@.
resultArray :: ByteString
resultArray =
  "[" <> result 16 "1" "false" "false" "false" raceDuration
    <> "," <> result 1 "2" "false" "false" "false" raceDuration
    <> "]"

-- | El caso medido del coche 23 de la 11353, trasplantado al coche 1: @dnf: true@
-- __con__ @position@. Es el que hace que 'ltStatus' tenga que ser campo propio.
resultWithDnf :: ByteString
resultWithDnf =
  "[" <> result 16 "1" "false" "false" "false" raceDuration
    <> "," <> result 1 "2" "true" "false" "false" raceDuration
    <> "]"

-- | El coche 1 con abandono __y__ descalificación. No se ha observado; fija la
-- prioridad de 'statusOf' para que no la decida el orden de los guardas.
resultDsqAndDnf :: ByteString
resultDsqAndDnf =
  "[" <> result 16 "1" "false" "false" "false" raceDuration
    <> "," <> result 1 "2" "true" "false" "true" raceDuration
    <> "]"

-- | El coche 1 sin tomar la salida. Cero casos en las cuatro sesiones medidas.
resultWithDns :: ByteString
resultWithDns =
  "[" <> result 16 "1" "false" "false" "false" raceDuration
    <> "," <> result 1 "null" "false" "true" "false" "null"
    <> "]"

-- | Clasificación de una sesión de prácticas: @duration@ es la mejor vuelta y llega
-- como número. Los dos tiempos son los del podio de la FP3 de Madrid (11364), y su
-- diferencia real es @+0.166@.
resultPractice :: ByteString
resultPractice =
  "[" <> result 16 "1" "false" "false" "false" "92.797"
    <> "," <> result 1 "2" "false" "false" "false" "92.963"
    <> "]"

-- | Clasificación de una Qualy: @duration@ llega como __arreglo de tres__, con nulos
-- en los segmentos que el piloto no disputó. Los números son los de la Qualy 11357:
-- el 16 corrió las tres Q y vale su Q3 (81.786); el 1 cayó en Q1 y vale su Q1
-- (82.779), o sea @+0.993@ contra la pole y __no__ los @+0.167@ que OpenF1 publica
-- contra el líder de Q1.
resultQualy :: ByteString
resultQualy =
  "[" <> result 16 "1" "false" "false" "false" "[82.612,82.077,81.786]"
    <> "," <> result 1 "2" "false" "false" "false" "[82.779,null,null]"
    <> "]"

-- | El coche 1 con el arreglo de Qualy __entero a nulos__: no marcó tiempo en
-- ninguna Q. No se ha observado; la forma solo se construye a mano.
resultQualyAllNull :: ByteString
resultQualyAllNull =
  "[" <> result 16 "1" "false" "false" "false" "[82.612,82.077,81.786]"
    <> "," <> result 1 "2" "false" "false" "false" "[null,null,null]"
    <> "]"

-- | Clasificación de una carrera: @duration@ es el tiempo __total__, no una vuelta.
-- Los dos son los de la 11361, cuya diferencia publicada es @+3.857@.
resultRace :: ByteString
resultRace =
  "[" <> result 16 "1" "false" "false" "false" "6675.281"
    <> "," <> result 1 "2" "false" "false" "false" "6679.138"
    <> "]"

-- | El coche 1 con @duration@ nulo y __sin ninguna bandera puesta__: el caso medido
-- del coche 23 en la FP3 de hoy (11364), que dio dos vueltas y no cronometró
-- ninguna. Va aparte de 'resultWithDns' para que la ausencia de tiempo no se pruebe
-- a través de una incidencia.
resultNoTime :: ByteString
resultNoTime =
  "[" <> result 16 "1" "false" "false" "false" "92.797"
    <> "," <> result 1 "2" "false" "false" "false" "null"
    <> "]"

-- | Las tres banderas ausentes en los dos objetos. Con @.:@ este fixture no
-- decodifica y se pierde la tabla entera.
resultWithoutFlagKeys :: ByteString
resultWithoutFlagKeys =
  "[" <> resultNoFlags 16 "1"
    <> "," <> resultNoFlags 1 "2"
    <> "]"

-- | Filas ya ensambladas para los casos de procedencia: no prueban el ensamblado,
-- sino lo que 'withProvenance' pone alrededor, así que no pasan por ningún fixture JSON.
liveRowsFixture :: [LiveTimingRow]
liveRowsFixture =
  [ LiveTimingRow 1 "LEC" "Ferrari" "LEADER" "-" "1:21.004" Running "-" "" [] False False
  , LiveTimingRow 2 "NOR" "McLaren" "+0.412" "+0.412" "1:21.390" Running "-" "" [] False False
  ]

-- | La sesión de la carrera 11369 ya mapeada, con los valores que
-- 'feedSessionRace' produce al servirse en 'raceServedAt'.
raceSessionFixture :: SessionInfo
raceSessionFixture =
  SessionInfo
    { siType    = "Race"
    , siName    = "Race"
    , siMeeting = "Spanish Grand Prix"
    , siCircuit = Just "Madring"
    , siState   = Just (StateReading SessionStarted Heard)
    , siLaps    = Just (LapProgress 12 57)
    , siClock   = Just (SessionClock 5400 True)
    , siPart    = Nothing
    , siTrack   = Nothing
    , siCountdown = Nothing
    , siStart   = Nothing
    , siEntries = []
    , siCutOffTime = Nothing
    }

-- | Una sesión con el tipo, el nombre y el gran premio que se le pidan, __sin
-- circuito__, y el resto como en 'raceSessionFixture'.
--
-- __Se construye actualizando y no enumerando los siete campos__: un campo nuevo en
-- 'SessionInfo' dejaría aquí un hueco que el compilador solo avisa, y actualizando
-- lo hereda del fixture.
namedSession :: T.Text -> T.Text -> T.Text -> SessionInfo
namedSession sType sName sMeeting =
  raceSessionFixture
    { siType = sType, siName = sName, siMeeting = sMeeting, siCircuit = Nothing }

-- | Finalizada y dicho por la fuente, que es lo que la otra punta pone en lo guardado.
finalisedHeard' :: StateReading
finalisedHeard' = StateReading SessionFinalised Heard

-- | Un instante del sábado 3 de octubre de 2026 en UTC, el día de la clasificación de
-- Malasia. Las horas pueden pasar de 24, y caen en los días siguientes.
malaysiaAt :: Int -> Int -> Int -> UTCTime
malaysiaAt h m s =
  addUTCTime (fromIntegral (h * 3600 + m * 60 + s)) (UTCTime (fromGregorian 2026 10 3) 0)

-- | La clasificación de Malasia tal como la entrega el microservicio, con el estado
-- del campo que se pida y los avisos de pista que habían llegado hasta un instante.
--
-- Los avisos son los REALES de la grabación, incluida la bandera de la P3 que la foto
-- arrastraba; los de sector se omiten porque la regla no los mira.
malaysiaQuali :: T.Text -> T.Text -> FeedSession
malaysiaQuali upTo field =
  decoded { fsState = field, fsFlags = filter ((<= upTo) . ffUtc) (fsFlags decoded) }
  where
    decoded = either error id (trySession feedSessionMalaysiaQuali)

feedSessionMalaysiaQuali :: ByteString
feedSessionMalaysiaQuali =
  "{\"siType\":\"Qualifying\",\"siName\":\"Qualifying\",\
  \\"siMeeting\":\"Bahrain Grand Prix\",\"siState\":\"Started\",\
  \\"siStartDate\":\"2026-10-03T16:00:00\",\"siGmtOffset\":\"08:00:00\",\
  \\"siFlags\":[\
  \{\"utc\":\"2026-10-03T04:59:00\",\"flag\":\"GREEN\",\"scope\":\"Track\"},\
  \{\"utc\":\"2026-10-03T05:30:00\",\"flag\":\"CHEQUERED\",\"scope\":\"Track\"},\
  \{\"utc\":\"2026-10-03T08:00:00\",\"flag\":\"GREEN\",\"scope\":\"Track\"},\
  \{\"utc\":\"2026-10-03T08:18:00\",\"flag\":\"CHEQUERED\",\"scope\":\"Track\"},\
  \{\"utc\":\"2026-10-03T08:25:00\",\"flag\":\"GREEN\",\"scope\":\"Track\"},\
  \{\"utc\":\"2026-10-03T08:40:00\",\"flag\":\"CHEQUERED\",\"scope\":\"Track\"},\
  \{\"utc\":\"2026-10-03T08:47:00\",\"flag\":\"GREEN\",\"scope\":\"Track\"},\
  \{\"utc\":\"2026-10-03T09:00:00\",\"flag\":\"CHEQUERED\",\"scope\":\"Track\"}]}"

-- | La clasificación de Malasia a las 08:30 UTC, en la Q2, como la emite el
-- microservicio: solo lo que no estaba antes, con el último aviso de la foto.
feedSessionMalaysiaQ2 :: ByteString
feedSessionMalaysiaQ2 =
  "{\"siType\":\"Qualifying\",\"siName\":\"Qualifying\",\
  \\"siPart\":2,\"siEntries\":[22,16,10],\"siCutOffTime\":\"1:43.230\",\
  \\"siTrack\":{\"status\":\"1\",\"message\":\"AllClear\"},\
  \\"siNotices\":[{\"utc\":\"2026-10-03T08:22:15\",\"category\":\"Other\",\
  \\"message\":\"FIA STEWARDS: Q1 INCIDENT INVOLVING CAR 18 (STR) NOTED - FAILING TO FOLLOW \
  \RACE DIRECTORS INSTRUCTIONS - MAXIMUM DELTA TIME\"}]}"

-- | Tres filas de la misma foto: el líder de la Q2, un eliminado en la Q1 y uno sin
-- tiempo dentro del 107 % (este último, de las 07:50, cuando nadie lo tenía).
feedRowsMalaysiaQ2 :: ByteString
feedRowsMalaysiaQ2 =
  "[{\"ltPosition\":1,\"ltDriver\":\"VER\",\"ltBestLap\":\"-\",\
  \\"ltPartBests\":[\"1:36.477\",\"-\",\"-\"],\"ltKnockedOut\":false,\"ltCutoff\":false},\
  \{\"ltPosition\":22,\"ltDriver\":\"PER\",\"ltBestLap\":\"1:38.933\",\
  \\"ltPartBests\":[\"1:38.933\",\"-\",\"-\"],\"ltKnockedOut\":true,\"ltCutoff\":false},\
  \{\"ltPosition\":1,\"ltDriver\":\"ANT\",\"ltBestLap\":\"-\",\
  \\"ltPartBests\":[\"-\",\"-\",\"-\"],\"ltKnockedOut\":false,\"ltCutoff\":true}]"

-- | Lo que sirve el peldaño del feed: las filas y la sesión que las nombra.
liveTableFixture :: LiveTable
liveTableFixture = LiveTable (Just raceSessionFixture) liveRowsFixture NextUnknown

-- | 'servedFromBox' sobre 'liveTableFixture', guardada en el instante dado y servida
-- tantos segundos después. Lo que varía entre casos es la edad, y es lo único que
-- queda a la vista.
servedFromBox' :: UTCTime -> NominalDiffTime -> (Origin, LiveTable)
servedFromBox' storedAt age =
  servedFromBox (addUTCTime age storedAt) storedAt liveTableFixture

-- | El sello y el reloj de la sesión de lo servido, que son las dos mitades de la
-- misma decisión.
boxClock :: (Origin, LiveTable) -> (Origin, Maybe SessionClock)
boxClock (origin, table) = (origin, siClock =<< liveSession table)

-- | Lo que sirven los peldaños que no saben de qué sesión hablan — OpenF1 y el
-- dato de ejemplo. __Es «no se sabe» y no una sesión vacía__, que es la distinción
-- que motiva el 'Maybe' de 'Common.Types.liveSession'.
namelessTableFixture :: LiveTable
namelessTableFixture = LiveTable Nothing liveRowsFixture NextUnknown

-- | Las 14:03:22 UTC del 2026-09-11 __con fracción de segundo__, que es lo que da
-- 'getCurrentTime': 'fetchedAtText' tiene que tirarla.
fetchInstant :: UTCTime
fetchInstant = UTCTime (fromGregorian 2026 9 11) 50602.123456

-- | Los parámetros de la sesión en curso, sacados de la opción que se manda de verdad.
latest :: [(T.Text, Maybe T.Text)]
latest = queryParamToList latestSession

-- | Un minuto después de 'fetchInstant': el «ahora» de 'tyreStep', distinto de la hora de
-- lo guardado para que no se puedan confundir.
tyreNow :: UTCTime
tyreNow = addUTCTime 60 fetchInstant

-- | Lo que trae OpenF1 en las pruebas de 'tyreStep'.
freshStints :: [TyreStint]
freshStints = [TyreStint "NOR" "MEDIUM" 1 20, TyreStint "NOR" "HARD" 21 44]

-- | Lo guardado en las pruebas de 'tyreStep': otra tanda, para que servir la equivocada
-- se note.
keptStints :: [TyreStint]
keptStints = [TyreStint "LEC" "SOFT" 1 12]

-- | Las tres cabeceras de una respuesta de @\/api\/live@, buscadas por su nombre
-- __de tipo__, que es el que Servant usa al serializarlas.
headersOf
  :: LiveResponse
  -> ( ResponseHeader OriginHeaderName T.Text
     , ResponseHeader FetchedAtHeaderName T.Text
     , ResponseHeader SourceHeaderName T.Text
     )
headersOf r = (lookupResponseHeader r, lookupResponseHeader r, lookupResponseHeader r)

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

-- | La forma corta solo se ahorra las horas mientras no las haya, así que a partir
-- de la hora las dos primeras formas son la __misma cadena__. Es lo que hace que
-- elegir entre ellas sea una decisión de ancho por debajo de la hora y nada por
-- encima; los casos de arriba lo fijan en el borde y esto lo extiende al resto.
clockFormsMeet :: Int -> Property
clockFormsMeet n =
  formatClock ClockCompact secs === formatClock ClockHours secs
  where
    -- `mod` con divisor positivo no devuelve negativos ni siquiera con `minBound`,
    -- al contrario que `abs`; es el patrón que ya usan `neverScientific` y
    -- `originRoundTrips`.
    secs = 3600 + (n `mod` 86400)

-- | Lo que hace utilizable la cabecera: lo que el backend escribe es exactamente lo
-- que el widget recupera. Los casos de arriba lo comprueban sobre las etiquetas de
-- hoy; esto lo ata al __tipo__, así que un constructor nuevo cuya etiqueta se olvide
-- en 'originFrom' rompe aquí y no en producción.
--
-- El 'Origin' se genera desde un 'Int' con @mod@ en vez de declarar un 'Arbitrary',
-- que es el patrón que ya usan 'neverScientific' y 'snapIsIdempotent'. __El número
-- de constructores sale del propio tipo__ y no de un literal: hasta el 2026-09-18
-- era un @3@ escrito a mano, con su propio aviso de que se quedaría corto en
-- silencio, y el cuarto constructor lo cumplió.
originRoundTrips :: Int -> Property
originRoundTrips n = originFrom (originLabel origin) === Just origin
  where
    origins = [minBound .. maxBound] :: [Origin]
    origin = origins !! (n `mod` length origins)

-- | El número de fuentes sale del propio tipo y no de un literal, igual que en
-- 'originRoundTrips': si mañana hay una tercera, la propiedad la cubre sin que nadie
-- se acuerde de tocar el módulo.
sourceRoundTrips :: Int -> Property
sourceRoundTrips n = sourceFrom (sourceLabel source) === Just source
  where
    sources = [minBound .. maxBound] :: [Source]
    source = sources !! (n `mod` length sources)

-- | La regla que gobierna el aviso: __callar es privilegio de 'Fresh'__ y de nadie
-- más, con hora o sin ella. Es la propiedad que impide el fallo que motivó el
-- módulo — servir un respaldo sin decirlo—, y la que impide el error simétrico:
-- avisar sobre un dato que sí es bueno.
onlyFreshIsSilent :: Int -> Maybe String -> Property
onlyFreshIsSilent n at = silent === (origin == Fresh)
  where
    origins = [minBound .. maxBound] :: [Origin]
    origin = origins !! (n `mod` length origins)
    silent =
      case originNotice origin (T.pack <$> at) of
        Nothing -> True
        Just _  -> False

-- | Con la referencia primero, la última Δ del otro es su vuelta menos la de la
-- referencia, y la de la referencia es cero: los sectores suman la vuelta.
lastDeltaIsLapDiff
  :: (NonNegative Double, NonNegative Double, NonNegative Double)
  -> (NonNegative Double, NonNegative Double, NonNegative Double)
  -> Property
lastDeltaIsLapDiff (NonNegative r1, NonNegative r2, NonNegative r3) (NonNegative c1, NonNegative c2, NonNegative c3) =
  map last (deltasAgainst AgainstReference [Just (r1, r2, r3), Just (c1, c2, c3)])
    === [0, (c1 + c2 + c3) - (r1 + r2 + r3)]

-- | La base es la vuelta más corta, así que ninguna Δ acaba en negativo.
noneEndsBelowFastest :: [(NonNegative Double, NonNegative Double, NonNegative Double)] -> Bool
noneEndsBelowFastest laps =
  all (>= 0) [last d | d <- deltasAgainst AgainstFastest [Just (a, b, c) | (NonNegative a, NonNegative b, NonNegative c) <- laps]]
