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
  ) where

import           Common.Types  (ComparisonEntry (..), LapComparison (..))
import           Control.Monad (join)
import           Data.List     (find, minimumBy)
import           Data.Maybe    (isNothing, listToMaybe)
import           Data.Ord      (comparing)
import           Data.Text     (Text)

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
