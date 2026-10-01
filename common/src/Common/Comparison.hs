-- | Lo que Lap Comparison calcula con los datos de cada piloto, sin pintar nada: la Δ
-- en las fronteras contra la base que elija el usuario, y la X de cada muestra de
-- las trazas en el eje elegido.
module Common.Comparison
  ( Sectors
  , frontierTimes
  , Baseline (..)
  , deltasAgainst
  , Axis (..)
  , axesInOrder
  , defaultAxis
  , axisLabel
  , axisNotice
  , LapGeometry (..)
  , axisXs
  , anchored
  ) where

import           Control.Monad (join)
import           Data.List     (minimumBy)
import           Data.Maybe    (catMaybes, listToMaybe)
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
  deriving stock (Eq, Show)

-- | La Δ de cada piloto en las cuatro fronteras, __comparado − base__ (positivo = va
-- por detrás), en el orden de entrada. El más rápido es la vuelta más corta de los
-- que tienen sus tres sectores, y un empate se lo queda el primero. Un piloto sin
-- sectores da @[]@, y todos dan @[]@ si la base no los tiene.
deltasAgainst :: Baseline -> [Maybe Sectors] -> [[Double]]
deltasAgainst baseline entries =
  case base of
    Nothing -> map (const []) entries
    Just b  -> map (maybe [] (\s -> zipWith (-) (frontierTimes s) (frontierTimes b))) entries
  where
    base = case baseline of
      AgainstReference -> join (listToMaybe entries)
      AgainstFastest   -> fastest (catMaybes entries)
    fastest [] = Nothing
    fastest xs = Just (minimumBy (comparing lapOf) xs)
    lapOf (s1, s2, s3) = s1 + s2 + s3

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
