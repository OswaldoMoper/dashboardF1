-- | Lo que Tyre Strategy calcula con la tabla en vivo, sin pintar nada: qué filas, en qué
-- orden, la escala de vueltas y, por stint o por juego, dónde empieza su barra, cuánto
-- mide, de qué color es y qué dice al pasar por encima.
module Common.TyreStrategy
  ( StintRow (..)
  , StintBar (..)
  , SetRow (..)
  , SetBar (..)
  , stintRows
  , setRows
  , tyreSets
  , stintScale
  , stintBar
  , setBar
  , barNotches
  , barStyle
  , setStyle
  , leftStyle
  , stintTitle
  , rowLabel
  , compoundClass
  , compoundLegend
  , scaleLabel
  , lapTicks
  , gridLines
  , noStintsNotice
  , notOutYet
  ) where

import           Common.Types       (LapProgress (..), LiveTable (..),
                                     LiveTimingRow (..), SessionInfo (..),
                                     TyreStint (..))
import           Data.Function      (on)
import           Data.List          (nubBy, sortOn)
import           Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import           Data.Maybe         (fromMaybe)
import           Data.Text          (Text)
import qualified Data.Text          as T
import           Numeric            (showFFloat)
import           Text.Read          (readMaybe)

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

-- | Una fila del widget por juegos: un coche y sus juegos en orden.
data SetRow = SetRow
  { setPosition :: Maybe Int  -- ^ 'Nothing' si el coche tiene stints y no fila en la tabla.
  , setCar      :: Text
  , setDriver   :: Text
  , setBars     :: [SetBar]  -- ^ Vacía si el coche aún no tiene stints: 'notOutYet'.
  }
  deriving stock (Eq, Show)

-- | La barra de un juego ('tyreSets'), en fracciones de la escala (de 0 a 1).
data SetBar = SetBar
  { setStart   :: Double
  , setWidth   :: Double    -- ^ Las vueltas de todas sus salidas.
  , setClass   :: Text      -- ^ 'compoundClass' de la primera salida.
  , setTotal   :: Int       -- ^ La edad al montarlo más sus vueltas.
  , setUsed    :: Bool      -- ^ Ya venía usado al montarlo.
  , setNotches :: [Double]  -- ^ Dónde empieza cada salida tras la primera: un paso por boxes.
  , setTitle   :: Text
  }
  deriving stock (Eq, Show)

-- | Una fila por cada fila de la tabla, por posición; después, los coches con stints y
-- sin fila, por número. Mientras se espera ('Common.Types.waitingTable') no hay ninguna.
stintRows :: LiveTable -> [StintRow]
stintRows t =
  [ StintRow p c d (map (stintBar scale) ss) | (p, c, d, ss) <- carRows t ]
  where
    scale = stintScale (liveSession t) (liveStints t)

-- | Las mismas filas que 'stintRows', con una barra por juego.
setRows :: LiveTable -> [SetRow]
setRows t =
  [ SetRow p c d (map (setBar scale) (tyreSets ss)) | (p, c, d, ss) <- carRows t ]
  where
    scale = stintScale (liveSession t) (liveStints t)

-- | Cada coche con su posición, su número, su piloto y sus stints, en el orden de las filas.
carRows :: LiveTable -> [(Maybe Int, Text, Text, [TyreStint])]
carRows t = map tableRow (sortOn ltPosition (liveRows t)) ++ map orphanRow orphans
  where
    stints   = liveStints t
    stintsOf c = filter ((== c) . tsCar) stints
    tableRow r = (Just (ltPosition r), ltCar r, ltDriver r, stintsOf (ltCar r))
    orphanRow (c, d) = (Nothing, c, d, stintsOf c)
    inTable  = map ltCar (liveRows t)
    orphans  = sortOn (carOrder . fst) (nubBy ((==) `on` fst)
                 [ (tsCar s, tsDriver s) | s <- stints, tsCar s `notElem` inTable ])
    carOrder c = (fromMaybe maxBound (readMaybe (T.unpack c)) :: Int, c)

-- | Los stints de un coche, en su orden, partidos en juegos: un stint «mismo juego» va
-- con el anterior; cualquier otro abre juego, también el primero aunque diga «mismo juego».
tyreSets :: [TyreStint] -> [NonEmpty TyreStint]
tyreSets = foldr step []
  where
    step s ((next :| rest) : sets) | tsSameSet next == Just True = (s :| (next : rest)) : sets
    step s sets                                                   = (s :| []) : sets

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

-- | La barra de un juego contra una escala de vueltas. El total no cuenta vueltas negativas.
setBar :: Int -> NonEmpty TyreStint -> SetBar
setBar scale pieces@(first :| rest) = SetBar
  { setStart   = fraction (tsStartLap first - 1)
  , setWidth   = fraction laps
  , setClass   = compoundClass (tsCompound first)
  , setTotal   = tsAge first + laps
  , setUsed    = tsNew first == Just False
  , setNotches = map (fraction . subtract 1 . tsStartLap) rest
  , setTitle   = setTitleOf pieces
  }
  where
    laps       = sum (map (max 0 . tsLaps) (NE.toList pieces))
    fraction n = fromIntegral n / fromIntegral scale

-- | Dónde va cada muesca dentro de su barra, en fracción de la barra (de 0 a 1). En una
-- barra de ancho 0, todas en 0.
barNotches :: SetBar -> [Double]
barNotches b
  | setWidth b <= 0 = map (const 0) (setNotches b)
  | otherwise       = [ (n - setStart b) / setWidth b | n <- setNotches b ]

-- | El @style@ de la barra: @left: 25.000%; width: 9.375%@. Con ancho 0 la marca fina
-- la pone la hoja de estilos.
barStyle :: StintBar -> Text
barStyle b = "left: " <> percent (sbStart b) <> "; width: " <> percent (sbWidth b)

-- | El @style@ de la barra de un juego, como 'barStyle'.
setStyle :: SetBar -> Text
setStyle b = "left: " <> percent (setStart b) <> "; width: " <> percent (setWidth b)

-- | El @style@ de lo que se pinta en un punto de la pista (una muesca, una raya de la
-- rejilla, una marca del eje): @left: 15.000%@.
leftStyle :: Double -> Text
leftStyle x = "left: " <> percent x

percent :: Double -> Text
percent x = T.pack (showFFloat (Just 3) (100 * x) "") <> "%"

-- | Lo que va a la izquierda de la fila: @1 LEC@; sin fila en la tabla, solo el piloto.
rowLabel :: SetRow -> Text
rowLabel r = maybe "" (\p -> showT p <> " ") (setPosition r) <> setDriver r

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
stintTitle s =
  T.intercalate " · "
    ([tsCompound s, lapsText (tsStartLap s) (tsEndLap s) (tsLaps s), wearText s] ++ sameSet)
  where
    sameSet = [ "mismo juego" | tsSameSet s == Just True ]

-- | El tooltip de un juego: @MEDIUM · vueltas 1–10 (10) · nuevo, edad 0 · 3 salidas: 1–3,
-- 4–7, 8–10@, con la edad y nuevo/usado de la primera salida; una salida de 0 vueltas, @15
-- (0)@. Un juego de una sola salida, 'stintTitle'.
setTitleOf :: NonEmpty TyreStint -> Text
setTitleOf (s :| []) = stintTitle s
setTitleOf pieces@(first :| _) =
  T.intercalate " · "
    [tsCompound first, lapsText start (start + laps - 1) laps, wearText first, outings]
  where
    start   = tsStartLap first
    laps    = sum (map (max 0 . tsLaps) (NE.toList pieces))
    outings = showT (length pieces) <> " salidas: "
              <> T.intercalate ", " (map outing (NE.toList pieces))
    outing p
      | tsLaps p <= 0 = showT (tsStartLap p) <> " (0)"
      | otherwise     = showT (tsStartLap p) <> "–" <> showT (tsEndLap p)

-- | @vueltas 14–21 (8)@ con la vuelta de inicio, la de fin y las vueltas; con 0 vueltas,
-- @desde la vuelta 3 (0)@.
lapsText :: Int -> Int -> Int -> Text
lapsText start end laps
  | laps <= 0 = "desde la vuelta " <> showT start <> " (0)"
  | otherwise = "vueltas " <> showT start <> "–" <> showT end <> " (" <> showT laps <> ")"

-- | @nuevo, edad 0@, @usado, edad 2@, o solo @edad 0@ sin nuevo/usado.
wearText :: TyreStint -> Text
wearText s = case tsNew s of
  Just True  -> "nuevo, " <> age
  Just False -> "usado, " <> age
  Nothing    -> age
  where
    age = "edad " <> showT (tsAge s)

-- | La clase CSS del color: @soft@, @medium@, @hard@, @intermediate@ o @wet@; cualquier
-- otro compuesto (@UNKNOWN@ incluido), @unknown@.
compoundClass :: Text -> Text
compoundClass c
  | lower `elem` ["soft", "medium", "hard", "intermediate", "wet"] = lower
  | otherwise                                                       = "unknown"
  where
    lower = T.toLower c

-- | Las marcas del eje, con su vuelta y su fracción de la escala: desde 0, cada 5 vueltas, o
-- cada 10 si la escala pasa de 30.
lapTicks :: Int -> [(Int, Double)]
lapTicks scale = [ (lap, fromIntegral lap / fromIntegral scale) | lap <- [0, step .. scale] ]
  where
    step = if scale > 30 then 10 else 5

-- | Las rayas de la rejilla: las marcas de 'lapTicks' sin la primera ni la del final de la
-- escala, que son los bordes de la pista.
gridLines :: Int -> [Double]
gridLines scale = [ x | (lap, x) <- lapTicks scale, lap > 0, lap < scale ]

-- | El aviso cuando la tabla no sale del feed, que es lo único que trae stints.
noStintsNotice :: Text
noStintsNotice = "Sin stints: salen del directo"

-- | Lo que dice la fila de un coche que aún no tiene stints.
notOutYet :: Text
notOutYet = "aún sin salir a pista"

showT :: Int -> Text
showT = T.pack . show
