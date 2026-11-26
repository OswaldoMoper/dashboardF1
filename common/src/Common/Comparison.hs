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
  , Layer (..)
  , Curve (..)
  , curvesOf
  , curveKey
  , curvesWith
  , axisValues
  , axisBlowUp
  , frontSeries
  , lapShown
  , missingReference
  , noneHasLap
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
    -- * Los coches elegidos
  , maxCars
  , pickReference
  , addCar
  , removeCar
  , keepCars
  , GroupPick (..)
  , Added (..)
  , WithGroups (..)
  , withGroups
  , addedCars
  , addedLaps
  , lapAgainst
  , leadingPair
    -- * El mando de la vuelta
  , lapChoiceKey
  , lapChoiceFromKey
  , lapChoiceLabel
  , lapChoiceShort
  , lapFor
  , lapButtons
  , LapPick (..)
  , lapPicks
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

import           Common.Chart   (axisRange)
import           Common.Origin  (Source (..))
import           Common.Session (SessionKey, renderSessionKey)
import           Common.Types   (ComparisonEntry (..), DriverEntry (..),
                                 LapComparison (..), LiveTimingRow (..),
                                 SessionInfo (..), SessionState (..),
                                 StateReading (..), lapSeconds, partLabel,
                                 sessionIsLive)
import           Control.Monad  (join)
import           Data.Aeson     (FromJSON (..), ToJSON (..), Value (String),
                                 withText)
import           Data.List      (find, minimumBy, nub, sortOn)
import           Data.Maybe     (fromMaybe, isJust, isNothing, listToMaybe)
import           Data.Ord       (comparing)
import           Data.Text      (Text)
import qualified Data.Text      as T
import           Text.Read      (readMaybe)

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

-- | Cómo se pinta una curva cuando se comparan de 3 a 5 coches (2026-11-21 (l)).
data Layer
  = Faint
    -- ^ A 2 px y al 35 %.
  | Behind
    -- ^ La base: entera, detrás de la del frente.
  | Front
    -- ^ La elegida, con su pareja; de ella son la fila de fronteras y la banda.
  deriving stock (Eq, Show)

-- | Un coche de la comparación, su Δ contra la base ('deltasAgainst') y cómo se pinta, y la
-- sesión de un grupo de la que es la vuelta, si no es de la que se ve.
data Curve = Curve
  { cvEntry :: ComparisonEntry
  , cvDelta :: [Double]
  , cvLayer :: Layer
  , cvFrom  :: Maybe SessionKey
  }
  deriving stock (Eq, Show)

-- | Lo que distingue a una curva para llevarla al frente: sus siglas y, si es de otra
-- sesión, su clave (@«LEC · 2026-21-FP3»@).
curveKey :: Curve -> Text
curveKey cv = ceDriver (cvEntry cv) <> maybe "" ((" · " <>) . renderSessionKey) (cvFrom cv)

-- | Los coches de la comparación con la base elegida, en el orden en que se pintan
-- (2026-11-21 (l)): primero los tenues, en su orden; después la base, y al final el del frente:
-- el de siglas @front@ si es uno de los comparados y, si no, el primero tras la base. Con dos
-- coches, la base y el frente, como el par. La base es la de 'baseIndex'; sin ella, la
-- referencia, y las Δ vacías. Sin coches, ninguno.
curvesOf :: Baseline -> Maybe Text -> LapComparison -> [Curve]
curvesOf baseline front c = case zip3 [0 :: Int ..] entries deltas of
  [] -> []
  xs ->
    let others = [x | x@(i, _, _) <- xs, i /= base]
        chosen = case [i | (i, e, _) <- others, Just (ceDriver e) == front] of
          i : _ -> Just i
          []    -> (\(i, _, _) -> i) <$> listToMaybe others
        layer i
          | i == base        = Behind
          | Just i == chosen = Front
          | otherwise        = Faint
        curve (i, e, d) = Curve e d (layer i) Nothing
     in sortOn (layerOrder . cvLayer) (map curve xs)
  where
    entries = lcEntries c
    sectors = map ceSectors entries
    deltas  = deltasAgainst baseline sectors
    base    = fromMaybe 0 (baseIndex baseline sectors)

-- | El orden de pintado: los tenues, la base y el del frente.
layerOrder :: Layer -> Int
layerOrder Faint  = 0
layerOrder Behind = 1
layerOrder Front  = 2

-- | 'curvesOf' con detrás las vueltas de otras sesiones que suman los grupos (2026-11-21 (u),
-- (af)), cada una tenue y con su Δ contra la misma base ('lapAgainst'). Va al frente la de
-- clave @front@ ('curveKey'), sea de la sesión que se ve o de otra; si es de otra, la de la
-- sesión que se ve pasa a tenue. En el orden en que se pintan.
curvesWith :: Baseline -> Maybe Text -> LapComparison -> [(SessionKey, ComparisonEntry)] -> [Curve]
curvesWith baseline front c laps = sortOn (layerOrder . cvLayer) (map demote here <> others)
  where
    here   = curvesOf baseline front c
    others =
      [ if Just (curveKey cv) == front then cv {cvLayer = Front} else cv
      | (k, e) <- laps
      , let cv = Curve e (lapAgainst baseline c e) Faint (Just k) ]
    lapAtFront = any ((== Front) . cvLayer) others
    demote cv
      | lapAtFront && cvLayer cv == Front = cv {cvLayer = Faint}
      | otherwise                         = cv

-- | Los valores con los que se escala el eje vertical del tipo 1 (2026-11-23 (h)): los de todas
-- las curvas, salvo que las de otras sesiones multipliquen el alto del eje por más de
-- 'axisBlowUp'; entonces, solo los de la sesión que se ve, y lo demás se corta en el borde.
-- Sin curvas de la sesión que se ve, los de todas.
axisValues :: [Curve] -> [Double]
axisValues curves
  | null here                                         = everything
  | extent everything > axisBlowUp * extent ownValues = ownValues
  | otherwise                                         = everything
  where
    here       = [cv | cv <- curves, isNothing (cvFrom cv)]
    ownValues  = concatMap cvDelta here
    everything = concatMap cvDelta curves
    extent xs  = let (lo, hi) = axisRange xs in hi - lo

-- | Cuántas veces puede crecer el alto del eje por las vueltas de otras sesiones antes de
-- cortarlas (2026-11-23 (h)).
axisBlowUp :: Double
axisBlowUp = 3

-- | La Δ del coche al frente ('curvesOf'), la de la fila de fronteras y la banda; @[]@
-- sin coche al frente o si a él o a la base les faltan los sectores.
frontSeries :: Baseline -> Maybe Text -> LapComparison -> [Double]
frontSeries baseline front = maybe [] cvDelta . find ((== Front) . cvLayer) . curvesOf baseline front

-- | El tiempo de vuelta de un coche como se pinta: @«sin vuelta»@ si no tiene sus
-- tres sectores.
lapShown :: ComparisonEntry -> Text
lapShown e
  | isNothing (ceSectors e) = "sin vuelta"
  | otherwise               = ceLap e

-- | El aviso que sustituye a la gráfica: con cualquier base, si hay coches y ninguno
-- tiene vuelta; contra la referencia, también si es ella la que no la tiene. 'Nothing'
-- en cualquier otro caso: contra el más rápido, la base es el más rápido de los que
-- tienen vuelta.
missingReference :: Baseline -> LapComparison -> Maybe Text
missingReference _ c
  | noneHasLap c = Just "Ninguno de los elegidos tiene vuelta en esta sesión: elige otro piloto."
missingReference AgainstFastest _ = Nothing
missingReference AgainstReference c =
  case lcEntries c of
    (ref : _) | isNothing (ceSectors ref) -> Just (noLapNote ref <> ": elige otra referencia.")
    _ -> Nothing

-- | Si hay coches y ninguno tiene vuelta (sus tres sectores). Sin coches, 'False'.
noneHasLap :: LapComparison -> Bool
noneHasLap c = case lcEntries c of
  es@(_ : _) -> all (isNothing . ceSectors) es
  []         -> False

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

-- | Cuántos coches se comparan como mucho, la referencia incluida (2026-09-29 (b)).
maxCars :: Int
maxCars = 5

-- | La referencia nueva en la lista elegida (la referencia primero): si ya estaba entre
-- los demás, la vieja ocupa su sitio; si no, la vieja sale. Con la lista vacía, sola.
pickReference :: Text -> [Text] -> [Text]
pickReference new [] = [new]
pickReference new (ref : others)
  | new == ref = ref : others
  | otherwise  = new : map (\c -> if c == new then ref else c) others

-- | Un coche más, al final; nada si ya está o si ya hay 'maxCars'.
addCar :: Text -> [Text] -> [Text]
addCar car cars
  | car `elem` cars || length cars >= maxCars = cars
  | otherwise                                 = cars <> [car]

-- | Fuera un coche que no sea la referencia; nada si es ella o si quedaría sola.
removeCar :: Text -> [Text] -> [Text]
removeCar car (ref : others)
  | car /= ref && any (/= car) others = ref : filter (/= car) others
removeCar _ cars = cars

-- | Los coches elegidos en una lista de números nueva, en su orden: el que está se queda;
-- el que no, pasa al primero de la lista que no esté elegido, y si no queda ninguno,
-- sale.
keepCars :: [Text] -> [Text] -> [Text]
keepCars cars chosen = go [] chosen
  where
    go acc [] = reverse acc
    go acc (c : cs)
      | c `elem` cars = go (c : acc) cs
      | otherwise = case find (`notElem` (acc <> chosen)) cars of
          Just x  -> go (x : acc) cs
          Nothing -> go acc cs

-- | Lo que suma a Lap Comparison un grupo de la tarjeta: sus pilotos, por siglas, y la
-- sesión que suma, ya resuelta ('Common.Group.addedSessions'), si la hay.
data GroupPick = GroupPick
  { gpDrivers :: [Text]
  , gpSession :: Maybe SessionKey
  }
  deriving stock (Eq, Show)

-- | Un hueco de la comparación que añade un grupo.
data Added
  = AddedCar Text Text
    -- ^ Un coche de la sesión que se ve: su número y sus siglas.
  | AddedLap SessionKey Text
    -- ^ La vuelta de un piloto, por siglas, en la sesión de un grupo.
  deriving stock (Eq, Show)

-- | Lo que se compara cuando la tarjeta está en grupos (2026-11-20 (l), (p), (u);
-- 2026-11-21 (u), (al)).
data WithGroups = WithGroups
  { wgCars    :: [Text]
    -- ^ Los números que se piden de la sesión que se ve: los de la tarjeta, la referencia
    -- primero, y detrás los coches que añaden los grupos.
  , wgAdded   :: [Added]
    -- ^ Lo que añaden los grupos y cabe, en su orden.
  , wgLeftOut :: [Added]
    -- ^ Lo que añaden los grupos y no cabe.
  }
  deriving stock (Eq, Show)

-- | Los coches de la tarjeta con lo que suman sus grupos, en el orden de los grupos y,
-- dentro de cada uno, primero sus pilotos y después su sesión: cada piloto del grupo que no
-- está ya en la tarjeta (un piloto que no está en la parrilla no cuenta), y con sesión, la
-- vuelta en ella de cada piloto del grupo o, si no tiene pilotos, la de la referencia. Los de
-- la tarjeta no se caen nunca; lo de los grupos entra hasta 'maxCars' y lo demás no cabe.
-- Sin coches de la tarjeta no se añade nada.
withGroups :: [DriverEntry] -> [Text] -> [GroupPick] -> WithGroups
withGroups _ [] _ = WithGroups [] [] []
withGroups grid own@(ref : _) picks =
  WithGroups (own <> [n | AddedCar n _ <- fits]) fits rest
  where
    byCode c   = find ((== c) . deCode) grid
    refCode    = deCode <$> find ((== ref) . deNumber) grid
    slots      = nub (concatMap slotsOf picks)
    slotsOf (GroupPick ds s) =
      [AddedCar (deNumber d) (deCode d) | c <- ds, Just d <- [byCode c], deNumber d `notElem` own]
        <> maybe [] (\k -> [AddedLap k c | c <- if null ds then maybe [] pure refCode else ds]) s
    (fits, rest) = splitAt (max 0 (maxCars - length own)) slots

-- | Los números de los coches que añaden los grupos ('wgAdded').
addedCars :: WithGroups -> [Text]
addedCars g = [n | AddedCar n _ <- wgAdded g]

-- | Las vueltas de otras sesiones que añaden los grupos, juntas por sesión y en su orden:
-- una petición por sesión.
addedLaps :: WithGroups -> [(SessionKey, [Text])]
addedLaps g = [(k, [c | AddedLap k' c <- wgAdded g, k' == k]) | k <- nub [k | AddedLap k _ <- wgAdded g]]

-- | La Δ de una vuelta de otra sesión contra la base de la comparación que se ve ('baseIndex'):
-- @[]@ si a ella o a la base les faltan los sectores.
lapAgainst :: Baseline -> LapComparison -> ComparisonEntry -> [Double]
lapAgainst baseline c e =
  case (ceSectors e, join (listToMaybe . flip drop sectors =<< baseIndex baseline sectors)) of
    (Just s, Just b) -> zipWith (-) (frontierTimes s) (frontierTimes b)
    _                -> []
  where
    sectors = map ceSectors (lcEntries c)

-- | Cómo se guarda una vuelta: @fastest@, @last@ o @part-2@.
lapChoiceKey :: LapChoice -> Text
lapChoiceKey FastestLap  = "fastest"
lapChoiceKey LastLap     = "last"
lapChoiceKey (PartLap n) = "part-" <> T.pack (show n)

-- | 'lapChoiceKey' al revés; una parte que no sea de 1 en adelante no se lee.
lapChoiceFromKey :: Text -> Maybe LapChoice
lapChoiceFromKey "fastest" = Just FastestLap
lapChoiceFromKey "last"    = Just LastLap
lapChoiceFromKey k = do
  n <- readMaybe . T.unpack =<< T.stripPrefix "part-" k
  if n >= 1 then Just (PartLap n) else Nothing

instance ToJSON LapChoice where
  toJSON = String . lapChoiceKey

instance FromJSON LapChoice where
  parseJSON = withText "LapChoice" $ \k ->
    maybe (fail "LapChoice: no es una vuelta") pure (lapChoiceFromKey k)

-- | El nombre de una vuelta en los botones de la cabecera: @«más rápida»@, @«última»@,
-- @«Q2»@ (@«SQ2»@ en la clasificación Sprint).
lapChoiceLabel :: Maybe SessionInfo -> LapChoice -> Text
lapChoiceLabel _ FastestLap  = "más rápida"
lapChoiceLabel _ LastLap     = "última"
lapChoiceLabel s (PartLap n) = maybe ("Q" <> T.pack (show n)) (`partLabel` n) s

-- | El nombre en el desplegable corto de cada piloto: @«rápida»@, y los demás como
-- 'lapChoiceLabel'.
lapChoiceShort :: Maybe SessionInfo -> LapChoice -> Text
lapChoiceShort _ FastestLap = "rápida"
lapChoiceShort s c          = lapChoiceLabel s c

-- | La vuelta que lleva un piloto entre las que se ofrecen: su excepción; si no, la
-- regla; si tampoco se ofrece, la más rápida (la regla se sigue recordando).
lapFor :: [LapChoice] -> LapChoice -> Maybe LapChoice -> LapChoice
lapFor offered rule exception =
  case filter (`elem` offered) (maybe [] pure exception <> [rule]) of
    c : _ -> c
    []    -> FastestLap

-- | Los botones de la regla, con su nombre y si se pueden pulsar: en directo
-- ('Just' con su sesión), los que se ofrecen; con FastF1 ('Nothing'), «más rápida» y
-- «última» apagada.
lapButtons :: Maybe (Maybe SessionInfo) -> [(LapChoice, Text, Bool)]
lapButtons Nothing  = [(FastestLap, lapChoiceLabel Nothing FastestLap, True), (LastLap, lapChoiceLabel Nothing LastLap, False)]
lapButtons (Just s) = [(c, lapChoiceLabel s c, True) | c <- lapChoicesOffered s]

-- | El desplegable corto de un piloto: sus opciones con su nombre, la vuelta que lleva,
-- si difiere de la regla y si se puede tocar (con FastF1, no).
data LapPick = LapPick
  { lpOptions :: [(LapChoice, Text)]
  , lpValue   :: LapChoice
  , lpDiffers :: Bool
  , lpEnabled :: Bool
  }
  deriving stock (Eq, Show)

-- | Los desplegables cortos de los pilotos, con la regla y la excepción de cada uno
-- ('lapFor'): en directo, los de los dos que se comparan; con FastF1 ('Nothing'),
-- 'maxCars', todos en «rápida» y apagados.
lapPicks :: Maybe (Maybe SessionInfo) -> LapChoice -> (Maybe LapChoice, Maybe LapChoice) -> [LapPick]
lapPicks Nothing _ _ = replicate maxCars (LapPick [(c, lapChoiceShort Nothing c) | c <- [FastestLap, LastLap]] FastestLap False False)
lapPicks (Just s) rule (a, b) = map pick [a, b]
  where
    offered  = lapChoicesOffered s
    options  = [(c, lapChoiceShort s c) | c <- offered]
    shown    = lapFor offered rule Nothing
    pick exc = let v = lapFor offered rule exc in LapPick options v (v /= shown) True

-- | El tipo de gráfica de Lap Comparison, elegido en el título.
data ChartType = SectorDelta | TelemetryTraces | LapDeltaBars
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
chartTypeLabel TelemetryTraces = "Telemetría comparativa"
chartTypeLabel LapDeltaBars    = "Lap Delta"

-- | Si el tipo ya se puede elegir; los demás salen en gris en el desplegable.
chartTypeReady :: ChartType -> Bool
chartTypeReady SectorDelta     = True
chartTypeReady TelemetryTraces = True
chartTypeReady _               = False

-- | El @value@ de cada opción del desplegable.
chartTypeKey :: ChartType -> Text
chartTypeKey SectorDelta     = "sector-delta"
chartTypeKey TelemetryTraces = "telemetry"
chartTypeKey LapDeltaBars    = "lap-delta"

-- | 'chartTypeKey' al revés.
chartTypeFromKey :: Text -> Maybe ChartType
chartTypeFromKey k = lookup k [(chartTypeKey t, t) | t <- chartTypesInOrder]

-- | Si el tipo pinta trazas y pide muestras al servidor.
chartTypeTraces :: ChartType -> Bool
chartTypeTraces = (`elem` [TelemetryTraces, LapDeltaBars])

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
