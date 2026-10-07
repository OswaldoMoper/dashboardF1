-- | El escalado de las trazas de Lap Comparison a un @\<svg\>@ de ancho fijo: un canal
-- por fila —los que lleva el tipo ('traceChannels')—, la X de cada muestra en el eje
-- elegido ('Common.Comparison.axisXs') y dónde caen las fronteras. Puro; quien pinta
-- es 'Widgets.Comparison'.
--
-- La X va de 0 al final de la vuelta más larga de las que se pintan, sin margen: el
-- lienzo se estira a lo ancho, y lo que va en HTML encima se coloca en porcentaje
-- con 'xPercent'.
module Common.Traces
  ( -- * Los canales
    Channel (..)
  , channelsInOrder
  , traceChannels
  , TraceRows (..)
  , stretchesSpeed
  , channelLabel
  , channelHeight
  , channelTop
  , channelValue
  , channelRange
    -- * El lienzo
  , tracesWidth
  , tracesHeight
  , channelsSpan
    -- * La X
  , carGeometry
  , traceXs
  , axisEnd
  , frontierXs
  , boundaryXs
  , xPercent
    -- * La curva
  , tracePoints
    -- * Los rótulos
  , channelCaption
  , axisEndLabel
    -- * El deslizable de muestras
  , samplesMin
  , samplesMax
  , samplesStep
  , samplesStart
  , readSamples
  ) where

import           Common.Comparison (Axis (..), ChartType (..), LapGeometry (..),
                                    axisXs)
import           Common.Format     (formatFixed)
import           Common.Types      (ComparisonEntry (..), TracePoint (..))
import           Data.Maybe        (fromMaybe)
import           Data.Text         (Text)
import qualified Data.Text         as T
import           Text.Read         (readMaybe)

-- | Un canal de la traza, una fila del lienzo.
data Channel = Speed | Throttle | Brake
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Los canales de arriba abajo.
channelsInOrder :: [Channel]
channelsInOrder = [minBound .. maxBound]

-- | Los canales que pinta cada tipo, de arriba abajo: el 2 solo la velocidad y el 3
-- los tres (2026-10-06 (e)). El 1 no pinta trazas, y el 4 no tiene canales hasta que
-- se decida si sus barras son las trazas.
traceChannels :: ChartType -> [Channel]
traceChannels LapSpeedTrace   = [Speed]
traceChannels TelemetryTraces = channelsInOrder
traceChannels _               = []

-- | El rótulo de cada fila.
channelLabel :: Channel -> Text
channelLabel Speed    = "km/h"
channelLabel Throttle = "Acelerador %"
channelLabel Brake    = "Freno"

-- | Las filas que se pintan, de arriba abajo, y lo que se estira la velocidad sobre
-- su mínimo, en px; solo cuenta si la velocidad va sola ('stretchesSpeed').
data TraceRows = TraceRows
  { trChannels :: [Channel]
  , trStretch  :: Double
  }
  deriving stock (Eq, Show)

-- | Si la velocidad se estira con la tarjeta: solo cuando va sola (2026-10-06 (e));
-- con otras filas, el tipo 3, espera al modo edición.
stretchesSpeed :: [Channel] -> Bool
stretchesSpeed = (== [Speed])

-- | El alto de una fila, en px: la velocidad 150 más lo estirado si va sola y 100
-- con otra (2026-10-06 (e)). Con los rótulos, el tipo 3 cabe en 55 u de Race
-- Overview a 1912 × 914 (2026-10-06 (d)).
channelHeight :: TraceRows -> Channel -> Double
channelHeight r Speed
  | stretchesSpeed (trChannels r) = 150 + trStretch r
  | otherwise                     = 100
channelHeight _ Throttle = 50
channelHeight _ Brake    = 20

-- | Lo que hay encima de la primera fila (su rótulo) y debajo de la última (el
-- principio y el final del eje X), y entre dos filas, en px.
tracesTop, tracesGap, tracesBottom :: Double
tracesTop    = 19
tracesGap    = 19
tracesBottom = 16

-- | El ancho del @viewBox@; el lienzo se estira al de la tarjeta.
tracesWidth :: Double
tracesWidth = 600

-- | El alto del lienzo con esas filas, en px y en unidades del @viewBox@, que
-- coinciden.
tracesHeight :: TraceRows -> Double
tracesHeight r =
  tracesTop + sum (map (channelHeight r) chs)
    + tracesGap * fromIntegral (max 0 (length chs - 1)) + tracesBottom
  where
    chs = trChannels r

-- | Dónde empiezan las filas y dónde acaban, de la primera a la última.
channelsSpan :: TraceRows -> (Double, Double)
channelsSpan r = (tracesTop, tracesHeight r - tracesBottom)

-- | Dónde empieza una fila entre esas filas.
channelTop :: TraceRows -> Channel -> Double
channelTop r ch =
  tracesTop + sum [channelHeight r c + tracesGap | c <- trChannels r, c < ch]

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
-- «Sectores». @[]@ si el coche no tiene traza, o en «Sectores» si no la tiene la
-- referencia.
traceXs :: Axis -> ComparisonEntry -> ComparisonEntry -> [Double]
traceXs axis ref car =
  case (carGeometry car, axis) of
    (Nothing, _)          -> []
    (Just g, AxisSectors) -> maybe [] (\rg -> axisXs axis g rg samples) (carGeometry ref)
    (Just g, _)           -> axisXs axis g g samples
  where
    samples = [(ctTime p, ctDistance p) | p <- ceTrace car]

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

-- | El atributo @points@ de la curva de un coche en un canal de esas filas, con su
-- rango y la X mayor de los que se pintan. El freno va en escalones: cada muestra
-- repite antes el valor de la anterior. Vacío si las X y las muestras no casan.
tracePoints
  :: TraceRows -> Channel -> (Double, Double) -> Double -> [Double] -> [TracePoint] -> Text
tracePoints r ch (lo, hi) xMax xs ps
  | length xs /= length ps || null xs = ""
  | otherwise = T.unwords (concat (zipWith3 point xs ys (Nothing : map Just ys)))
  where
    ys = map (y . channelValue ch) ps
    y v
      | hi > lo   = channelTop r ch + channelHeight r ch * (1 - (v - lo) / (hi - lo))
      | otherwise = channelTop r ch + channelHeight r ch
    x v = tracesWidth * xPercent xMax v / 100
    pair a b = formatFixed 1 a <> "," <> formatFixed 1 b
    point xv yv (Just prev) | ch == Brake = [pair (x xv) prev, pair (x xv) yv]
    point xv yv _                         = [pair (x xv) yv]

-- | El rótulo de una fila con su rango: la velocidad dice hasta dónde llega,
-- @«km/h (0–300)»@; las otras dos, solo su nombre.
channelCaption :: Channel -> (Double, Double) -> Text
channelCaption Speed (lo, hi) =
  channelLabel Speed <> " (" <> formatFixed 0 lo <> "–" <> formatFixed 0 hi <> ")"
channelCaption ch _ = channelLabel ch

-- | El rótulo del final del eje X: metros enteros, segundos con un decimal, o la
-- fracción con dos.
axisEndLabel :: Axis -> Double -> Text
axisEndLabel AxisDistance x = formatFixed 0 x <> " m"
axisEndLabel AxisTime x     = formatFixed 1 x <> " s"
axisEndLabel _ x            = formatFixed 2 x

-- | El deslizable de muestras por coche: de 60 a 250 de 5 en 5, y abre en 100
-- (2026-09-30 (a)).
samplesMin, samplesMax, samplesStep, samplesStart :: Int
samplesMin   = 60
samplesMax   = 250
samplesStep  = 5
samplesStart = 100

-- | El valor del deslizable como muestras, o 'Nothing' si no es un número en su
-- rango.
readSamples :: Text -> Maybe Int
readSamples t = do
  n <- readMaybe (T.unpack t)
  if n >= samplesMin && n <= samplesMax then Just n else Nothing
