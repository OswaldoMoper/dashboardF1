-- | El escalado de las trazas de Lap Comparison (el tipo 3, Telemetría comparativa) a
-- un @\<svg\>@ de ancho fijo: un canal por fila —velocidad, acelerador y freno—, la X
-- de cada muestra en el eje elegido ('Common.Comparison.axisXs') y dónde caen las
-- fronteras. Puro; quien pinta es 'Widgets.Comparison'.
--
-- La X va de 0 al final de la vuelta más larga de las que se pintan, sin margen: el
-- lienzo se estira a lo ancho, y lo que va en HTML encima se coloca en porcentaje
-- con 'xPercent'.
module Common.Traces
  ( -- * Los canales
    Channel (..)
  , channelsInOrder
  , channelLabel
  , channelHeight
  , channelTop
  , channelValue
  , channelRange
    -- * El lienzo
  , tracesWidth
  , tracesHeight
    -- * La X
  , carGeometry
  , traceXs
  , axisEnd
  , frontierXs
  , boundaryXs
  , xPercent
    -- * La curva
  , tracePoints
  ) where

import           Common.Comparison (Axis (..), LapGeometry (..), axisXs)
import           Common.Format     (formatFixed)
import           Common.Types      (ComparisonEntry (..), TracePoint (..))
import           Data.Maybe        (fromMaybe)
import           Data.Text         (Text)
import qualified Data.Text         as T

-- | Un canal de la traza, una fila del lienzo.
data Channel = Speed | Throttle | Brake
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Los canales de arriba abajo.
channelsInOrder :: [Channel]
channelsInOrder = [minBound .. maxBound]

-- | El rótulo de cada fila.
channelLabel :: Channel -> Text
channelLabel Speed    = "km/h"
channelLabel Throttle = "Acelerador %"
channelLabel Brake    = "Freno"

-- | El alto de cada fila, en px (2026-10-02: la velocidad a 100).
channelHeight :: Channel -> Double
channelHeight Speed    = 100
channelHeight Throttle = 60
channelHeight Brake    = 30

-- | Lo que hay encima de la primera fila (su rótulo) y debajo de la última (el
-- principio y el final del eje X), y entre dos filas, en px.
tracesTop, tracesGap, tracesBottom :: Double
tracesTop    = 14
tracesGap    = 14
tracesBottom = 16

-- | El ancho del @viewBox@; el lienzo se estira al de la tarjeta.
tracesWidth :: Double
tracesWidth = 600

-- | El alto del lienzo, en px y en unidades del @viewBox@, que coinciden.
tracesHeight :: Double
tracesHeight =
  tracesTop + sum (map channelHeight channelsInOrder)
    + tracesGap * fromIntegral (length channelsInOrder - 1) + tracesBottom

-- | Dónde empieza cada fila.
channelTop :: Channel -> Double
channelTop ch =
  tracesTop + sum [channelHeight c + tracesGap | c <- channelsInOrder, c < ch]

-- | El valor de una muestra en un canal: la velocidad en km\/h, el acelerador en %
-- y el freno, 0 o 1.
channelValue :: Channel -> TracePoint -> Double
channelValue Speed    = ctSpeed
channelValue Throttle = (* 100) . ctThrottle
channelValue Brake    = ctBrake

-- | El rango vertical de un canal: el acelerador de 0 a 100 y el freno de 0 a 1; la
-- velocidad de 0 a la máxima de los coches que se pintan redondeada hacia arriba a
-- 50 (50 si no hay muestras).
channelRange :: Channel -> [ComparisonEntry] -> (Double, Double)
channelRange Throttle _ = (0, 100)
channelRange Brake _    = (0, 1)
channelRange Speed es   =
  (0, max 50 (fromIntegral (ceiling (top / 50) :: Int) * 50))
  where
    top = maximum (0 : [ctSpeed p | e <- es, p <- ceTrace e])

-- | Lo que la vuelta de un coche aporta a los ejes: su distancia total —la de su
-- última muestra— y sus fronteras S1\/S2 en metros. 'Nothing' sin traza. Sin
-- fronteras van a @(0, 0)@, con las que 'Common.Comparison.anchored' deja la
-- fracción tal cual.
carGeometry :: ComparisonEntry -> Maybe LapGeometry
carGeometry e = case ceTrace e of
  [] -> Nothing
  ps -> Just (LapGeometry (ctDistance (last ps)) (fromMaybe (0, 0) (ceFrontiers e)))

-- | La X de cada muestra de un coche en el eje elegido, con la referencia para el eje
-- «Sectores». @[]@ si el coche o la referencia no tienen traza.
traceXs :: Axis -> ComparisonEntry -> ComparisonEntry -> [Double]
traceXs axis ref car =
  case (carGeometry car, carGeometry ref) of
    (Just g, Just rg) -> axisXs axis g rg [(ctTime p, ctDistance p) | p <- ceTrace car]
    _                 -> []

-- | Dónde acaba la vuelta de un coche en el eje: la X de su última muestra, o 0.
axisEnd :: Axis -> ComparisonEntry -> ComparisonEntry -> Double
axisEnd axis ref car = case traceXs axis ref car of
  [] -> 0
  xs -> last xs

-- | Dónde cruzó un coche S1 y S2, en el eje: en tiempo, sus sectores; en distancia,
-- sus fronteras en metros; en fracción, divididas por su total; y en «Sectores», las
-- de la referencia, que es donde el estiramiento las lleva. 'Nothing' si falta el
-- dato.
frontierXs :: Axis -> ComparisonEntry -> ComparisonEntry -> Maybe (Double, Double)
frontierXs AxisTime _ car = do
  (s1, s2, _) <- ceSectors car
  pure (s1, s1 + s2)
frontierXs AxisDistance _ car = ceFrontiers car
frontierXs AxisFraction _ car = do
  g <- carGeometry car
  (f1, f2) <- ceFrontiers car
  if lgTotal g > 0 then pure (f1 / lgTotal g, f2 / lgTotal g) else Nothing
frontierXs AxisSectors ref _ = frontierXs AxisFraction ref ref

-- | Las X de la fila Δ: Inicio, S1, S2 y S3 en las fronteras de la referencia
-- (2026-10-02). 'Nothing' si falta alguna.
boundaryXs :: Axis -> ComparisonEntry -> Maybe [Double]
boundaryXs axis ref = do
  (x1, x2) <- frontierXs axis ref ref
  pure [0, x1, x2, axisEnd axis ref ref]

-- | Una X del eje como porcentaje del ancho, hasta la X mayor; 0 si no la hay.
xPercent :: Double -> Double -> Double
xPercent xMax x
  | xMax > 0  = 100 * x / xMax
  | otherwise = 0

-- | El atributo @points@ de la curva de un coche en un canal, con su rango y la X
-- mayor de los que se pintan. El freno va en escalones: cada muestra repite antes el
-- valor de la anterior. Vacío si las X y las muestras no casan.
tracePoints :: Channel -> (Double, Double) -> Double -> [Double] -> [TracePoint] -> Text
tracePoints ch (lo, hi) xMax xs ps
  | length xs /= length ps || null xs = ""
  | otherwise = T.unwords (concat (zipWith3 point xs ys (Nothing : map Just ys)))
  where
    ys = map (y . channelValue ch) ps
    y v
      | hi > lo   = channelTop ch + channelHeight ch * (1 - (v - lo) / (hi - lo))
      | otherwise = channelTop ch + channelHeight ch
    x v = tracesWidth * xPercent xMax v / 100
    pair a b = formatFixed 1 a <> "," <> formatFixed 1 b
    point xv yv (Just prev) | ch == Brake = [pair (x xv) prev, pair (x xv) yv]
    point xv yv _                         = [pair (x xv) yv]
