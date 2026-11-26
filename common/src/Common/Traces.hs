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
  , toggleChannel
  , TraceRows (..)
  , channelLabel
  , channelName
  , channelKey
  , channelHeight
  , channelTop
  , channelValue
  , channelRange
    -- * El lienzo
  , tracesWidth
  , tracesHeight
  , channelsSpan
    -- * El estirado
  , TracePiece (..)
  , TraceLayout (..)
  , traceLayout
  , spanPiece
  , pieceFlex
    -- * La X
  , carGeometry
  , traceXs
  , axisEnd
  , frontierXs
  , boundaryXs
  , xPercent
    -- * La curva
  , tracePoints
  , traceVertices
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
import           Data.Aeson        (FromJSON (..), ToJSON (..), Value (String),
                                    withText)
import           Data.List         (intercalate)
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

-- | Los canales que pinta un tipo con los elegidos en «Gráficas ▾», de arriba abajo:
-- «Telemetría comparativa», los elegidos; el 1 no pinta trazas, y Lap Delta no tiene
-- canales hasta que se decida si sus barras son las trazas.
traceChannels :: ChartType -> [Channel] -> [Channel]
traceChannels TelemetryTraces chosen = [c | c <- channelsInOrder, c `elem` chosen]
traceChannels _ _                    = []

-- | Marca o desmarca un canal en «Gráficas ▾», en el orden de arriba abajo. El último
-- marcado no se desmarca.
toggleChannel :: Channel -> [Channel] -> [Channel]
toggleChannel c chosen
  | c `notElem` chosen = [x | x <- channelsInOrder, x == c || x `elem` chosen]
  | all (== c) chosen  = chosen
  | otherwise          = filter (/= c) chosen

-- | El rótulo de cada fila.
channelLabel :: Channel -> Text
channelLabel Speed    = "km/h"
channelLabel Throttle = "Acelerador %"
channelLabel Brake    = "Freno"

-- | El nombre de cada canal en «Gráficas ▾».
channelName :: Channel -> Text
channelName Speed    = "Velocidad"
channelName Throttle = "Acelerador"
channelName Brake    = "Freno"

-- | Cómo se guarda un canal.
channelKey :: Channel -> Text
channelKey Speed    = "speed"
channelKey Throttle = "throttle"
channelKey Brake    = "brake"

-- | Se guarda por su 'channelKey'; otro texto no se lee.
instance ToJSON Channel where
  toJSON = String . channelKey

instance FromJSON Channel where
  parseJSON = withText "Channel" $ \k ->
    maybe (fail "Channel: no es un canal") pure (lookup k [(channelKey c, c) | c <- channelsInOrder])

-- | Las filas que se pintan, de arriba abajo.
newtype TraceRows = TraceRows { trChannels :: [Channel] }
  deriving stock (Eq, Show)

-- | El alto mínimo de una fila, en px: la velocidad 150 si va sola, 100 con otra
-- (2026-10-06 (e)) y 75 con las otras dos (2026-11-24), para que las tres quepan en una
-- tarjeta de ~340 px; el acelerador 50 y el freno 20, solos o no (2026-11-23 (m)). Lo
-- que la tarjeta crece lo reparte 'traceLayout'.
channelHeight :: TraceRows -> Channel -> Double
channelHeight r Speed
  | trChannels r == [Speed]   = 150
  | length (trChannels r) > 2 = 75
  | otherwise                 = 100
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

-- | Un trozo del lienzo, de arriba abajo: la fila de un canal o, con 'Nothing', un
-- aire (el del rótulo de arriba, el hueco entre dos filas o el del eje). Lleva su
-- alto mínimo, en px, y su peso al repartir lo que crece la tarjeta (@flex-grow@):
-- cada trozo se lleva su peso entre la suma de todos.
data TracePiece = TracePiece
  { tpChannel :: Maybe Channel
  , tpBasis   :: Double
  , tpGrow    :: Double
  }
  deriving stock (Eq, Show)

-- | El lienzo en trozos: el aire de arriba, las filas con los aires de entre medias
-- y el aire de abajo. Las fronteras van de punta a punta de 'tlSpan'.
data TraceLayout = TraceLayout
  { tlTop    :: TracePiece
  , tlSpan   :: [TracePiece]
  , tlBottom :: TracePiece
  }
  deriving stock (Eq, Show)

-- | Los trozos de esas filas. Sin crecer suman 'tracesHeight'. Los pesos
-- (2026-10-09 (h), 2026-11-23 (m)): una fila sola se queda todo lo que crece; con
-- más, cada una pesa su alto con otra fila (la velocidad 100 también con las tres,
-- 2026-11-24), y cada aire la mitad del suyo, así que crece la mitad que ellas.
traceLayout :: TraceRows -> TraceLayout
traceLayout r =
  TraceLayout (air tracesTop) (intercalate [air tracesGap] (map (pure . row) chs)) (air tracesBottom)
  where
    chs   = trChannels r
    alone = length chs == 1
    row ch = TracePiece (Just ch) (channelHeight r ch) (if alone then 1 else weight ch)
    weight Speed = 100
    weight ch    = channelHeight r ch
    air h  = TracePiece Nothing h (if alone then 0 else h / 2)

-- | Un trozo que agrupa otros: suma sus mínimos y sus pesos, así que repartir dentro
-- de él da lo mismo que repartir entre todos.
spanPiece :: [TracePiece] -> TracePiece
spanPiece ps = TracePiece Nothing (sum (map tpBasis ps)) (sum (map tpGrow ps))

-- | El @flex@ de un trozo en una columna: crece con su peso, no encoge y parte de su
-- mínimo.
pieceFlex :: TracePiece -> Text
pieceFlex p = "flex: " <> formatFixed 3 (tpGrow p) <> " 0 " <> formatFixed 1 (tpBasis p) <> "px"

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
-- rango y la X mayor de los que se pintan: 'traceVertices' con un decimal.
tracePoints
  :: TraceRows -> Channel -> (Double, Double) -> Double -> [Double] -> [TracePoint] -> Text
tracePoints r ch range xMax xs ps =
  T.unwords [formatFixed 1 x <> "," <> formatFixed 1 y | (x, y) <- traceVertices r ch range xMax xs ps]

-- | Los vértices de la curva de un coche en un canal, en unidades del dibujo entero
-- ('tracesWidth' de ancho). El freno va en escalones: cada muestra repite antes el valor
-- de la anterior. Vacía si las X y las muestras no casan.
traceVertices
  :: TraceRows -> Channel -> (Double, Double) -> Double -> [Double] -> [TracePoint] -> [(Double, Double)]
traceVertices r ch (lo, hi) xMax xs ps
  | length xs /= length ps || null xs = []
  | otherwise = concat (zipWith3 point xs ys (Nothing : map Just ys))
  where
    ys = map (y . channelValue ch) ps
    y v
      | hi > lo   = channelTop r ch + channelHeight r ch * (1 - (v - lo) / (hi - lo))
      | otherwise = channelTop r ch + channelHeight r ch
    x v = tracesWidth * xPercent xMax v / 100
    point xv yv (Just prev) | ch == Brake = [(x xv, prev), (x xv, yv)]
    point xv yv _                         = [(x xv, yv)]

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
