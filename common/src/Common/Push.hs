-- | El __empuje__ del arrastre: dónde queda cada widget cuando uno se mueve o se
-- estira encima de los demás.
--
-- Puro, y siempre sobre la __foto__: entra el layout tal como estaba al coger la
-- tarjeta y el gesto de ese instante, y sale el layout entero o 'Nothing' si no
-- cabe («no se deja»). Quien arrastra guarda la foto y vuelve a llamar con cada
-- movimiento, así que seguir de largo deshace lo empujado sin memoria ninguna.
--
-- Las reglas, en unidades de 'Common.Layout.canvasSpan':
--
-- * La tarjeta que se lleva no encoge nunca; se queda dentro del lienzo.
-- * Cada tarjeta pisada se aparta por el eje en que el solape es más corto (en
--   empate, en vertical), hacia el lado donde queda su mayor parte, y si por ahí
--   no cabe, por el otro. En una misma columna o fila se reordena, sin probar el
--   otro eje (el detalle, en 'ways').
-- * Lo apartado empuja a lo que tiene delante, en cadena. Si la cadena se sale
--   del lienzo, encoge entera en proporción, solo en ese eje, con cada tamaño
--   redondeado a la rejilla, y la del borde se queda con lo que sobre o falte.
--   Nadie baja de su mínimo ('Common.Layout.minWidthFor', 'minHeightFor').
-- * Los huecos no se rellenan: nada se mueve si no lo pisan.
module Common.Push
  ( Drag (..)
  , applyDrag
  ) where

import           Common.Layout (canvasSpan, fitsAt, minHeightFor, minWidthFor,
                                overlaps)
import           Common.Types  (WidgetConfig (..), WidgetId)
import           Control.Monad (guard)
import           Data.Foldable (asum)
import           Data.List     (find, sortOn)
import           Data.Maybe    (fromMaybe)

-- | El gesto sobre una tarjeta, en unidades del lienzo.
data Drag
  = MoveTo WidgetId Int Int
    -- ^ Su esquina de arriba a la izquierda va a @(x, y)@.
  | ResizeTo WidgetId Int Int
    -- ^ Su ancho y su alto pasan a ser esos.
  deriving stock (Eq, Show)

-- | El layout tras el gesto, en el mismo orden que la foto, o 'Nothing' si no cabe
-- o si el gesto nombra un widget que no está.
--
-- El primer argumento son las divisiones del imán, como en
-- 'Common.Layout.snapTo': con @<= 0@ (imán apagado) los tamaños encogidos se
-- redondean de 1 en 1. El gesto llega ya pegado a la rejilla: aquí solo se recorta
-- al lienzo y a los mínimos.
--
-- Si sale 'Just', ningún par se solapa y todos pasan 'Common.Layout.fitsAt'.
applyDrag :: Int -> [WidgetConfig] -> Drag -> Maybe [WidgetConfig]
applyDrag divisions photo drag = do
  held <- find ((== dragged drag) . widgetId) photo
  let a = place drag held
  final <- settle (stepOf divisions) photo [widgetId a] [a] (replace a photo)
  guard (all fitsAt final && not (anyOverlap final))
  pure final

-- | El widget del gesto.
dragged :: Drag -> WidgetId
dragged (MoveTo wid _ _)   = wid
dragged (ResizeTo wid _ _) = wid

-- | La tarjeta que se lleva, con el gesto aplicado: movida dentro del lienzo, o
-- estirada sin bajar de sus mínimos ni salirse.
place :: Drag -> WidgetConfig -> WidgetConfig
place (MoveTo _ x y) w =
  w { wcX = within 0 (canvasSpan - wcW w) x, wcY = within 0 (canvasSpan - wcH w) y }
place (ResizeTo _ width height) w =
  w { wcW = within (minWidthFor t) (canvasSpan - wcX w) width
    , wcH = within (minHeightFor t) (canvasSpan - wcY w) height
    }
  where t = widgetType w

within :: Int -> Int -> Int -> Int
within lo hi = max lo . min hi

-- | El paso al que se redondea un tamaño encogido.
stepOf :: Int -> Int
stepOf divisions
  | divisions <= 0 = 1
  | otherwise      = max 1 (canvasSpan `div` divisions)

-- | Aparta, una a una, las tarjetas que pisa cada tarjeta ya colocada. Una tarjeta
-- colocada (la que se lleva, o una ya apartada) no se vuelve a mover.
settle
  :: Int -> [WidgetConfig] -> [WidgetId] -> [WidgetConfig] -> [WidgetConfig]
  -> Maybe [WidgetConfig]
settle _ _ _ [] current = Just current
settle step photo fixed (p : queue) current =
  case [q | q <- current, widgetId q `notElem` fixed, overlaps p q] of
    []    -> settle step photo fixed queue current
    q : _ -> do
      let p0 = fromMaybe p (find ((== widgetId p) . widgetId) photo)
      (current', moved) <- asum [pushChain step fixed current p q way | way <- ways p0 p q]
      settle step photo (fixed <> map widgetId moved) (p : queue <> moved) current'

-- | Hacia dónde se aparta @q@ de @p@, en el orden en que se prueba; @p0@ es @p@ en
-- la foto.
--
-- * Si @p@ tapa todo el ancho de @q@ y no todo su alto (misma columna), solo en
--   vertical; si tapa todo su alto y no todo su ancho (misma fila), solo en
--   horizontal. Si ahí no cabe, no se deja.
-- * Si la tapa entera y @p@ se movió desde la foto, primero hacia el sitio que ha
--   dejado libre, por el eje en que más se movió; si solo creció, hacia donde
--   crece. En empate, el vertical.
-- * Si no, por el eje del solape más corto (en empate, el vertical), y después el
--   otro.
--
-- El sentido es hacia donde queda la mayor parte de @q@; con los centros a la
-- misma altura, hacia el sitio que dejó @p@, y si no se movió, abajo o a la derecha.
ways :: WidgetConfig -> WidgetConfig -> WidgetConfig -> [Way]
ways p0 p q = case (ow >= wcW q, oh >= wcH q) of
  (True, False) -> [vertical]
  (False, True) -> [horizontal]
  (True, True)
    | dy /= 0 && abs dy >= abs dx -> [back dy Down Up, horizontal]
    | dx /= 0                     -> [back dx Rightward Leftward, vertical]
    | dh /= 0 && abs dh >= abs dw -> [growth dh Down Up, horizontal]
    | dw /= 0                     -> [growth dw Rightward Leftward, vertical]
  _ | oh <= ow                    -> [vertical, horizontal]
    | otherwise                   -> [horizontal, vertical]
  where
    oh = spanOverlap (along Down p) (along Down q)
    ow = spanOverlap (along Rightward p) (along Rightward q)
    dx = wcX p - wcX p0
    dy = wcY p - wcY p0
    dw = wcW p - wcW p0
    dh = wcH p - wcH p0
    -- Hacia donde estaba @p@: si subió (@d < 0@), abajo.
    back d forward backward = if d <= 0 then forward else backward
    -- Hacia donde crece @p@.
    growth d forward backward = if d >= 0 then forward else backward
    vertical   = away Down Up dy
    horizontal = away Rightward Leftward dx
    away forward backward d = case compare (centre (along forward q)) (centre (along forward p)) of
      GT -> forward
      LT -> backward
      EQ -> back d forward backward

-- | Un sentido de empuje.
data Way = Down | Up | Rightward | Leftward
  deriving stock (Eq, Show)

-- | Inicio y tamaño a lo largo del sentido, contados desde el borde del que el
-- empuje se aleja: así los cuatro sentidos se resuelven como «hacia abajo».
along :: Way -> WidgetConfig -> (Int, Int)
along Down      w = (wcY w, wcH w)
along Up        w = (canvasSpan - wcY w - wcH w, wcH w)
along Rightward w = (wcX w, wcW w)
along Leftward  w = (canvasSpan - wcX w - wcW w, wcW w)

setAlong :: Way -> (Int, Int) -> WidgetConfig -> WidgetConfig
setAlong Down      (s, z) w = w { wcY = s, wcH = z }
setAlong Up        (s, z) w = w { wcY = canvasSpan - s - z, wcH = z }
setAlong Rightward (s, z) w = w { wcX = s, wcW = z }
setAlong Leftward  (s, z) w = w { wcX = canvasSpan - s - z, wcW = z }

-- | El tramo en el otro eje.
across :: Way -> WidgetConfig -> (Int, Int)
across way w
  | isVertical way = (wcX w, wcW w)
  | otherwise      = (wcY w, wcH w)

minAlong :: Way -> WidgetConfig -> Int
minAlong way w
  | isVertical way = minHeightFor (widgetType w)
  | otherwise      = minWidthFor (widgetType w)

isVertical :: Way -> Bool
isVertical way = way == Down || way == Up

-- | Dos veces el centro de un tramo: compara centros sin dividir.
centre :: (Int, Int) -> Int
centre (s, z) = 2 * s + z

-- | Cuánto se solapan dos tramos; cero o menos si no se tocan.
spanOverlap :: (Int, Int) -> (Int, Int) -> Int
spanOverlap (s1, z1) (s2, z2) = min (s1 + z1) (s2 + z2) - max s1 s2

-- | Aparta @q@ de @p@ en ese sentido, con todo lo que tenga delante, y devuelve
-- el layout y las tarjetas movidas; 'Nothing' si no caben ni encogiendo, o si al
-- apartarse pisarían una tarjeta ya colocada.
pushChain
  :: Int -> [WidgetId] -> [WidgetConfig] -> WidgetConfig -> WidgetConfig -> Way
  -> Maybe ([WidgetConfig], [WidgetConfig])
pushChain step fixed current p q way = do
  let chain = grow [q]
  sizes <- chainSizes step way p chain
  let moved = [ setAlong way (s, z) m | (m, s, z) <- sizes ]
  guard (not (or [overlaps m f | m <- moved, f <- current, widgetId f `elem` fixed]))
  pure (foldr replace current moved, moved)
  where
    grow ms =
      let placed = starts way p (sizeOf way) ms
          ahead  = [ r | r <- current
                       , widgetId r `notElem` (fixed <> map widgetId ms)
                       , any (hits r) placed ]
      in if null ahead then ms else grow (ms <> ahead)
    hits r (s, st) =
      spanOverlap (across way s) (across way r) > 0
        && centre (along way r) >= centre (along way s)
        && spanOverlap (st, sizeOf way s) (along way r) > 0

sizeOf :: Way -> WidgetConfig -> Int
sizeOf way = snd . along way

-- | Dónde empieza cada tarjeta de la cadena con esos tamaños: donde estaba, o
-- detrás de lo que la empuja (@p@ o una anterior de la cadena), lo que quede más
-- lejos.
starts :: (Ord a, Num a) => Way -> WidgetConfig -> (WidgetConfig -> a) -> [WidgetConfig] -> [(WidgetConfig, a)]
starts way p size chain = foldl' next [] (sortOn (fst . along way) chain)
  where
    pEnd = fromIntegral (uncurry (+) (along way p))
    next done m =
      let from = [ pEnd | spanOverlap (across way p) (across way m) > 0 ]
              <> [ st + size d | (d, st) <- done
                               , spanOverlap (across way d) (across way m) > 0 ]
      in done <> [(m, maximum (fromIntegral (fst (along way m)) : from))]

-- | Inicio y tamaño de cada tarjeta de la cadena. Si con sus tamaños se sale del
-- lienzo, encogen todas en proporción (sin bajar de su mínimo), cada tamaño
-- redondeado al paso, y las que acaban en el borde se quedan con la diferencia.
chainSizes :: Int -> Way -> WidgetConfig -> [WidgetConfig] -> Maybe [(WidgetConfig, Int, Int)]
chainSizes step way p chain
  | reach (sizeOf way) <= canvasSpan = Just (withSizes (sizeOf way))
  | reachD 0 > span' = Nothing
  | otherwise = do
      let f      = bisect 0 1 (40 :: Int)
          scaled = [ (widgetId m, max (minAlong way m) (roundTo step (f * orig m))) | m <- chain ]
          size m = fromMaybe (sizeOf way m) (lookup (widgetId m) scaled)
          placed = withSizes size
          excess = maximum [ s + z | (_, s, z) <- placed ] - canvasSpan
          edge   = maximum [ s + z | (_, s, z) <- placed ]
          final  = [ if s + z == edge then (m, s, z - excess) else (m, s, z) | (m, s, z) <- placed ]
      guard (and [ z >= minAlong way m && z > 0 | (m, _, z) <- final ])
      pure final
  where
    span' = fromIntegral canvasSpan :: Double
    orig m = fromIntegral (sizeOf way m) :: Double
    withSizes size = [ (m, st, size m) | (m, st) <- starts way p size chain ]
    reach size = maximum [ st + size m | (m, st) <- starts way p size chain ]
    sizeD f m = max (fromIntegral (minAlong way m)) (f * orig m)
    reachD f = maximum [ st + sizeD f m | (m, st) <- starts way p (sizeD f) chain ]
    bisect lo hi n
      | n <= 0              = lo
      | reachD mid <= span' = bisect mid hi (n - 1)
      | otherwise           = bisect lo mid (n - 1)
      where mid = (lo + hi) / 2

-- | Redondea al múltiplo del paso más cercano (la mitad, hacia arriba).
roundTo :: Int -> Double -> Int
roundTo step v = step * floor (v / fromIntegral step + 0.5)

-- | La lista con ese widget sustituido, en su sitio.
replace :: WidgetConfig -> [WidgetConfig] -> [WidgetConfig]
replace w = map (\x -> if widgetId x == widgetId w then w else x)

anyOverlap :: [WidgetConfig] -> Bool
anyOverlap ws = or [ overlaps a b | (i, a) <- zip [0 :: Int ..] ws, (j, b) <- zip [0 ..] ws, i < j ]
