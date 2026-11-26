-- | Cómo se mezclan las dos tintas de un piloto en una curva: tramos, barbero o espiga, las
-- tres del mismo grosor y con sus medidas sobre el largo de la línea (2026-11-20 (z)). Todo va
-- en píxeles de pantalla: sobre un @viewBox@ estirado un tramo mediría distinto en subida que
-- en llano.
--
-- Puro. Quien pinta pone la línea entera en la primera tinta y encima lo que diga
-- 'blendOverlay' en la segunda, recortado por la propia línea.
module Common.Blend
  ( -- * La mezcla
    Blend (..)
  , blendsInOrder
  , defaultBlend
  , blendKey
  , blendFromKey
  , blendLabel
  , blendStoreKey
  , blendOnOpen
    -- * Las medidas
  , lineWidth
  , dashLength
  , markPeriod
    -- * La segunda tinta
  , Point
  , Mark (..)
  , Overlay (..)
  , blendOverlay
  , pointsAlong
  , pointsAttr
  , toPixels
  ) where

import           Common.Format (formatFixed)
import           Data.List     (find)
import           Data.Maybe    (fromMaybe)
import           Data.Text     (Text)
import qualified Data.Text     as T

-- | Las tres mezclas, elegidas en ☰ para todas las gráficas.
data Blend = Tramos | Barbero | Espiga
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | En el orden del selector.
blendsInOrder :: [Blend]
blendsInOrder = [minBound .. maxBound]

-- | La de quien no ha elegido.
defaultBlend :: Blend
defaultBlend = Tramos

-- | La clave con que se guarda y se lee.
blendKey :: Blend -> Text
blendKey Tramos  = "tramos"
blendKey Barbero = "barbero"
blendKey Espiga  = "espiga"

-- | 'Nothing' para una clave que no es de ninguna.
blendFromKey :: Text -> Maybe Blend
blendFromKey k = find ((== k) . blendKey) blendsInOrder

-- | El nombre en el selector.
blendLabel :: Blend -> Text
blendLabel Tramos  = "Tramos"
blendLabel Barbero = "Barbero"
blendLabel Espiga  = "Espiga"

-- | Dónde guarda el navegador la mezcla elegida, con su 'blendKey'. Es una para todas las
-- pestañas.
blendStoreKey :: Text
blendStoreKey = "dashboardF1.mezcla"

-- | La mezcla al abrir, desde lo guardado: 'defaultBlend' si no hay nada o no es de ninguna.
blendOnOpen :: Maybe Text -> Blend
blendOnOpen saved = fromMaybe defaultBlend (blendFromKey =<< saved)

-- | El grosor de la línea, en px, igual en las tres.
lineWidth :: Double
lineWidth = 3.5

-- | El largo de cada tramo, en px de línea.
dashLength :: Double
dashLength = 6

-- | Cada cuántos px de línea va una raya del barbero o una uve de la espiga.
markPeriod :: Double
markPeriod = 14

-- | Un punto en px de pantalla.
type Point = (Double, Double)

-- | Un trazo de la segunda tinta: una polilínea abierta y su grosor.
data Mark = Mark
  { markPoints :: [Point]
  , markWidth  :: Double
  }
  deriving stock (Eq, Show)

-- | Lo que va encima de la línea en la segunda tinta.
data Overlay
  = Dashed Double
    -- ^ La misma línea, a trazos de este largo con huecos iguales.
  | Marks [Mark]
    -- ^ Trazos sueltos, que pasan del borde de la línea: hay que recortarlos con ella.
  deriving stock (Eq, Show)

-- | La segunda tinta de una curva dada en px.
blendOverlay :: Blend -> [Point] -> Overlay
blendOverlay Tramos  _   = Dashed dashLength
blendOverlay Barbero pts = Marks (map stripe (pointsAlong markPeriod pts))
blendOverlay Espiga  pts = Marks (map chevron (pointsAlong markPeriod pts))

-- | Una raya cruzada de borde a borde, inclinada 40° respecto a la perpendicular a la línea.
stripe :: (Point, Point) -> Mark
stripe ((x, y), (tx, ty)) =
  Mark [(x + nx * w + tx * k, y + ny * w + ty * k), (x - nx * w - tx * k, y - ny * w - ty * k)]
       (markPeriod / 2 * cos tilt)
  where
    (nx, ny) = (-ty, tx)
    w = lineWidth
    k = tan tilt * w
    tilt = 40 * pi / 180

-- | Una uve que apunta hacia donde avanza la línea.
chevron :: (Point, Point) -> Mark
chevron ((x, y), (tx, ty)) =
  Mark [ (x - tx * h + nx * w, y - ty * h + ny * w)
       , (x + tx * h, y + ty * h)
       , (x - tx * h - nx * w, y - ty * h - ny * w) ]
       (markPeriod * 0.3)
  where
    (nx, ny) = (-ty, tx)
    w = lineWidth
    h = markPeriod * 0.45 / 2

-- | El punto y la dirección (vector unitario) de la polilínea cada @period@ px de largo,
-- desde su principio: en @0@, @period@, @2·period@… mientras no se llegue al final. Los
-- tramos de largo cero no cuentan. Vacía con @period <= 0@ o con menos de dos puntos.
pointsAlong :: Double -> [Point] -> [(Point, Point)]
pointsAlong period
  | period <= 0 = const []
  | otherwise   = go 0
  where
    go o (a@(x1, y1) : rest@((x2, y2) : _))
      | len <= 0  = go o rest
      | o < len   = ((x1 + tx * o, y1 + ty * o), (tx, ty)) : go (o + period) (a : rest)
      | otherwise = go (o - len) rest
      where
        len = sqrt ((x2 - x1) ^ (2 :: Int) + (y2 - y1) ^ (2 :: Int))
        tx = (x2 - x1) / len
        ty = (y2 - y1) / len
    go _ _ = []

-- | El atributo @points@ de una polilínea en px, con dos decimales.
pointsAttr :: [Point] -> Text
pointsAttr = T.unwords . map (\(x, y) -> formatFixed 2 x <> "," <> formatFixed 2 y)

-- | Un punto de un @viewBox@ (x, y, ancho, alto) estirado sin conservar la proporción a una
-- caja de ese ancho y alto en px, en px de esa caja.
toPixels :: (Double, Double, Double, Double) -> (Double, Double) -> Point -> Point
toPixels (vx, vy, vw, vh) (bw, bh) (x, y) = ((x - vx) * bw / vw, (y - vy) * bh / vh)
