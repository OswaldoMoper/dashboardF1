-- | Lo que Lap Comparison calcula con los datos de cada piloto, sin pintar nada: la Δ
-- en las fronteras contra la base que elija el usuario, y el estiramiento del eje
-- «Sectores».
module Common.Comparison
  ( Sectors
  , frontierTimes
  , Baseline (..)
  , deltasAgainst
  , anchored
  ) where

import           Control.Monad (join)
import           Data.List     (minimumBy)
import           Data.Maybe    (catMaybes, listToMaybe)
import           Data.Ord      (comparing)

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
