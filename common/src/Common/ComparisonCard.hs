-- | Las reglas de la tarjeta de Lap Comparison que dependen de su tamaño: el ancho
-- de la tabla de mando, cuándo se apila, cuándo el eje vertical entra en la
-- gráfica y qué modo de la fila de fronteras se puede elegir.
--
-- Puro: entra el tamaño medido de la tarjeta (en px, por dentro) y salen
-- decisiones. Quien mide y pinta es 'Widgets.Comparison'.
module Common.ComparisonCard
  ( -- * Modos de la gráfica
    ChartMode (..)
  , defaultMode
  , modesInOrder
  , modeLabel
  , modeKey
  , modeFromKey
  , modeOption
  , modeEnabled
  , shownMode
  , showsValues
  , showsNames
  , rowHeight
  , valuesRowFits
  , valuesFitMeasured
    -- * Lado de la tabla de mando
  , Side (..)
  , defaultControlSide
  , otherSide
    -- * Anchos
  , CardLayout (..)
  , cardLayout
  , controlWidth
  , vsBeside
  , valuesFit
    -- * El eje dentro de la gráfica
  , insideAxisLabels
    -- * Medidas
  , valueWidth
  , valueHeight
  , carSelectWidth
  , vsWidth
  , controlMaxWidth
  , columnGap
  , axisGap
  , axisColumnWidth
  , valuesRowHeight
  , singleRowHeight
  , cardPadding
  ) where

import           Common.Chart (axisPoints, axisTicks, chartWidth,
                               frontierCells)
import           Data.List    (find, sort, sortOn)
import           Data.Maybe   (mapMaybe)
import           Data.Ord     (Down (..))
import           Data.Text    (Text)

-- | Qué lleva la fila de fronteras, debajo de la gráfica. El eje vertical va
-- siempre, en los tres.
data ChartMode
  = ModeValues      -- ^ Solo los valores: @0.000 s · −0.134 s · …@.
  | ModeAxis        -- ^ Solo el eje: @Inicio · S1 · S2 · S3@.
  | ModeAxisValues  -- ^ Las dos líneas.
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | El modo con el que abre la tarjeta.
defaultMode :: ChartMode
defaultMode = ModeAxisValues

-- | El orden de la lista del desplegable.
modesInOrder :: [ChartMode]
modesInOrder = [minBound .. maxBound]

-- | El texto del modo en el desplegable.
modeLabel :: ChartMode -> Text
modeLabel ModeValues     = "Valores"
modeLabel ModeAxis       = "Solo eje"
modeLabel ModeAxisValues = "Eje y valores"

-- | El valor del modo en el desplegable.
modeKey :: ChartMode -> Text
modeKey ModeValues     = "values"
modeKey ModeAxis       = "axis"
modeKey ModeAxisValues = "axis-values"

-- | El modo de un valor del desplegable; 'Nothing' si no es de ninguno.
modeFromKey :: Text -> Maybe ChartMode
modeFromKey k = lookup k [(modeKey m, m) | m <- modesInOrder]

-- | Si el modo pinta la línea de valores.
showsValues :: ChartMode -> Bool
showsValues = (/= ModeAxis)

-- | Si el modo pinta la línea de nombres (@Inicio · S1 · S2 · S3@).
showsNames :: ChartMode -> Bool
showsNames = (/= ModeValues)

-- | Alto de la fila de fronteras en ese modo, con su margen.
rowHeight :: ChartMode -> Double
rowHeight ModeAxisValues = valuesRowHeight
rowHeight _              = singleRowHeight

-- | Si el modo se puede elegir, sabiendo si caben las dos líneas
-- ('valuesRowFits'). Solo «Eje y valores» se apaga.
modeEnabled :: Bool -> ChartMode -> Bool
modeEnabled valuesFitHere = \case
  ModeAxisValues -> valuesFitHere
  _              -> True

-- | El texto de la entrada en la lista: el del modo, con «(no cabe)» si está apagada.
modeOption :: Bool -> ChartMode -> Text
modeOption valuesFitHere m
  | modeEnabled valuesFitHere m = modeLabel m
  | otherwise                   = modeLabel m <> " (no cabe)"

-- | El modo que se pinta a partir del elegido: «Eje y valores» sin sitio para las
-- dos líneas se ve como «Solo eje», y vuelve solo en cuanto caben. La elección no
-- se toca.
shownMode :: Bool -> ChartMode -> ChartMode
shownMode valuesFitHere m
  | modeEnabled valuesFitHere m = m
  | otherwise                   = ModeAxis

-- | Si la fila de fronteras con sus dos líneas cabe sin que la tarjeta pida scroll:
-- el alto por dentro de la tarjeta y el de su contenido __sin__ esa fila, los dos
-- medidos.
valuesRowFits :: Double -> Double -> Bool
valuesRowFits innerHeight contentWithoutRow =
  contentWithoutRow + valuesRowHeight <= innerHeight

-- | 'valuesRowFits' con lo que se mide en la página: el alto de la tarjeta con su
-- relleno (@clientHeight@), el de su contenido y el alto de la fila de fronteras
-- pintada en ese momento (0 si no hay).
valuesFitMeasured :: Double -> Double -> Double -> Bool
valuesFitMeasured client content row =
  valuesRowFits (client - cardPadding) (content - row)

-- | Un lado de la tarjeta.
data Side = SideLeft | SideRight
  deriving stock (Eq, Show)

-- | Donde abre la tabla de mando.
defaultControlSide :: Side
defaultControlSide = SideLeft

-- | El lado contrario: el del eje, respecto de la tabla de mando, también con la
-- tarjeta apilada.
otherSide :: Side -> Side
otherSide SideLeft  = SideRight
otherSide SideRight = SideLeft

-- | El reparto de la tarjeta a lo ancho, en px.
data CardLayout = CardLayout
  { clStacked    :: Bool
    -- ^ La tabla de mando arriba y la gráfica debajo, a todo el ancho.
  , clControl    :: Double
    -- ^ Ancho de la tabla de mando; con la tarjeta apilada, el de la tarjeta.
  , clChart      :: Double
    -- ^ Ancho de la columna de la gráfica, eje incluido.
  , clAxisInside :: Bool
    -- ^ Los números del eje van dentro de la gráfica y no en su columna.
  } deriving stock (Eq, Show)

-- | El reparto para un ancho por dentro de la tarjeta.
--
-- * Dos columnas mientras los valores de las fronteras quepan bajo la gráfica
--   ('valuesFit'); si no, apilada.
-- * El eje vertical va dentro cuando, en su columna, dejaría a la curva tan
--   estrecha que los valores no cabrían. Se decide igual en todos los modos.
cardLayout :: Double -> CardLayout
cardLayout inner
  | valuesFit twoColumnChart = layout False (controlWidth inner) twoColumnChart
  | otherwise                = layout True inner inner
  where
    twoColumnChart = inner - controlWidth inner - columnGap
    layout stacked control chart =
      CardLayout
        { clStacked    = stacked
        , clControl    = control
        , clChart      = chart
        , clAxisInside = not (valuesFit (chart - axisColumnWidth))
        }

-- | Ancho de la tabla de mando con dos columnas: un tercio de la tarjeta, nunca
-- menos que el desplegable de piloto ni más que 'controlMaxWidth'.
controlWidth :: Double -> Double
controlWidth inner = max carSelectWidth (min controlMaxWidth (inner / 3))

-- | Si el «VS» va a la derecha del desplegable de referencia en una tabla de mando
-- de ese ancho. El desplegable va centrado, así que el «VS» y su hueco (@--sp-2@)
-- tienen que caber en el margen que le queda; si no, va en su propia línea.
vsBeside :: Double -> Bool
vsBeside control = (control - carSelectWidth) / 2 >= 6 + vsWidth

-- | Si los cuatro valores de las fronteras caben sin pisarse bajo una gráfica de
-- ese ancho, colocados como 'Common.Chart.frontierCells': el primero hacia la
-- derecha de su punto, el último hacia la izquierda y los de en medio centrados.
valuesFit :: Double -> Bool
valuesFit width = and (zipWith (<=) (map snd spans) (drop 1 (map fst spans)))
  where
    xs    = [x / 100 * width | (x, _, _) <- frontierCells [0, 0, 0, 0]]
    lastI = length xs - 1
    spans = [span' i x | (i, x) <- zip [0 :: Int ..] xs]
    span' i x
      | i == 0     = (x, x + valueWidth)
      | i == lastI = (x - valueWidth, x)
      | otherwise  = (x - valueWidth / 2, x + valueWidth / 2)

-- | Los números del eje cuando van dentro de la gráfica: la X de su borde izquierdo
-- y la Y de su centro, en px dentro de una gráfica de ese ancho y
-- 'Common.Chart.chartHeight' de alto, y su etiqueta.
--
-- * Sin el cero: lo marca la línea discontinua.
-- * Cada número va pegado al borde del lado del eje, sobre su línea. Si la curva lo
--   tapa, se desliza hacia el otro borde lo justo para dejar de taparlo, sin pasar
--   de los tres cuartos del ancho: el cuarto del lado de la tabla de mando queda
--   libre.
-- * Si en esos tres cuartos no hay un tramo libre, no sale.
insideAxisLabels :: Side -> Double -> [Double] -> [(Double, Double, Text)]
insideAxisLabels side width xs =
  [ (x, y, label)
  | (v, y, label) <- axisTicks xs
  , v /= 0
  , Just x <- [place (blocked y)]
  ]
  where
    curve = [(px / chartWidth * width, py) | (px, py) <- axisPoints xs]
    reach = valueHeight / 2 + curveHalfStroke
    blocked y =
      mapMaybe (crossing (y - reach) (y + reach)) (zip curve (drop 1 curve))
        ++ [(px, px) | (px, py) <- curve, abs (py - y) <= reach]
    place spans = find (free spans) (candidates spans)
    free spans a =
      a >= lowest && a + valueWidth <= highest
        && not (any (\(s, e) -> a < e - 1e-9 && a + valueWidth > s + 1e-9) spans)
    candidates spans = case side of
      SideRight -> width - valueWidth : sortOn Down [s - valueWidth | (s, _) <- spans]
      SideLeft  -> 0 : sort [e | (_, e) <- spans]
    (lowest, highest) = case side of
      SideRight -> (width / 4, width)
      SideLeft  -> (0, width * 3 / 4)

-- | El tramo en X de un segmento de la curva cuya Y cae entre @lo@ y @hi@.
crossing :: Double -> Double -> ((Double, Double), (Double, Double)) -> Maybe (Double, Double)
crossing lo hi ((x1, y1), (x2, y2))
  | y1 == y2  = if lo <= y1 && y1 <= hi then Just (min x1 x2, max x1 x2) else Nothing
  | tMin > tMax = Nothing
  | otherwise = Just (at tMin, at tMax)
  where
    tA   = (lo - y1) / (y2 - y1)
    tB   = (hi - y1) / (y2 - y1)
    tMin = max 0 (min tA tB)
    tMax = min 1 (max tA tB)
    at t = x1 + t * (x2 - x1)

-- | Media anchura del trazo de la curva (@stroke-width@ 2).
curveHalfStroke :: Double
curveHalfStroke = 1

-- | Ancho de un valor con signo («+0.617 s»), medido con la base de 12 px de la
-- hoja. Los números del eje tienen la misma forma.
valueWidth :: Double
valueWidth = 39.6

-- | Alto de un valor, o de un número del eje.
valueHeight :: Double
valueHeight = 13.05

-- | Ancho del desplegable de piloto: el de su opción más larga.
carSelectWidth :: Double
carSelectWidth = 149

-- | Ancho del «VS» entre los desplegables.
vsWidth :: Double
vsWidth = 11.9

-- | El ancho máximo de la tabla de mando.
controlMaxWidth :: Double
controlMaxWidth = 225

-- | Hueco entre la tabla de mando y la gráfica (@--sp-4@).
columnGap :: Double
columnGap = 12

-- | Hueco entre la columna del eje y la curva.
axisGap :: Double
axisGap = 4

-- | Ancho de la columna del eje cuando va fuera de la gráfica: un número y su hueco.
axisColumnWidth :: Double
axisColumnWidth = valueWidth + axisGap

-- | Alto de la fila de fronteras con sus dos líneas y su margen (@2.5rem@ más
-- @--sp-1@).
valuesRowHeight :: Double
valuesRowHeight = 33

-- | Alto de la fila de fronteras con una sola línea y su margen: la línea, 4,95 px
-- de aire y @--sp-1@.
singleRowHeight :: Double
singleRowHeight = 21

-- | Relleno de la tarjeta, arriba y abajo juntos (@--sp-4@ dos veces).
cardPadding :: Double
cardPadding = 24
