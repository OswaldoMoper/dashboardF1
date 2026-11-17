module Main (main) where

import           Common.Origin               (Source (..), Sourced (..))
import           Common.Shown                (Indicator (..), Poll (..),
                                              pollIdle)
import           Common.Types                (LapComparison (..),
                                              LiveTable (..),
                                              LiveTimingRow (..),
                                              SessionInfo (..),
                                              SessionState (..),
                                              StateBasis (..),
                                              StateReading (..), UpNext (..),
                                              emptyLiveRow)
import           Common.TyreStrategy         (SetRow, setRows)
import           Test.Hspec
import           Test.QuickCheck

import qualified Widgets.Comparison.Helper   as C
import           Widgets.Live.Helper         (indicatorOf, sessionOf, stateOf)
import qualified Widgets.LiveTiming.Helper   as LT
import qualified Widgets.TyreStrategy.Helper as TS

main :: IO ()
main = hspec $ do
  comparisonSpec
  liveTimingSpec
  tyreStrategySpec
  liveSpec

comparisonSpec :: Spec
comparisonSpec = describe "Widgets.Comparison.Helper" $ do
  describe "step" $ do
    it "una respuesta buena se enseña, haya lo que haya antes" $ do
      C.step (Just (comparisonN 2)) C.Loading `shouldBe` C.Loaded (comparisonN 2)
      C.step (Just (comparisonN 2)) C.Failed `shouldBe` C.Loaded (comparisonN 2)
      C.step (Just (comparisonN 2)) (C.Loaded (comparisonN 1)) `shouldBe` C.Loaded (comparisonN 2)

    it "un fallo con una comparación en pantalla la conserva" $
      C.step Nothing (C.Loaded (comparisonN 1)) `shouldBe` C.Loaded (comparisonN 1)

    it "un fallo sin nada que conservar es Failed" $ do
      C.step Nothing C.Loading `shouldBe` C.Failed
      C.step Nothing C.Failed `shouldBe` C.Failed

    it "tras cualquier serie de respuestas se enseña la última buena" $
      property stepsFrom

  describe "shownComparison" $
    it "tras una recarga fallida sigue señalando la comparación anterior" $ do
      let shown = foldl (flip C.step) C.Loading [Just (comparisonN 1), Nothing]
      C.shownComparison shown `shouldBe` Just (comparisonN 1)
      C.shownComparison C.Failed `shouldBe` Nothing
      C.shownComparison C.Loading `shouldBe` Nothing

  describe "refreshOf" $
    it "un fallo marca LastFailed y una respuesta buena, Idle" $ do
      C.refreshOf Nothing `shouldBe` C.LastFailed
      C.refreshOf (Just (comparisonN 1)) `shouldBe` C.Idle

liveTimingSpec :: Spec
liveTimingSpec = describe "Widgets.LiveTiming.Helper.liveStateOf" $ do
  it "sin respuesta todavía, Loading" $
    LT.liveStateOf pollIdle `shouldBe` LT.Loading

  it "un fallo sin nada que enseñar es Failed" $
    LT.liveStateOf (pollWith Nothing True False) `shouldBe` LT.Failed

  it "un fallo con la tabla en pantalla la conserva" $
    rowsOf (LT.liveStateOf (pollWith (Just (fromFeed raceTable)) True False))
      `shouldBe` Just (liveRows raceTable)

  it "una tabla que llega sin filas se enseña vacía, no como cargando" $
    rowsOf (LT.liveStateOf (pollWith (Just (fromFeed raceTable {liveRows = []})) False False))
      `shouldBe` Just []

  it "una petición en vuelo no cambia lo que se enseña" $
    property $ \(shown, failed) ->
      let p = pollWith (fromFeed raceTable <$ shownFlag shown) failed
       in LT.liveStateOf (p True) === LT.liveStateOf (p False)

tyreStrategySpec :: Spec
tyreStrategySpec = describe "Widgets.TyreStrategy.Helper.tyreStateOf" $ do
  it "sin respuesta todavía, Loading; un fallo sin nada, Failed" $ do
    TS.tyreStateOf pollIdle `shouldBe` TS.Loading
    TS.tyreStateOf (pollWith Nothing True False) `shouldBe` TS.Failed

  it "una tabla del feed se enseña con sus juegos" $
    setsOf (TS.tyreStateOf (pollWith (Just (fromFeed raceTable)) False False))
      `shouldBe` Just (setRows raceTable)

  it "una tabla de otra fuente, o sin fuente, no tiene stints" $
    mapM_ (\src -> TS.tyreStateOf (pollWith (Just (sourcedBy src raceTable)) False False)
                     `shouldBe` TS.NoStints)
          [Just OpenF1, Just FastF1, Nothing]

  it "un fallo con la tabla del feed en pantalla la conserva" $
    setsOf (TS.tyreStateOf (pollWith (Just (fromFeed raceTable)) True False))
      `shouldBe` Just (setRows raceTable)

  it "una petición en vuelo no cambia lo que se enseña" $
    property $ \(shown, failed) ->
      let p = pollWith (fromFeed raceTable <$ shownFlag shown) failed
       in TS.tyreStateOf (p True) === TS.tyreStateOf (p False)

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
      let i = indicatorOf (pollWith (Just (fromFeed raceTable)) True False)
      (indShown i, indFailed i) `shouldBe` (True, True)

-- | Comparaciones distintas entre sí, por el número de muestras.
comparisonN :: Int -> LapComparison
comparisonN n =
  MkLapComparison {lcEntries = [], lcSamples = n, lcNotice = "", lcTelemetry = Nothing}

-- | Lo que 'C.step' tiene que dejar tras la serie: la última buena; 'C.Failed' si hubo
-- respuestas y ninguna buena; 'C.Loading' si no hubo ninguna.
stepsFrom :: [Maybe Int] -> Property
stepsFrom rs = foldl (flip C.step) C.Loading (map (fmap comparisonN) rs) === expected
  where
    expected = case [n | Just n <- rs] of
      [] | null rs   -> C.Loading
         | otherwise -> C.Failed
      ns             -> C.Loaded (comparisonN (last ns))

-- | El refresco con lo que se enseña, si la última falló y si hay una en vuelo.
pollWith :: Maybe (Sourced LiveTable) -> Bool -> Bool -> Poll (Sourced LiveTable)
pollWith shown failed inFlight =
  pollIdle {pollShown = shown, pollLastFailed = failed, pollInFlight = inFlight}

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
  indicatorOf (pollWith (Just (fromFeed raceTable {liveSession = Just session})) False False)
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
