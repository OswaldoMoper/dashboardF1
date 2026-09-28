-- | Las reglas de la tarjeta de Lap Comparison que dependen de su tamaño: el ancho
-- de la tabla de mando, cuándo se apila, cuándo el eje entra en la gráfica y qué
-- modo de la gráfica se puede elegir.
--
-- Puro: entra el tamaño medido de la tarjeta (en px, por dentro) y salen
-- decisiones. Quien mide y pinta es 'Widgets.Comparison'.
module Common.ComparisonCard
  ( -- * Modos de la gráfica
    ChartMode (..)
  , defaultMode
  , modesInOrder
  , modeLabel
  , modeOption
  , modeEnabled
  , shownMode
  , valuesRowFits
    -- * Lado de la tabla de mando
  , Side (..)
  , defaultControlSide
  , otherSide
    -- * Anchos
  , CardLayout (..)
  , cardLayout
  , controlWidth
  , valuesFit
    -- * Medidas
  , valueWidth
  , valueHeight
  , carSelectWidth
  , compareButtonWidth
  , modeSelectWidth
  , controlGap
  , columnGap
  , axisGap
  , valuesRowHeight
  ) where

import           Common.Chart (frontierCells)
import           Data.Text    (Text)

-- | Qué números acompañan a la curva.
data ChartMode
  = ModeValues      -- ^ El valor de cada frontera debajo de la gráfica.
  | ModeAxis        -- ^ Los números del eje, sin la fila de valores.
  | ModeAxisValues  -- ^ Las dos cosas.
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | El modo con el que abre la tarjeta.
defaultMode :: ChartMode
defaultMode = ModeValues

-- | El orden de la lista del desplegable.
modesInOrder :: [ChartMode]
modesInOrder = [minBound .. maxBound]

-- | El texto del modo en el desplegable.
modeLabel :: ChartMode -> Text
modeLabel ModeValues     = "Valores"
modeLabel ModeAxis       = "Solo eje"
modeLabel ModeAxisValues = "Eje y valores"

-- | Si el modo se puede elegir, sabiendo si cabe la fila de valores
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

-- | El modo que se pinta a partir del elegido: «Eje y valores» sin sitio para la
-- fila se ve como «Solo eje», y vuelve solo en cuanto cabe. La elección no se
-- toca.
shownMode :: Bool -> ChartMode -> ChartMode
shownMode valuesFitHere m
  | modeEnabled valuesFitHere m = m
  | otherwise                   = ModeAxis

-- | Si la fila de valores cabe sin que la tarjeta pida scroll: el alto por dentro
-- de la tarjeta y el de su contenido __sin__ esa fila, los dos medidos.
valuesRowFits :: Double -> Double -> Bool
valuesRowFits innerHeight contentWithoutValues =
  contentWithoutValues + valuesRowHeight <= innerHeight

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
-- * Dos columnas mientras la fila de valores quepa bajo la gráfica ('valuesFit');
--   si no, apilada.
-- * El eje va dentro cuando, en su columna, dejaría a la curva tan estrecha que la
--   fila de valores no cabría. Se decide igual en los modos sin fila de valores.
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
        , clAxisInside = not (valuesFit (chart - valueWidth - axisGap))
        }

-- | Ancho de la tabla de mando con dos columnas: un tercio de la tarjeta, nunca
-- menos que el desplegable de piloto ni más que «Comparar» y el desplegable de
-- modos juntos.
controlWidth :: Double -> Double
controlWidth inner =
  max carSelectWidth (min (compareButtonWidth + controlGap + modeSelectWidth) (inner / 3))

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

-- | Ancho de un valor con signo («+0.617 s») en la letra fija de 12 px. Los
-- números del eje tienen la misma forma.
valueWidth :: Double
valueWidth = 52.8

-- | Alto de un valor, o de un número del eje.
valueHeight :: Double
valueHeight = 17.4

-- | Ancho del desplegable de piloto: el de su opción más larga.
carSelectWidth :: Double
carSelectWidth = 191

-- | Ancho de «Comparar».
compareButtonWidth :: Double
compareButtonWidth = 84.2

-- | Ancho del desplegable de modos: el de su opción más larga, «Eje y valores (no
-- cabe)».
modeSelectWidth :: Double
modeSelectWidth = 176

-- | Hueco entre controles de la tabla de mando (@--sp-2@).
controlGap :: Double
controlGap = 8

-- | Hueco entre la tabla de mando y la gráfica (@--sp-4@).
columnGap :: Double
columnGap = 16

-- | Hueco entre la columna del eje y la curva.
axisGap :: Double
axisGap = 4

-- | Alto de la fila de valores con su margen (@2.5rem@ más @--sp-1@).
valuesRowHeight :: Double
valuesRowHeight = 44
