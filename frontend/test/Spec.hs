module Main (main) where

import           Common.Carry                (Held (..), Scene (..), heldStyle)
import           Common.Chart                (chartHeight)
import           Common.Comparison           (Baseline (..), ChartType (..),
                                              LapChoice (..), LiveCard (..),
                                              LiveEntry (..), chartTypeTraces,
                                              chartTypesInOrder, defaultAxis,
                                              Added (..), WithGroups (..),
                                              Curve (..), Layer (..))
import           Common.ComparisonCard       (rowHeight)
import           Common.FixedLayouts         (cfg, qualy, raceOverview,
                                              strategy)
import           Common.Layout               (slotStyle)
import           Common.Origin               (Origin (..), Source (..),
                                              Sourced (..))
import           Common.Session              (SessionCode (..), SessionKey (..),
                                              readSessionKey)
import           Common.Shown                (Fetched (..), Indicator (..),
                                              Poll (..), pollIdle)
import           Common.Traces               (TraceRows (..), channelsInOrder,
                                              traceChannels, tracesHeight)
import           Common.Types                (ComparisonEntry (..),
                                              DriverEntry (..),
                                              HistoricalStat (..),
                                              LapComparison (..),
                                              LapProgress (..), Layout (..),
                                              LiveTable (..),
                                              LiveTimingRow (..),
                                              SessionInfo (..),
                                              SessionState (..),
                                              StatEntity (..), StateBasis (..),
                                              StateReading (..),
                                              TelemetryGap (..), UpNext (..),
                                              WidgetConfig (..), WidgetId (..),
                                              WidgetType (..), emptyLiveRow)
import           Common.TyreStrategy         (SetRow, setRows)
import           Data.List                   (nub)
import qualified Data.Map                    as Map
import           Data.Maybe                  (isJust)
import qualified Data.Text                   as T
import           Test.Hspec
import           Test.QuickCheck

import qualified Client.Helper               as CH
import qualified Pages.Dashboard.Helper      as D
import qualified Widgets.Comparison.Helper   as C
import qualified Widgets.Historical.Helper   as H
import           Widgets.Live.Helper         (indicatorOf, liveAside,
                                              missingTitle, sessionOf, stateOf)
import qualified Widgets.LiveTiming.Helper   as LT
import qualified Widgets.TyreStrategy.Helper as TS

main :: IO ()
main = hspec $ do
  comparisonSpec
  liveTimingSpec
  tyreStrategySpec
  liveSpec
  historicalSpec
  dashboardSpec
  clientSpec

clientSpec :: Spec
clientSpec = describe "Client.Helper" $ do
  let body = Just "[1,2]"
  it "un 200 con cuerpo que se entiende, el valor; sin cuerpo o sin entenderlo, no" $
    [ CH.fetchedFrom 200 body, CH.fetchedFrom 200 Nothing, CH.fetchedFrom 200 (Just "no") ]
      `shouldBe` [Got [1, 2 :: Int], NotFetched, NotFetched]

  it "un 404 es Absent, traiga lo que traiga" $
    property $ \txt -> CH.fetchedFrom 404 (T.pack <$> txt) === (Absent :: Fetched [Int])

  it "cualquier otro código es un fallo, aunque el cuerpo se entienda" $
    property $ \code -> code /= 200 && code /= 404 ==>
      CH.fetchedFrom code body === (NotFetched :: Fetched [Int])
        .&&. CH.decodedFrom code body === (Nothing :: Maybe [Int])

  it "decodedFrom de un 404 tampoco da nada" $
    CH.decodedFrom 404 body `shouldBe` (Nothing :: Maybe [Int])

dashboardSpec :: Spec
dashboardSpec = describe "Pages.Dashboard.Helper" $ do
  let fixed = concatMap widgets [raceOverview, qualy, strategy]
      lap = cfg (WidgetId "lap-comparison") LapComparison (60, 0, 60, 85)
      moved = lap {wcX = 30}
  describe "slotClass" $
    it "de los siete slots de los layouts fijos, la esquina la tocan tres" $
      [ widgetId w | w <- fixed, D.slotClass w /= "widget-slot" ]
        `shouldBe` map WidgetId ["lap-comparison", "qualy-live-timing", "tyre-strategy"]

  describe "slotAttrs" $ do
    it "sin nada cogido, su clase y el rectángulo con el que la pinta la escena" $
      D.slotAttrs lap (Scene [moved] Nothing Nothing)
        `shouldBe` Map.fromList [("class", D.slotClass moved), ("style", slotStyle moved)]

    it "sin estar en la escena, su propio rectángulo" $
      D.slotAttrs lap (Scene [] Nothing Nothing)
        `shouldBe` Map.fromList [("class", D.slotClass lap), ("style", slotStyle lap)]

    it "la que se lleva sigue al puntero, y si ahí no se deja va marcada" $ do
      let held fits = Held (widgetId lap) 1 2 30 40 fits
      [ Map.lookup "class" (D.slotAttrs lap (Scene [lap] (Just (held f)) Nothing)) | f <- [True, False] ]
        `shouldBe` map Just ["widget-slot widget-slot--held", "widget-slot widget-slot--held widget-slot--blocked"]
      Map.lookup "style" (D.slotAttrs lap (Scene [lap] (Just (held True)) Nothing)) `shouldBe` Just (heldStyle (held True))

    it "otra cogida no cambia la suya" $
      D.slotAttrs lap (Scene [lap] (Just (Held (WidgetId "otra") 1 2 30 40 True)) Nothing)
        `shouldBe` D.slotAttrs lap (Scene [lap] Nothing Nothing)

historicalSpec :: Spec
historicalSpec = describe "Widgets.Historical.Helper" $ do
  describe "onlyEntity" $
    it "solo las filas de esa clasificación, en su orden" $
      property $ \ks ->
        let rows = zipWith statOf [1 ..] ks
         in H.onlyEntity DriverStat rows === filter ((== DriverStat) . hsEntity) rows
              .&&. length (H.onlyEntity DriverStat rows) + length (H.onlyEntity ConstructorStat rows) === length rows

  describe "pointsLabel" $
    it "sin el .0 que sobra; un medio punto, con su decimal" $
      map (\p -> H.pointsLabel (statOf 1 True) {hsPoints = p}) [393, 12.5, 0, -0.0]
        `shouldBe` ["393", "12.5", "0", "0"]

  describe "winsLabel y positionLabel" $ do
    it "sin dato, la raya y no un cero" $ do
      H.winsLabel (statOf 1 True) {hsWins = Nothing} `shouldBe` "—"
      H.positionLabel (statOf 1 True) {hsPosition = Nothing} `shouldBe` "—"

    it "con dato, el número entero, el cero incluido" $ do
      map (\w -> H.winsLabel (statOf 1 True) {hsWins = Just w}) [0, 7] `shouldBe` ["0", "7"]
      H.positionLabel (statOf 1 True) {hsPosition = Just 3} `shouldBe` "3"

-- | Una fila de piloto (@True@) o de constructor.
statOf :: Int -> Bool -> HistoricalStat
statOf n driver =
  HistoricalStat
    { hsEntity = if driver then DriverStat else ConstructorStat
    , hsCode = T.pack (show n), hsGivenName = "", hsFamilyName = ""
    , hsPoints = 0, hsWins = Nothing, hsPosition = Just n
    }

comparisonSpec :: Spec
comparisonSpec = describe "Widgets.Comparison.Helper" $ do
  describe "step" $ do
    it "una respuesta buena se enseña, haya lo que haya antes" $ do
      C.step (Got (comparisonN 2)) C.Loading `shouldBe` C.Loaded (comparisonN 2)
      C.step (Got (comparisonN 2)) C.Failed `shouldBe` C.Loaded (comparisonN 2)
      C.step (Got (comparisonN 2)) C.NotFound `shouldBe` C.Loaded (comparisonN 2)
      C.step (Got (comparisonN 2)) (C.Loaded (comparisonN 1)) `shouldBe` C.Loaded (comparisonN 2)

    it "un fallo o un 404 con una comparación en pantalla la conserva" $ do
      C.step NotFetched (C.Loaded (comparisonN 1)) `shouldBe` C.Loaded (comparisonN 1)
      C.step Absent (C.Loaded (comparisonN 1)) `shouldBe` C.Loaded (comparisonN 1)

    it "un fallo sin nada que conservar es Failed" $ do
      C.step NotFetched C.Loading `shouldBe` C.Failed
      C.step NotFetched C.Failed `shouldBe` C.Failed

    it "un 404 sin nada que conservar es NotFound" $ do
      C.step Absent C.Loading `shouldBe` C.NotFound
      C.step Absent C.Failed `shouldBe` C.NotFound

    it "tras cualquier serie de respuestas se enseña la última buena" $
      property stepsFrom

  describe "shownComparison" $
    it "tras una recarga fallida sigue señalando la comparación anterior" $ do
      let shown = foldl (flip C.step) C.Loading [Got (comparisonN 1), NotFetched]
      C.shownComparison shown `shouldBe` Just (comparisonN 1)
      C.shownComparison C.Failed `shouldBe` Nothing
      C.shownComparison C.NotFound `shouldBe` Nothing
      C.shownComparison C.Loading `shouldBe` Nothing

  describe "refreshOf" $
    it "un fallo o un 404 marcan LastFailed y una respuesta buena, Idle" $ do
      C.refreshOf NotFetched `shouldBe` C.LastFailed
      C.refreshOf Absent `shouldBe` C.LastFailed
      C.refreshOf (Got (comparisonN 1)) `shouldBe` C.Idle

  cardSpec
  gridSpec
  canvasSpec

-- | El lienzo: qué serie se pinta y qué alto mide.
canvasSpec :: Spec
canvasSpec = do
  let both = (comparisonN 0) {lcEntries = map leEntry [entryOf "16" True, entryOf "4" True]}
      refNoLap = (comparisonN 0) {lcEntries = map leEntry [entryOf "16" False, entryOf "4" True]}
      single = (comparisonN 0) {lcEntries = [leEntry (entryOf "16" True)]}
      view t b = C.View t b defaultAxis False Nothing channelsInOrder
      traced = filter chartTypeTraces chartTypesInOrder
      flat = filter (not . chartTypeTraces) chartTypesInOrder
  describe "seriesOf" $
    it "con los dos coches con vuelta, una Δ por frontera; si a uno le falta, ninguna" $ do
      length (C.seriesOf AgainstReference both) `shouldBe` 4
      C.seriesOf AgainstReference refNoLap `shouldBe` []

  describe "rowSeries" $
    it "en el tipo 1, la Δ del coche al frente; en las trazas, la del par" $ do
      let car n s = MkComparisonEntry n n "1:20.000" Nothing (Just s) Nothing []
          three = (comparisonN 0) {lcEntries = [car "16" (26, 27, 27), car "4" (26, 27.5, 27), car "1" (25, 27, 27)]}
          front f t = (view t AgainstReference) {C.vFront = f}
      C.rowSeries (front (Just "1") SectorDelta) three `shouldBe` [0, -1, -1, -1]
      C.rowSeries (front Nothing SectorDelta) three `shouldBe` [0, 0, 0.5, 0.5]
      C.rowSeries (front (Just "1") TelemetryTraces) three `shouldBe` [0, 0, 0.5, 0.5]

  describe "groupLaps" $
    it "las vueltas de los pilotos pedidos, en su orden; nada del ejemplo ni de un fallo" $ do
      let p3 = SessionKey 2026 21 Practice3
          e d = MkComparisonEntry d d "1:35.000" Nothing (Just (27, 32, 36)) Nothing []
          got o = Got (Sourced o Nothing Nothing ((comparisonN 0) {lcEntries = [e "LEC", e "NOR"]}))
      C.groupLaps p3 ["LEC"] (got (Just Fresh)) `shouldBe` [(p3, e "LEC")]
      C.groupLaps p3 ["LEC", "NOR"] (got Nothing) `shouldBe` [(p3, e "LEC"), (p3, e "NOR")]
      C.groupLaps p3 ["LEC"] (got (Just Sample)) `shouldBe` []
      C.groupLaps p3 ["LEC"] NotFetched `shouldBe` []

  describe "shownItemsOf" $
    it "la tarjeta, y detrás lo de los grupos en su orden: «VER, del grupo» y «VER · P1, del grupo»" $ do
      let p1 = SessionKey 2026 21 Practice1
          q  = SessionKey 2026 21 Qualifying
          e n d = MkComparisonEntry n d "1:35.000" Nothing (Just (27, 32, 36)) Nothing []
          c  = (comparisonN 0) {lcEntries = [e "16" "LEC", e "1" "NOR", e "3" "VER"]}
          g  = WithGroups ["16", "1", "3"] [AddedCar "3" "VER", AddedLap p1 "VER"] [AddedCar "44" "HAM"]
          items = C.shownItemsOf (Just q) g [(p1, e "1" "VER")] (C.Loaded c)
      map (\it -> (C.itKey it, C.itLegend it, C.itHead it, C.itGroup it, C.itCar it)) items
        `shouldBe` [ ("LEC", "LEC", "LEC", False, "16"), ("NOR", "NOR", "NOR", False, "1")
                   , ("VER", "VER, del grupo", "VER", True, "3")
                   , ("VER · 2026-21-FP1", "VER · P1, del grupo", "VER · P1", True, "") ]
      C.shownItemsOf (Just q) g [] (C.Loaded c) `shouldSatisfy` ((== 3) . length)
      C.shownItemsOf (Just q) g [] C.Loading `shouldBe` []
      map (C.leftOutLabel (Just q)) (AddedLap (SessionKey 2025 22 Practice1) "LEC" : wgLeftOut g) `shouldBe` ["LEC · P1 2025", "HAM"]

  describe "rowItems" $ do
    it "una fila por curva: en las trazas, la referencia y el primero de los demás; en el tipo 1, todas" $ do
      let e n d = MkComparisonEntry n d "1:35.000" Nothing (Just (27, 32, 36)) Nothing []
          it' k g = C.Item k k k g "" (e "" k)
          items = [it' "LEC" False, it' "NOR" False, it' "VER" False, it' "HAM" True, it' "LEC · P3" True]
      [ (t, map C.itKey (C.rowItems t False items)) | t <- [minBound .. maxBound] ]
        `shouldBe` [ (SectorDelta, ["LEC", "NOR", "VER", "HAM", "LEC · P3"]), (TelemetryTraces, ["LEC", "NOR"])
                   , (LapDeltaBars, ["LEC", "NOR"]) ]
      C.rowItems TelemetryTraces False [it' "LEC" False, it' "HAM" True] `shouldBe` [it' "LEC" False]

    it "con una sola gráfica que no es la velocidad, todos los coches de la tarjeta, sin los de los grupos" $ do
      let e n d = MkComparisonEntry n d "1:35.000" Nothing (Just (27, 32, 36)) Nothing []
          it' k g = C.Item k k k g "" (e "" k)
          items = [it' "LEC" False, it' "NOR" False, it' "VER" False, it' "RUS" False, it' "PIA" False, it' "HAM" True]
      map C.itKey (C.rowItems TelemetryTraces True items) `shouldBe` ["LEC", "NOR", "VER", "RUS", "PIA"]
      map C.itKey (C.rowItems SectorDelta True items) `shouldBe` map C.itKey items

  describe "edgeNotes" $
    it "la vuelta de otra sesión que se sale del eje de la que se ve: por dónde y su último valor" $ do
      let e d = MkComparisonEntry "16" d "1:35.000" Nothing (Just (27, 32, 36)) Nothing []
          p3  = SessionKey 2025 22 Qualifying
          nor = Curve (e "NOR") [0, -0.42, -0.91, -0.8] Front Nothing
          up  = Curve (e "LEC") [0, 3.5, 9.8, 14.8] Faint (Just p3)
          dn  = Curve (e "LEC") [0, -3, -6, -5] Faint (Just p3)
          near = Curve (e "LEC") [0, -0.1, -0.3, -0.2] Faint (Just p3)
      C.edgeNotes [nor, up] `shouldBe` [(True, 14.8)]
      C.edgeNotes [nor, dn, up] `shouldBe` [(False, -5), (True, 14.8)]
      C.edgeNotes [nor, near] `shouldBe` []
      C.edgeNotes [up] `shouldBe` []
      C.edgeNotes [nor, Curve (e "LEC") [0, 0.1, 0.2, 0.15] Faint (Just p3)] `shouldBe` []

  describe "rowHeightNow" $
    it "el alto de su modo si hay fronteras que nombrar; si no, o sin comparación, 0" $
      [ (m, C.rowHeightNow m (view SectorDelta AgainstReference) s) | m <- [minBound .. maxBound], s <- [C.Loaded both, C.Loaded refNoLap, C.Loading] ]
        `shouldBe` [ (m, h) | m <- [minBound .. maxBound], h <- [rowHeight m, 0, 0] ]

  describe "canvasDrawn" $ do
    it "sin trazas, el alto de la gráfica del tipo 1, haya lo que haya en la comparación" $
      [ C.canvasDrawn (view t b) (C.Loaded c) | t <- flat, b <- [AgainstReference, AgainstFastest], c <- [both, refNoLap, single] ]
        `shouldSatisfy` all (== Just chartHeight)

    it "con trazas y dos coches, el alto de sus canales" $
      [ C.canvasDrawn (view t AgainstReference) (C.Loaded both) | t <- traced ]
        `shouldBe` [ Just (tracesHeight (TraceRows (traceChannels t channelsInOrder))) | t <- traced ]

    it "con trazas: sin la vuelta de la referencia (contra ella) o con un solo coche, no hay lienzo" $
      [ (C.canvasDrawn (view t AgainstReference) (C.Loaded refNoLap), C.canvasDrawn (view t AgainstFastest) (C.Loaded single))
      | t <- traced ]
        `shouldSatisfy` all (== (Nothing, Nothing))

    it "contra el más rápido, la referencia sin vuelta no quita el lienzo" $
      [ isJust (C.canvasDrawn (view t AgainstFastest) (C.Loaded refNoLap)) | t <- traced ] `shouldSatisfy` and

    it "sin comparación, nunca" $
      [ C.canvasDrawn (view t b) s | t <- chartTypesInOrder, b <- [AgainstReference, AgainstFastest], s <- [C.Loading, C.Failed, C.NotFound] ]
        `shouldSatisfy` all (== Nothing)

-- | La parrilla de los selectores: por posición, en el orden en que llega.
gridSpec :: Spec
gridSpec = do
  describe "indexedGrid y carAt" $ do
    it "conserva el orden de llegada: la posición i es el coche i" $
      property $ \(Distinct ns) ->
        let g = map entryNumbered ns
         in Map.elems (C.indexedGrid g) === g .&&. map (C.carAt (C.indexedGrid g)) [0 .. length g - 1] === map (Just . deNumber) g

    it "una posición fuera de la parrilla no tiene coche" $
      property $ \(Distinct ns) (NonNegative k) ->
        C.carAt (C.indexedGrid (map entryNumbered ns)) (length ns + k) === Nothing

  describe "positionOf y positionFor" $ do
    it "positionOf es carAt al revés: cada número vuelve a su posición" $
      property $ \(Distinct ns) ->
        let idx = C.indexedGrid (map entryNumbered ns)
         in map (C.positionOf idx . T.pack . show) ns === map Just [0 .. length ns - 1]

    it "un coche que no está en la parrilla no mueve el selector; sin comparación, tampoco" $ do
      let idx = C.indexedGrid (map entryNumbered [1, 16, 44])
          shown = Just (comparisonN 0) {lcEntries = map leEntry [entryOf "16" True, entryOf "4" True]}
      [ C.positionFor (C.carOf 0) idx shown
        , C.positionFor (C.carOf 1) idx shown
        , C.positionFor (C.carOf 0) idx Nothing
        ]
        `shouldBe` [Just 1, Nothing, Nothing]

  describe "carOf" $
    it "el número del coche i de la comparación, la referencia el 0; fuera de ella, nada" $ do
      let c = (comparisonN 0) {lcEntries = map leEntry [entryOf "16" True, entryOf "4" False]}
      map (`C.carOf` c) [0, 1, 2] `shouldBe` [Just "16", Just "4", Nothing]

  describe "driverLabel" $
    it "número, acrónimo y equipo; sin equipo, sin el guion" $
      map C.driverLabel [MkDriverEntry "1" "NOR" "McLaren", MkDriverEntry "1" "NOR" ""]
        `shouldBe` ["1 · NOR — McLaren", "1 · NOR"]

-- | Números de coche distintos, como los de una parrilla.
newtype Distinct = Distinct [Int]
  deriving Show

instance Arbitrary Distinct where
  arbitrary = Distinct . nub . map getNonNegative <$> listOf arbitrary

entryNumbered :: Int -> DriverEntry
entryNumbered n = MkDriverEntry (T.pack (show n)) ("D" <> T.pack (show n)) ""

-- | Las reglas de la tarjeta con el directo.
cardSpec :: Spec
cardSpec = do
  describe "liveInput" $ do
    it "mientras se espera el retraso, nada, haya lo que haya" $
      property $ \(wait, shown) ->
        C.liveInput (Just wait) (pollWith (fromFeed raceTable <$ shownFlag shown) False False) === Nothing

    it "pasado el retraso, la fuente, la sesión y las filas de lo enseñado; sin nada enseñado, nada" $ do
      C.liveInput Nothing (pollWith (Just (fromFeed raceTable)) False False)
        `shouldBe` Just (Just Feed, liveSession raceTable, liveRows raceTable)
      C.liveInput Nothing (pollWith Nothing True False) `shouldBe` Nothing

  describe "notRunOf" $ do
    let empty = pollWith (Just (sourcedBy (Just FastF1) raceTable {liveRows = []})) False False
    it "con una sesión elegida y la tabla sin filas, sin correr; con filas o sin elegir, no" $
      [ C.notRunOf True Nothing empty
      , C.notRunOf True Nothing (pollWith (Just (fromFeed raceTable)) False False)
      , C.notRunOf False Nothing empty
      , C.notRunOf True Nothing pollIdle
      ]
        `shouldBe` [True, False, False, False]

    it "mientras se espera el retraso, nunca" $
      property $ \(chosen, wait) -> C.notRunOf chosen (Just wait) empty === False

  describe "liveFor" $
    it "solo Delta por sectores va en directo; los demás tipos pintan FastF1" $
      [ (t, C.liveFor following t) | t <- chartTypesInOrder ]
        `shouldBe` [ (t, if t == SectorDelta then following else Offline) | t <- chartTypesInOrder ]

  describe "gridFor" $ do
    it "en directo, los pilotos de las filas por número; sin directo, la parrilla de FastF1" $ do
      map deCode (C.gridFor (Just (Nothing, liveRows raceTable)) fastGrid) `shouldBe` ["NOR", "LEC"]
      C.gridFor Nothing fastGrid `shouldBe` fastGrid

  describe "liveEntriesFor" $ do
    let live = Just (liveSession raceTable, liveRows raceTable)
        rules = (Nothing, Nothing)
    it "en directo y con los dos coches, uno por coche y en su orden" $
      map (ceCar . leEntry) <$> C.liveEntriesFor live (Just "4", Just "16") FastestLap rules
        `shouldBe` Just ["4", "16"]

    it "sin directo o sin uno de los dos coches, nada" $
      [ C.liveEntriesFor Nothing (Just "4", Just "16") FastestLap rules
      , C.liveEntriesFor live (Just "4", Nothing) FastestLap rules
      , C.liveEntriesFor live (Nothing, Just "16") FastestLap rules
      ]
        `shouldBe` [Nothing, Nothing, Nothing]

  describe "markedRule" $ do
    it "con FastF1, la más rápida, sea cual sea la regla" $
      map (C.markedRule Nothing) [FastestLap, LastLap, PartLap 2] `shouldBe` replicate 3 FastestLap

    it "en directo, la regla si se ofrece; una parte que la sesión no tiene, la más rápida" $
      [ C.markedRule (Just (Just baseSession)) LastLap
      , C.markedRule (Just (Just baseSession)) (PartLap 2)
      , C.markedRule (Just (Just baseSession {siPart = Just 2})) (PartLap 2)
      ]
        `shouldBe` [LastLap, FastestLap, PartLap 2]

  describe "shownState" $ do
    it "con la comparación del directo, esa, sin muestras ni avisos" $
      C.shownState (Just [entryOf "16" True]) (C.Loaded (comparisonN 100))
        `shouldBe` C.Loaded (comparisonN 0) {lcEntries = [leEntry (entryOf "16" True)]}

    it "sin directo, lo que había" $
      map (C.shownState Nothing) states `shouldBe` states

  describe "shownGap" $ do
    let withGap = C.Loaded (comparisonN 100) {lcTelemetry = Just gap}
    it "solo los tipos con trazas dicen lo que falta de la telemetría" $
      [ (t, C.shownGap t withGap) | t <- chartTypesInOrder ]
        `shouldBe` [ (t, if chartTypeTraces t then Just gap else Nothing) | t <- chartTypesInOrder ]

    it "sin comparación, nada" $
      map (C.shownGap TelemetryTraces) [C.Loading, C.Failed, C.NotFound] `shouldBe` replicate 3 Nothing

  describe "dueGap" $ do
    -- 2026-11-07T00:40:05Z es el minuto 29 900 200 desde 1970 (date -u +%s, entre 60).
    it "toca el primer minuto después de su hora, si no se pidió ya por ella" $ do
      map (C.dueGap (Just gap, Nothing)) [29900199 .. 29900202] `shouldBe` [Nothing, Nothing, Just gap, Just gap]
      C.dueGap (Just gap, Just (tgRetryAt gap)) 29900202 `shouldBe` Nothing
      C.dueGap (Just gap, Just "2026-11-07T00:30:00Z") 29900202 `shouldBe` Just gap

    it "sin nada que falte, nunca" $
      property $ \(m, done) -> C.dueGap (Nothing, fmap T.pack done) m === Nothing

  describe "noLapNote" $ do
    it "en directo, el coche del directo sin sectores lleva aviso; el que los tiene, no" $ do
      isJust (C.noLapNote (Just [entryOf "16" False, entryOf "4" True]) C.Loading "16") `shouldBe` True
      C.noLapNote (Just [entryOf "16" False, entryOf "4" True]) C.Loading "4" `shouldBe` Nothing

    it "sin directo, el de la comparación de FastF1; sin comparación, ninguno" $ do
      let fast = C.Loaded (comparisonN 0) {lcEntries = map leEntry [entryOf "16" False, entryOf "4" True]}
      map (isJust . C.noLapNote Nothing fast) ["16", "4"] `shouldBe` [True, False]
      C.noLapNote Nothing C.Loading "16" `shouldBe` Nothing
  where
    following = Following Nothing (liveRows raceTable)
    fastGrid = [MkDriverEntry "1" "VER" "Red Bull Racing", MkDriverEntry "16" "LEC" "Ferrari"]
    gap = MkTelemetryGap 0.04 "2026-11-07T00:40:05Z"
    states = [C.Loading, C.Failed, C.NotFound, C.Loaded (comparisonN 3)]

-- | Un coche de la comparación del directo, con sus sectores o sin ellos.
entryOf :: T.Text -> Bool -> LiveEntry
entryOf car sectors =
  LiveEntry (MkComparisonEntry car car "1:20.000" Nothing (if sectors then Just (26, 27, 27) else Nothing) Nothing []) "1:20.000"

liveTimingSpec :: Spec
liveTimingSpec = describe "Widgets.LiveTiming.Helper.liveStateOf" $ do
  it "sin respuesta todavía, Loading" $
    LT.liveStateOf False pollIdle `shouldBe` LT.Loading

  it "un fallo sin nada que enseñar es Failed" $
    LT.liveStateOf False (pollWith Nothing True False) `shouldBe` LT.Failed

  it "un fallo con la tabla en pantalla la conserva" $
    rowsOf (LT.liveStateOf False (pollWith (Just (fromFeed raceTable)) True False))
      `shouldBe` Just (liveRows raceTable)

  it "un 404 sin nada que enseñar es NotFound; con la tabla en pantalla, la conserva" $ do
    LT.liveStateOf True (notFound (pollWith Nothing True False)) `shouldBe` LT.NotFound
    rowsOf (LT.liveStateOf True (notFound (pollWith (Just (sourcedBy (Just FastF1) raceTable)) True False)))
      `shouldBe` Just (liveRows raceTable)

  it "una tabla que llega sin filas se enseña vacía, no como cargando" $
    rowsOf (LT.liveStateOf False (pollWith (Just (fromFeed raceTable {liveRows = []})) False False))
      `shouldBe` Just []

  it "con una sesión elegida, sin filas es NotRun; con filas, la tabla" $ do
    LT.liveStateOf True (pollWith (Just (sourcedBy (Just FastF1) raceTable {liveRows = []})) False False)
      `shouldBe` LT.NotRun
    rowsOf (LT.liveStateOf True (pollWith (Just (sourcedBy (Just FastF1) raceTable)) False False))
      `shouldBe` Just (liveRows raceTable)

  it "una petición en vuelo no cambia lo que se enseña" $
    property $ \(shown, failed) ->
      let p = pollWith (fromFeed raceTable <$ shownFlag shown) failed
       in LT.liveStateOf False (p True) === LT.liveStateOf False (p False)

  it "liveViewOf: con diferido, la espera; un 404 sin nada se dice al momento" $ do
    LT.liveViewOf True 41 (Just 41) (pollWith Nothing False False) `shouldBe` LT.Waiting "En espera · diferido 0:41 · empieza en 41 s"
    LT.liveViewOf True 41 (Just 41) (notFound (pollWith Nothing True False)) `shouldBe` LT.NotFound
    LT.liveViewOf True 41 Nothing (pollWith Nothing True False) `shouldBe` LT.Failed

  it "liveViewOf: con diferido, un fallo sin nada llegado se dice al momento; con algo, la espera" $ do
    LT.liveViewOf False 41 (Just 41) (pollWith Nothing True False) `shouldBe` LT.Failed
    LT.liveViewOf False 41 (Just 41) (pollWith Nothing True True) `shouldBe` LT.Failed
    LT.liveViewOf False 41 (Just 20) (pollWith (Just (fromFeed raceTable)) True False)
      `shouldBe` LT.Waiting "En espera · diferido 0:41 · empieza en 20 s"

  it "hasTable: solo con la tabla, también sin filas" $ do
    map LT.hasTable [LT.Loading, LT.Failed, LT.NotRun, LT.NotFound, LT.Waiting "Diferido: 0:30"]
      `shouldBe` [False, False, False, False, False]
    LT.hasTable (LT.Loaded [] [] []) `shouldBe` True
    LT.hasTable (LT.liveStateOf False (pollWith (Just (fromFeed raceTable)) False False)) `shouldBe` True

tyreStrategySpec :: Spec
tyreStrategySpec = describe "Widgets.TyreStrategy.Helper.tyreStateOf" $ do
  it "sin respuesta todavía, Loading; un fallo sin nada, Failed" $ do
    TS.tyreStateOf False pollIdle `shouldBe` TS.Loading
    TS.tyreStateOf False (pollWith Nothing True False) `shouldBe` TS.Failed

  it "una tabla del feed se enseña con sus juegos" $
    setsOf (TS.tyreStateOf False (pollWith (Just (fromFeed raceTable)) False False))
      `shouldBe` Just (setRows raceTable)

  it "una tabla de otra fuente, o sin fuente, no tiene stints" $
    mapM_ (\src -> TS.tyreStateOf False (pollWith (Just (sourcedBy src raceTable)) False False)
                     `shouldBe` TS.NoStints)
          [Just OpenF1, Just FastF1, Nothing]

  it "con una sesión elegida, los juegos de cualquier fuente; sin filas, NotRun" $ do
    setsOf (TS.tyreStateOf True (pollWith (Just (sourcedBy (Just FastF1) raceTable)) False False))
      `shouldBe` Just (setRows raceTable)
    TS.tyreStateOf True (pollWith (Just (sourcedBy (Just FastF1) raceTable {liveRows = []})) False False)
      `shouldBe` TS.NotRun

  it "tyreViewOf: con diferido, la espera; un 404 sin nada se dice al momento" $ do
    TS.tyreViewOf True 41 (Just 41) (pollWith Nothing False False) `shouldBe` TS.Waiting "En espera · diferido 0:41 · empieza en 41 s"
    TS.tyreViewOf True 41 (Just 41) (notFound (pollWith Nothing True False)) `shouldBe` TS.NotFound

  it "tyreViewOf: con diferido, un fallo sin nada llegado se dice al momento; con algo, la espera" $ do
    TS.tyreViewOf False 41 (Just 41) (pollWith Nothing True False) `shouldBe` TS.Failed
    TS.tyreViewOf False 41 (Just 41) (pollWith Nothing True True) `shouldBe` TS.Failed
    TS.tyreViewOf False 41 (Just 20) (pollWith (Just (fromFeed raceTable)) True False)
      `shouldBe` TS.Waiting "En espera · diferido 0:41 · empieza en 20 s"

  it "un fallo con la tabla del feed en pantalla la conserva" $
    setsOf (TS.tyreStateOf False (pollWith (Just (fromFeed raceTable)) True False))
      `shouldBe` Just (setRows raceTable)

  it "un 404 sin nada que enseñar es NotFound; con la tabla en pantalla, la conserva" $ do
    TS.tyreStateOf True (notFound (pollWith Nothing True False)) `shouldBe` TS.NotFound
    setsOf (TS.tyreStateOf True (notFound (pollWith (Just (sourcedBy (Just FastF1) raceTable)) True False)))
      `shouldBe` Just (setRows raceTable)

  it "una petición en vuelo no cambia lo que se enseña" $
    property $ \(shown, failed) ->
      let p = pollWith (fromFeed raceTable <$ shownFlag shown) failed
       in TS.tyreStateOf False (p True) === TS.tyreStateOf False (p False)

liveSpec :: Spec
liveSpec = describe "Widgets.Live.Helper" $ do
  describe "sessionOf" $ do
    it "sin respuesta todavía no hay sesión" $
      sessionOf pollIdle `shouldBe` Nothing

    it "una tabla que no nombra su sesión se ve igual que no tener nada" $
      sessionOf (pollWith (Just (fromFeed raceTable {liveSession = Nothing})) False False)
        `shouldBe` Nothing

    it "la sesión de la tabla en pantalla, aunque la última recarga fallara" $
      sessionOf (pollWith (Just (fromFeed raceTable)) True False)
        `shouldBe` Just (sessionIn SessionStarted)

  describe "stateOf" $ do
    it "una sesión sin estado no tiene estado" $
      stateOf (pollWith (Just (fromFeed raceTable {liveSession = Just baseSession})) False False)
        `shouldBe` Nothing

    it "el estado de la sesión, con su procedencia" $
      stateOf (pollWith (Just (fromFeed raceTable)) False False)
        `shouldBe` Just (StateReading SessionStarted Heard)

  describe "indicatorOf" $ do
    it "rueda con la sesión en marcha" $
      runningFinalised (indicatorIn (Just SessionStarted)) `shouldBe` (True, False)

    it "con bandera roja o a cuadros no rueda" $ do
      runningFinalised (indicatorIn (Just SessionRedFlag)) `shouldBe` (False, False)
      runningFinalised (indicatorIn (Just SessionChequered)) `shouldBe` (False, False)

    it "finalizada, sin rodar" $
      runningFinalised (indicatorIn (Just SessionFinalised)) `shouldBe` (False, True)

    it "sin estado de sesión, ni rueda ni está finalizada" $
      runningFinalised (indicatorIn Nothing) `shouldBe` (False, False)

    it "un fallo con la tabla en pantalla sigue enseñándola y avisa del fallo" $ do
      let i = indicatorOf False (pollWith (Just (fromFeed raceTable)) True False)
      (indShown i, indFailed i) `shouldBe` (True, True)

    it "una sesión elegida ya corrida: con filas y sin rodar" $ do
      let finished = Just (fromFeed raceTable {liveSession = Just (sessionIn SessionFinalised)})
      indPast (indicatorOf True (pollWith finished False False)) `shouldBe` True
      indPast (indicatorOf False (pollWith finished False False)) `shouldBe` False

    it "sin filas (aún sin correr), rodando o sin nada en pantalla, no" $ do
      let shown t = pollWith (Just (fromFeed t)) False False
      indPast (indicatorOf True (shown raceTable {liveRows = []})) `shouldBe` False
      indPast (indicatorOf True (shown raceTable {liveSession = Just (sessionIn SessionStarted)})) `shouldBe` False
      indPast (indicatorOf True (pollWith Nothing False False)) `shouldBe` False

  describe "missingTitle" $ do
    it "con sesión elegida, un 404 y nada enseñado, el aviso con su clave" $
      missingTitle (readSessionKey "2026-30-r") (notFound (pollWith Nothing True False))
        `shouldBe` "Sesión no encontrada: 2026-30-R"

    it "vacío con la tabla en pantalla, sin 404 o sin sesión elegida" $ do
      missingTitle (readSessionKey "2026-30-R") (notFound (pollWith (Just (fromFeed raceTable)) True False))
        `shouldBe` ""
      missingTitle (readSessionKey "2026-30-R") (pollWith Nothing True False) `shouldBe` ""
      missingTitle Nothing (notFound (pollWith Nothing True False)) `shouldBe` ""

  describe "liveAside" $ do
    let chosen = readSessionKey "2026-20-R"
    it "con sesión elegida y el directo en carrera: gran premio, sesión y vuelta" $
      liveAside chosen (liveWith (sessionIn SessionStarted) {siLaps = Just (LapProgress 30 50)})
        `shouldBe` Just "Spanish Grand Prix · Race · vuelta 30/50"

    it "fuera de carrera, sin vuelta" $
      liveAside chosen (liveWith (sessionIn SessionStarted) {siName = "Qualifying"})
        `shouldBe` Just "Spanish Grand Prix · Qualifying"

    it "con bandera roja o a cuadros sigue avisando" $
      map (liveAside chosen . liveWith . sessionIn) [SessionRedFlag, SessionChequered]
        `shouldBe` replicate 2 (Just "Spanish Grand Prix · Race")

    it "nada sin sesión elegida, sin directo, por empezar, finalizada o sin estado" $
      [ liveAside Nothing (liveWith (sessionIn SessionStarted))
      , liveAside chosen pollIdle
      , liveAside chosen (liveWith (sessionIn SessionInactive))
      , liveAside chosen (liveWith (sessionIn SessionFinalised))
      , liveAside chosen (liveWith baseSession)
      ] `shouldBe` replicate 5 Nothing

-- | Comparaciones distintas entre sí, por el número de muestras.
comparisonN :: Int -> LapComparison
comparisonN n =
  MkLapComparison {lcEntries = [], lcSamples = n, lcNotice = "", lcTelemetry = Nothing, lcCut = Nothing}

-- | Lo que 'C.step' tiene que dejar tras la serie: la última buena; 'C.Failed' si hubo
-- respuestas y ninguna buena; 'C.Loading' si no hubo ninguna.
stepsFrom :: [Maybe Int] -> Property
stepsFrom rs = foldl (flip C.step) C.Loading (map (maybe NotFetched (Got . comparisonN)) rs) === expected
  where
    expected = case [n | Just n <- rs] of
      [] | null rs   -> C.Loading
         | otherwise -> C.Failed
      ns             -> C.Loaded (comparisonN (last ns))

-- | El refresco con lo que se enseña, si la última falló y si hay una en vuelo.
pollWith :: Maybe (Sourced LiveTable) -> Bool -> Bool -> Poll (Sourced LiveTable)
pollWith shown failed inFlight =
  pollIdle {pollShown = shown, pollLastFailed = failed, pollInFlight = inFlight}

-- | El directo enseñando la carrera con esa sesión.
liveWith :: SessionInfo -> Poll (Sourced LiveTable)
liveWith s = pollWith (Just (fromFeed raceTable {liveSession = Just s})) False False

-- | El refresco tras un @404@ sin respuesta buena después.
notFound :: Poll a -> Poll a
notFound p = p {pollNotFound = True}

shownFlag :: Bool -> Maybe ()
shownFlag b = if b then Just () else Nothing

fromFeed :: LiveTable -> Sourced LiveTable
fromFeed = sourcedBy (Just Feed)

sourcedBy :: Maybe Source -> LiveTable -> Sourced LiveTable
sourcedBy src t =
  Sourced {srcOrigin = Nothing, srcSource = src, srcFetchedAt = Nothing, srcValue = t}

-- | Una carrera en marcha con dos coches.
raceTable :: LiveTable
raceTable =
  LiveTable
    { liveSession = Just (sessionIn SessionStarted)
    , liveRows    = [ emptyLiveRow {ltPosition = 1, ltCar = "16", ltDriver = "LEC"}
                    , emptyLiveRow {ltPosition = 2, ltCar = "4", ltDriver = "NOR"} ]
    , liveStints  = []
    , liveNext    = NextUnknown
    }

-- | Una carrera sin estado ni nada más que su nombre: de ella salen las demás.
baseSession :: SessionInfo
baseSession =
  SessionInfo
    { siType       = "Race"
    , siName       = "Race"
    , siMeeting    = "Spanish Grand Prix"
    , siCircuit    = Nothing
    , siState      = Nothing
    , siLaps       = Nothing
    , siClock      = Nothing
    , siPart       = Nothing
    , siTrack      = Nothing
    , siCountdown  = Nothing
    , siStart      = Nothing
    , siEntries    = []
    , siCutOffTime = Nothing
    }

sessionIn :: SessionState -> SessionInfo
sessionIn st = baseSession {siState = Just (StateReading st Heard)}

indicatorIn :: Maybe SessionState -> Indicator
indicatorIn st =
  indicatorOf False (pollWith (Just (fromFeed raceTable {liveSession = Just session})) False False)
  where
    session = baseSession {siState = (`StateReading` Heard) <$> st}

runningFinalised :: Indicator -> (Bool, Bool)
runningFinalised i = (indRunning i, indFinalised i)

rowsOf :: LT.LiveState -> Maybe [LiveTimingRow]
rowsOf (LT.Loaded rows _ _) = Just rows
rowsOf _                    = Nothing

setsOf :: TS.TyreState -> Maybe [SetRow]
setsOf (TS.Loaded _ rows) = Just rows
setsOf _                  = Nothing
