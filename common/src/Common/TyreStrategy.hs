-- | Lo que Tyre Strategy calcula con la tabla en vivo, sin pintar nada: qué filas, en qué
-- orden, la escala de vueltas y, por stint, dónde empieza su barra, cuánto mide, de qué
-- color es y qué dice al pasar por encima.
module Common.TyreStrategy
  ( StintRow (..)
  , StintBar (..)
  , stintRows
  , stintScale
  , stintBar
  , barStyle
  , stintTitle
  , rowLabel
  , compoundClass
  , compoundLegend
  , scaleLabel
  , noStintsNotice
  ) where

import           Common.Types  (LapProgress (..), LiveTable (..),
                                LiveTimingRow (..), SessionInfo (..),
                                TyreStint (..))
import           Data.Function (on)
import           Data.List     (nubBy, sortOn)
import           Data.Maybe    (fromMaybe)
import           Data.Text     (Text)
import qualified Data.Text     as T
import           Numeric       (showFFloat)
import           Text.Read     (readMaybe)

-- | Una fila del widget: un coche y sus stints en orden.
data StintRow = StintRow
  { srPosition :: Maybe Int  -- ^ 'Nothing' si el coche tiene stints y no fila en la tabla.
  , srCar      :: Text
  , srDriver   :: Text
  , srBars     :: [StintBar]  -- ^ Vacía si el coche aún no tiene stints.
  }
  deriving stock (Eq, Show)

-- | La barra de un stint, en fracciones de la escala (de 0 a 1).
data StintBar = StintBar
  { sbStart :: Double
  , sbWidth :: Double  -- ^ 0 en un stint de 0 vueltas: el widget pinta una marca fina.
  , sbClass :: Text    -- ^ 'compoundClass'.
  , sbTitle :: Text    -- ^ 'stintTitle'.
  }
  deriving stock (Eq, Show)

-- | Una fila por cada fila de la tabla, por posición; después, los coches con stints y
-- sin fila, por número. Mientras se espera ('Common.Types.waitingTable') no hay ninguna.
stintRows :: LiveTable -> [StintRow]
stintRows t = map tableRow (sortOn ltPosition (liveRows t)) ++ map orphanRow orphans
  where
    stints   = liveStints t
    scale    = stintScale (liveSession t) stints
    barsOf c = map (stintBar scale) (filter ((== c) . tsCar) stints)
    tableRow r = StintRow (Just (ltPosition r)) (ltCar r) (ltDriver r) (barsOf (ltCar r))
    orphanRow (c, d) = StintRow Nothing c d (barsOf c)
    inTable  = map ltCar (liveRows t)
    orphans  = sortOn (carOrder . fst) (nubBy ((==) `on` fst)
                 [ (tsCar s, tsDriver s) | s <- stints, tsCar s `notElem` inTable ])
    carOrder c = (fromMaybe maxBound (readMaybe (T.unpack c)) :: Int, c)

-- | Las vueltas que mide el eje: en carrera, el total; fuera, la vuelta de fin más alta.
-- Nunca menos que esa vuelta (ninguna barra se sale) ni menos de 1.
stintScale :: Maybe SessionInfo -> [TyreStint] -> Int
stintScale session stints = maximum (1 : highest : total)
  where
    highest = maximum (0 : map tsEndLap stints)
    total   = maybe [] (pure . lpTotal) (siLaps =<< session)

-- | La barra de un stint contra una escala de vueltas.
stintBar :: Int -> TyreStint -> StintBar
stintBar scale s = StintBar
  { sbStart = fromIntegral (tsStartLap s - 1) / fromIntegral scale
  , sbWidth = fromIntegral (max 0 (tsLaps s)) / fromIntegral scale
  , sbClass = compoundClass (tsCompound s)
  , sbTitle = stintTitle s
  }

-- | El @style@ de la barra: @left: 25.000%; width: 9.375%@. Con ancho 0 la marca fina
-- la pone la hoja de estilos.
barStyle :: StintBar -> Text
barStyle b = "left: " <> percent (sbStart b) <> "; width: " <> percent (sbWidth b)
  where
    percent x = T.pack (showFFloat (Just 3) (100 * x) "") <> "%"

-- | Lo que va a la izquierda de la fila: @1 LEC@; sin fila en la tabla, solo el piloto.
rowLabel :: StintRow -> Text
rowLabel r = maybe "" (\p -> showT p <> " ") (srPosition r) <> srDriver r

-- | La leyenda, en su orden: la clase de cada compuesto y su letra.
compoundLegend :: [(Text, Text)]
compoundLegend =
  [ ("soft", "S"), ("medium", "M"), ("hard", "H"), ("intermediate", "I"), ("wet", "W")
  , ("unknown", "?") ]

-- | La escala al final de la leyenda: @32 vueltas@, o @1 vuelta@.
scaleLabel :: Int -> Text
scaleLabel 1 = "1 vuelta"
scaleLabel n = showT n <> " vueltas"

-- | El tooltip: @MEDIUM · vueltas 14–21 (8) · usado, edad 2 · mismo juego@. Con 0
-- vueltas, @desde la vuelta 3 (0)@; sin nuevo/usado, solo la edad; sin mismo juego, nada.
stintTitle :: TyreStint -> Text
stintTitle s = T.intercalate " · " ([tsCompound s, laps, wear] ++ sameSet)
  where
    sameSet = [ "mismo juego" | tsSameSet s == Just True ]
    laps
      | tsLaps s <= 0 = "desde la vuelta " <> showT (tsStartLap s) <> " (0)"
      | otherwise     = "vueltas " <> showT (tsStartLap s) <> "–" <> showT (tsEndLap s)
                        <> " (" <> showT (tsLaps s) <> ")"
    age  = "edad " <> showT (tsAge s)
    wear = case tsNew s of
      Just True  -> "nuevo, " <> age
      Just False -> "usado, " <> age
      Nothing    -> age

-- | La clase CSS del color: @soft@, @medium@, @hard@, @intermediate@ o @wet@; cualquier
-- otro compuesto (@UNKNOWN@ incluido), @unknown@.
compoundClass :: Text -> Text
compoundClass c
  | lower `elem` ["soft", "medium", "hard", "intermediate", "wet"] = lower
  | otherwise                                                       = "unknown"
  where
    lower = T.toLower c

-- | El aviso cuando la tabla no sale del feed, que es lo único que trae stints.
noStintsNotice :: Text
noStintsNotice = "Sin stints: salen del directo"

showT :: Int -> Text
showT = T.pack . show
