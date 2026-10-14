-- | Lo que Lap Comparison calcula con los datos de cada piloto, sin pintar nada: la Δ
-- en las fronteras contra la base que elija el usuario, y la X de cada muestra de
-- las trazas en el eje elegido.
module Common.Comparison
  ( Sectors
  , frontierTimes
  , Baseline (..)
  , baselinesInOrder
  , baselineLabel
  , baselineRole
  , baselineKey
  , baselineFromKey
  , baseIndex
  , deltasAgainst
  , Axis (..)
  , axesInOrder
  , defaultAxis
  , axisLabel
  , axisNotice
  , LapGeometry (..)
  , axisXs
  , anchored
    -- * Lo que pinta el par de hoy
  , Pair (..)
  , pairWith
  , lapShown
  , missingReference
  , noLapFor
    -- * La vuelta del directo
  , LapChoice (..)
  , lapChoicesOffered
  , LiveEntry (..)
  , liveComparison
  , liveDrivers
  , comparisonIsLive
  , LiveCard (..)
  , liveCardStep
  , liveCardRows
  , liveLapLines
  , liveMissingReference
  , liveNoLapFor
  , endedNotice
  , keepChosen
  , leadingPair
    -- * El tipo de gráfica
  , ChartType (..)
  , chartTypesInOrder
  , defaultChartType
  , chartTypeLabel
  , chartTypeReady
  , chartTypeKey
  , chartTypeFromKey
  , chartTypeTraces
  , axisKey
  , axisFromKey
  , deltaFormula
  ) where

import           Common.Origin (Source (..))
import           Common.Types  (ComparisonEntry (..), DriverEntry (..),
                                LapComparison (..), LiveTimingRow (..),
                                SessionInfo (..), SessionState (..),
                                StateReading (..), lapSeconds, partLabel,
                                sessionIsLive)
import           Control.Monad (join)
import           Data.List     (find, minimumBy, sortOn)
import           Data.Maybe    (fromMaybe, isJust, isNothing, listToMaybe)
import           Data.Ord      (comparing)
import           Data.Text     (Text)
import qualified Data.Text     as T
import           Text.Read     (readMaybe)

-- | Los tres tiempos de sector de una vuelta, en segundos.
type Sectors = (Double, Double, Double)

-- | El tiempo acumulado en las cuatro fronteras: Inicio, S1, S2 y S3.
frontierTimes :: Sectors -> [Double]
frontierTimes (s1, s2, s3) = [0, s1, s1 + s2, s1 + s2 + s3]

-- | Contra quién se mide la Δ: la referencia (el primero de la lista), o el más
-- rápido de los que se comparan.
data Baseline = AgainstReference | AgainstFastest
  deriving stock (Eq, Show, Enum, Bounded)

-- | Las bases en el orden del desplegable «Δ contra».
baselinesInOrder :: [Baseline]
baselinesInOrder = [minBound .. maxBound]

-- | El nombre de la base en el desplegable.
baselineLabel :: Baseline -> Text
baselineLabel AgainstReference = "Referencia"
baselineLabel AgainstFastest   = "Más rápido"

-- | Cómo se nombra la base en la leyenda, entre paréntesis tras el piloto.
baselineRole :: Baseline -> Text
baselineRole AgainstReference = "referencia"
baselineRole AgainstFastest   = "más rápido"

-- | El @value@ de cada opción del desplegable.
baselineKey :: Baseline -> Text
baselineKey AgainstReference = "reference"
baselineKey AgainstFastest   = "fastest"

-- | 'baselineKey' al revés.
baselineFromKey :: Text -> Maybe Baseline
baselineFromKey k = lookup k [(baselineKey b, b) | b <- baselinesInOrder]

-- | Qué piloto es la base, por su posición: la referencia si tiene sus sectores, o
-- el más rápido de los que los tienen (un empate se lo queda el primero).
-- 'Nothing' si la base no tiene sectores.
baseIndex :: Baseline -> [Maybe Sectors] -> Maybe Int
baseIndex AgainstReference (Just _ : _) = Just 0
baseIndex AgainstReference _            = Nothing
baseIndex AgainstFastest entries =
  case [(i, s) | (i, Just s) <- zip [0 ..] entries] of
    [] -> Nothing
    xs -> Just (fst (minimumBy (comparing (lapOf . snd)) xs))
  where
    lapOf (s1, s2, s3) = s1 + s2 + s3

-- | La Δ de cada piloto en las cuatro fronteras, __comparado − base__ (positivo = va
-- por detrás), en el orden de entrada; la base es la de 'baseIndex'. Un piloto sin
-- sectores da @[]@, y todos dan @[]@ si la base no los tiene.
deltasAgainst :: Baseline -> [Maybe Sectors] -> [[Double]]
deltasAgainst baseline entries =
  case join . listToMaybe . flip drop entries =<< baseIndex baseline entries of
    Nothing -> map (const []) entries
    Just b  -> map (maybe [] (\s -> zipWith (-) (frontierTimes s) (frontierTimes b))) entries

-- | El eje X de las trazas.
data Axis = AxisDistance | AxisFraction | AxisTime | AxisSectors
  deriving stock (Eq, Show, Enum, Bounded)

-- | Los ejes en el orden del desplegable.
axesInOrder :: [Axis]
axesInOrder = [minBound .. maxBound]

-- | El eje con el que abre la tarjeta.
defaultAxis :: Axis
defaultAxis = AxisTime

-- | El nombre del eje en el desplegable.
axisLabel :: Axis -> Text
axisLabel AxisDistance = "Distancia"
axisLabel AxisFraction = "Fracción de vuelta"
axisLabel AxisTime     = "Tiempo"
axisLabel AxisSectors  = "Sectores"

-- | El aviso que va siempre bajo la leyenda: qué no es exacto en ese eje.
axisNotice :: Axis -> Text
axisNotice AxisDistance = "La distancia la integra FastF1 desde la velocidad: cada coche va en su escala."
axisNotice AxisFraction =
  "Cada coche dividido por su propia distancia: la misma fracción puede no ser el mismo punto de la pista."
axisNotice AxisTime     = "Segundos desde la línea: el coche más rápido llega antes a cada curva."
axisNotice AxisSectors  = "Estirado para que S1 y S2 coincidan: dentro de cada sector, aproximado."

-- | Lo que la vuelta de un coche aporta a los ejes: su distancia total y dónde cruzó
-- S1 y S2, en metros. Las fronteras vienen calculadas con la vuelta completa.
data LapGeometry = LapGeometry
  { lgTotal     :: Double
  , lgFrontiers :: (Double, Double)
  }
  deriving stock (Eq, Show)

-- | La X de cada muestra (segundos y metros desde la línea) de un coche en el eje
-- elegido; el segundo 'LapGeometry' es el de la referencia, y solo cuenta en
-- 'AxisSectors'. Con una distancia total que no sea positiva, la fracción es 0.
axisXs :: Axis -> LapGeometry -> LapGeometry -> [(Double, Double)] -> [Double]
axisXs AxisTime _ _       = map fst
axisXs AxisDistance _ _   = map snd
axisXs AxisFraction car _ = map (fractionOf car . snd)
axisXs AxisSectors car ref =
  map (anchored (frontierFractions car) (frontierFractions ref) . fractionOf car . snd)

fractionOf :: LapGeometry -> Double -> Double
fractionOf lap d
  | lgTotal lap > 0 = d / lgTotal lap
  | otherwise       = 0

frontierFractions :: LapGeometry -> (Double, Double)
frontierFractions lap = (fractionOf lap s1, fractionOf lap s2)
  where
    (s1, s2) = lgFrontiers lap

-- | Una fracción de vuelta de un coche, llevada por tramos a las fronteras de la
-- referencia: las fronteras S1 y S2 del coche (en fracción de vuelta) caen en las de
-- la referencia, y entre ellas se estira en línea recta; 0 y 1 no se mueven. Con unas
-- fronteras del coche que no cumplan @0 < s1 < s2 < 1@, devuelve la fracción tal cual.
anchored :: (Double, Double) -> (Double, Double) -> Double -> Double
anchored (a1, a2) (b1, b2) f
  | not (0 < a1 && a1 < a2 && a2 < 1) = f
  | f <= a1   = f / a1 * b1
  | f <= a2   = b1 + (f - a1) / (a2 - a1) * (b2 - b1)
  | otherwise = b2 + (f - a2) / (1 - a2) * (1 - b2)

-- | El par que pinta la tarjeta con una base: la base (la línea del cero), el otro
-- coche y su Δ contra ella en las cuatro fronteras.
data Pair = Pair
  { pairBase  :: ComparisonEntry
  , pairOther :: ComparisonEntry
  , pairDelta :: [Double]  -- ^ @[]@ si a alguno de los dos le faltan los sectores.
  }
  deriving stock (Eq, Show)

-- | El par de los dos primeros coches con la base elegida ('baseIndex'). Si la base
-- no se puede elegir —ninguno tiene vuelta, o la referencia no la tiene— la base es
-- la referencia. 'Nothing' sin dos coches.
pairWith :: Baseline -> LapComparison -> Maybe Pair
pairWith baseline c =
  case lcEntries c of
    ref : other : _ ->
      let sectors        = [ceSectors ref, ceSectors other]
          (dRef, dOther) = case deltasAgainst baseline sectors of
            [a, b] -> (a, b)
            _      -> ([], [])
       in Just $
            if baseIndex baseline sectors == Just 1
              then Pair other ref dRef
              else Pair ref other dOther
    _ -> Nothing

-- | El tiempo de vuelta de un coche como se pinta: @«sin vuelta»@ si no tiene sus
-- tres sectores.
lapShown :: ComparisonEntry -> Text
lapShown e
  | isNothing (ceSectors e) = "sin vuelta"
  | otherwise               = ceLap e

-- | El aviso que sustituye a la gráfica cuando la Δ va contra la referencia y la
-- referencia no tiene vuelta; 'Nothing' en cualquier otro caso. Contra el más rápido
-- no hay aviso: la base es el más rápido de los que tienen vuelta.
missingReference :: Baseline -> LapComparison -> Maybe Text
missingReference AgainstFastest _ = Nothing
missingReference AgainstReference c =
  case lcEntries c of
    (ref : _) | isNothing (ceSectors ref) -> Just (noLapNote ref <> ": elige otra referencia.")
    _ -> Nothing

-- | @«LEC no tiene vuelta en esta sesión»@: el aviso de un coche sin vuelta.
noLapNote :: ComparisonEntry -> Text
noLapNote e = ceDriver e <> " no tiene vuelta en esta sesión"

-- | El aviso de un coche, por su número, si en la comparación aparece sin vuelta;
-- 'Nothing' si la tiene o no aparece.
noLapFor :: Text -> LapComparison -> Maybe Text
noLapFor car c =
  noLapNote <$> find (\e -> ceCar e == car && isNothing (ceSectors e)) (lcEntries c)

-- | Qué vuelta de un coche se compara en directo: la más rápida de toda la sesión, la
-- última, o la más rápida de una parte de la clasificación, de 1 en adelante.
data LapChoice = FastestLap | LastLap | PartLap Int
  deriving stock (Eq, Show)

-- | Las vueltas que se ofrecen: la más rápida y la última, y en una clasificación cada
-- parte desde que empieza.
lapChoicesOffered :: Maybe SessionInfo -> [LapChoice]
lapChoicesOffered session =
  FastestLap : LastLap : maybe [] (\n -> map PartLap [1 .. n]) (siPart =<< session)

-- | Un coche de la comparación en directo y su tiempo como se pinta, que solo en directo
-- dice por qué no hay barras: @«1:33.100 · sin sectores»@ o @«sin vuelta en Q2»@.
data LiveEntry = LiveEntry
  { leEntry :: ComparisonEntry
  , leShown :: Text
  }
  deriving stock (Eq, Show)

-- | Los coches pedidos (número y vuelta), en el orden pedido, con lo que traen las filas
-- del directo. Un coche que no está en las filas sale «sin vuelta», con su número por
-- nombre.
liveComparison :: Maybe SessionInfo -> [LiveTimingRow] -> [(Text, LapChoice)] -> [LiveEntry]
liveComparison session rows = map entryOf
  where
    entryOf (car, choice) = case find ((== car) . ltCar) rows of
      Just r  -> liveEntry session r choice
      Nothing -> LiveEntry (MkComparisonEntry car car "" Nothing Nothing Nothing []) "sin vuelta"

liveEntry :: Maybe SessionInfo -> LiveTimingRow -> LapChoice -> LiveEntry
liveEntry session r choice =
  case (lapSeconds lap, sectorsFrom sectors) of
    (Nothing, _)      -> LiveEntry (entry "" Nothing) noLap
    (Just _, Nothing) -> LiveEntry (entry lap Nothing) (lap <> " · sin sectores")
    (Just _, Just s)  -> LiveEntry (entry lap (Just s)) lap
  where
    (lap, sectors) = case choice of
      FastestLap -> (ltBestLap r, ltBestSectors r)
      LastLap    -> (ltLastLap r, ltLastSectors r)
      PartLap n  -> (fromMaybe "" (nth n (ltPartBests r)), fromMaybe [] (nth n (ltPartBestSectors r)))
    part = case choice of
      PartLap n -> (`partLabel` n) <$> session
      _         -> Nothing
    noLap = maybe "sin vuelta" ("sin vuelta en " <>) part
    entry l s = MkComparisonEntry (ltCar r) (ltDriver r) l part s Nothing []
    nth n xs
      | n >= 1    = listToMaybe (drop (n - 1) xs)
      | otherwise = Nothing

-- | Los tres sectores en segundos, si los tres se leen.
sectorsFrom :: [Text] -> Maybe Sectors
sectorsFrom [a, b, c] = (,,) <$> lapSeconds a <*> lapSeconds b <*> lapSeconds c
sectorsFrom _         = Nothing

-- | Los pilotos del directo para los desplegables, por número de coche de menor a mayor.
-- Una fila sin número —o con uno que no se lee— no entra.
liveDrivers :: [LiveTimingRow] -> [DriverEntry]
liveDrivers rows =
  map snd $ sortOn fst
    [ (n, MkDriverEntry (ltCar r) (ltDriver r) (ltTeam r))
    | r <- rows, Just n <- [readMaybe (T.unpack (ltCar r)) :: Maybe Int] ]

-- | Si Lap Comparison va con el directo: lo sirve el feed y su sesión empezó y no ha
-- finalizado. Un estado desconocido, o ninguno, cuenta como directo (el criterio de
-- 'sessionIsLive'); «anunciada sin empezar» no.
comparisonIsLive :: Maybe Source -> Maybe SessionInfo -> Bool
comparisonIsLive (Just Feed) session =
  case srState <$> (siState =<< session) of
    Just SessionInactive -> False
    Just s               -> sessionIsLive s
    Nothing              -> True
comparisonIsLive _ _ = False

-- | Qué hace la tarjeta con el directo: nunca lo vio (pinta FastF1); lo sigue; lo
-- congela porque dejó de venir del feed con la sesión sin acabar; o la sesión acabó y
-- se queda con lo último. Las dos últimas guardan la sesión y las filas de la última
-- foto en vivo.
data LiveCard
  = Offline
  | Following (Maybe SessionInfo) [LiveTimingRow]
  | Frozen (Maybe SessionInfo) [LiveTimingRow]
  | Ended (Maybe SessionInfo) [LiveTimingRow]
  deriving stock (Eq, Show)

-- | El paso con cada directo que llega (la fuente, la sesión y las filas). En vivo
-- ('comparisonIsLive') se sigue; si no, lo que había se queda: acabado si la sesión dice
-- «finalizada» o ya anuncia la siguiente, congelado si no. Solo una sesión en vivo saca
-- de 'Ended'.
liveCardStep :: Maybe Source -> Maybe SessionInfo -> [LiveTimingRow] -> LiveCard -> LiveCard
liveCardStep src session rows prev
  | comparisonIsLive src session = Following session rows
  | otherwise = case prev of
      Following s r -> leave s r
      Frozen s r    -> leave s r
      other         -> other
  where
    leave s r
      | over      = Ended s r
      | otherwise = Frozen s r
    over = (srState <$> (siState =<< session)) `elem` map Just [SessionFinalised, SessionInactive]

-- | La sesión y las filas que se pintan, si la tarjeta va con el directo.
liveCardRows :: LiveCard -> Maybe (Maybe SessionInfo, [LiveTimingRow])
liveCardRows Offline         = Nothing
liveCardRows (Following s r) = Just (s, r)
liveCardRows (Frozen s r)    = Just (s, r)
liveCardRows (Ended s r)     = Just (s, r)

-- | El tiempo de un coche en dos líneas: con tiempo y sin sectores, el tiempo y debajo
-- @«sin sectores»@; en otro caso, su texto y nada debajo.
liveLapLines :: LiveEntry -> (Text, Maybe Text)
liveLapLines (LiveEntry e shown)
  | not (T.null (ceLap e)) && isNothing (ceSectors e) = (ceLap e, Just "sin sectores")
  | otherwise                                         = (shown, Nothing)

-- | 'missingReference' en directo: @«LEC: 1:33.100 · sin sectores. Elige otra
-- referencia.»@.
liveMissingReference :: Baseline -> [LiveEntry] -> Maybe Text
liveMissingReference AgainstFastest _ = Nothing
liveMissingReference AgainstReference es =
  case es of
    (ref : _) | isNothing (ceSectors (leEntry ref)) -> Just (liveNote ref <> ". Elige otra referencia.")
    _ -> Nothing

-- | 'noLapFor' en directo: @«LEC: 1:33.100 · sin sectores»@.
liveNoLapFor :: Text -> [LiveEntry] -> Maybe Text
liveNoLapFor car es =
  liveNote <$> find (\le -> ceCar (leEntry le) == car && isNothing (ceSectors (leEntry le))) es

liveNote :: LiveEntry -> Text
liveNote le = ceDriver (leEntry le) <> ": " <> leShown le

-- | El aviso sobre la gráfica cuando la sesión acabó ('Ended').
endedNotice :: Text
endedNotice = "Sesión acabada: lo último del directo"

-- | P1 y P2 del directo (por posición; las filas sin número no cuentan), el par con el
-- que abre la tarjeta si la página se abre ya en directo. 'Nothing' sin dos coches.
leadingPair :: [LiveTimingRow] -> Maybe (Text, Text)
leadingPair rows =
  case map ltCar (sortOn ltPosition (filter numbered rows)) of
    p1 : p2 : _ -> Just (p1, p2)
    _           -> Nothing
  where
    numbered r = isJust (readMaybe (T.unpack (ltCar r)) :: Maybe Int)

-- | Los dos coches elegidos (referencia y otro) en una lista de números nueva: el que
-- está se queda; el que no, pasa al primero de la lista que no sea el otro.
keepChosen :: [Text] -> (Text, Text) -> (Maybe Text, Maybe Text)
keepChosen cars (r, o) = (r', pick o (maybe [] pure r'))
  where
    r' = pick r [o]
    pick c avoid
      | c `elem` cars = Just c
      | otherwise     = find (`notElem` avoid) cars

-- | El tipo de gráfica de Lap Comparison, elegido en el título.
data ChartType = SectorDelta | LapSpeedTrace | TelemetryTraces | LapDeltaBars
  deriving stock (Eq, Show, Enum, Bounded)

-- | Los tipos en el orden del desplegable.
chartTypesInOrder :: [ChartType]
chartTypesInOrder = [minBound .. maxBound]

-- | El tipo con el que abre la tarjeta.
defaultChartType :: ChartType
defaultChartType = SectorDelta

-- | El nombre del tipo en el desplegable.
chartTypeLabel :: ChartType -> Text
chartTypeLabel SectorDelta     = "Delta por sectores"
chartTypeLabel LapSpeedTrace   = "Lap Speed Trace"
chartTypeLabel TelemetryTraces = "Telemetría comparativa"
chartTypeLabel LapDeltaBars    = "Lap Delta"

-- | Si el tipo ya se puede elegir; los demás salen en gris en el desplegable.
chartTypeReady :: ChartType -> Bool
chartTypeReady SectorDelta     = True
chartTypeReady LapSpeedTrace   = True
chartTypeReady TelemetryTraces = True
chartTypeReady _               = False

-- | El @value@ de cada opción del desplegable.
chartTypeKey :: ChartType -> Text
chartTypeKey SectorDelta     = "sector-delta"
chartTypeKey LapSpeedTrace   = "lap-speed-trace"
chartTypeKey TelemetryTraces = "telemetry"
chartTypeKey LapDeltaBars    = "lap-delta"

-- | 'chartTypeKey' al revés.
chartTypeFromKey :: Text -> Maybe ChartType
chartTypeFromKey k = lookup k [(chartTypeKey t, t) | t <- chartTypesInOrder]

-- | Si el tipo pinta trazas y pide muestras al servidor.
chartTypeTraces :: ChartType -> Bool
chartTypeTraces = (`elem` [LapSpeedTrace, TelemetryTraces, LapDeltaBars])

-- | El @value@ de cada opción del desplegable del eje.
axisKey :: Axis -> Text
axisKey AxisDistance = "distance"
axisKey AxisFraction = "fraction"
axisKey AxisTime     = "time"
axisKey AxisSectors  = "sectors"

-- | 'axisKey' al revés.
axisFromKey :: Text -> Maybe Axis
axisFromKey k = lookup k [(axisKey a, a) | a <- axesInOrder]

-- | Qué resta la Δ de un par: @«NOR − LEC»@, el otro coche menos la base.
deltaFormula :: Pair -> Text
deltaFormula p = ceDriver (pairOther p) <> " − " <> ceDriver (pairBase p)
