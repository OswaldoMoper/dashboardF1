-- | El __arrastre__ de una tarjeta en el modo edición, sin DOM: qué se lleva, dónde
-- se pinta mientras se lleva, dónde caerá y qué queda al soltar.
--
-- La página traduce el ratón y el teclado a 'Hand' y pinta la 'Scene'. Mientras se
-- lleva una tarjeta, 'boardLayout' es la __foto__ —el layout de antes de cogerla— y
-- no cambia hasta soltar; el empuje de cada instante lo calcula
-- 'Common.Push.applyDrag' sobre ella.
module Common.Carry
  ( Board (..)
  , Carry (..)
  , Grip (..)
  , Hand (..)
  , Held (..)
  , Scene (..)
  , boardOf
  , heldStyle
  , magnetDivisions
  , scene
  , stepBoard
  ) where

import           Common.Layout (canvasSpan, gridDivisions, minHeightFor,
                                minWidthFor, snapTo)
import           Common.Push   (Drag (..), applyDrag)
import           Common.Types  (WidgetConfig (..), WidgetId)
import           Data.List     (find)
import           Data.Maybe    (fromMaybe, isJust)
import           Data.Text     (Text)
import qualified Data.Text     as T
import           Numeric       (showFFloat)

-- | El layout de una capa y, si se está llevando una tarjeta, el gesto.
data Board = Board
  { boardLayout :: [WidgetConfig]
  , boardCarry  :: Maybe Carry
  } deriving stock (Eq, Show)

-- | Por dónde se coge la tarjeta: por el título se mueve; por la esquina ◢ se estira.
data Grip = ByTitle | ByCorner
  deriving stock (Eq, Show)

-- | Una tarjeta cogida: cuál y por dónde, dónde estaba el puntero al cogerla y dónde
-- está ahora (en px de la ventana), cuántos px mide una unidad del lienzo en cada
-- eje, y si Alt está pulsado.
data Carry = Carry
  { carryId   :: WidgetId
  , carryGrip :: Grip
  , carryFrom :: (Double, Double)
  , carryAt   :: (Double, Double)
  , carryUnit :: (Double, Double)
  , carryAlt  :: Bool
  } deriving stock (Eq, Show)

-- | Lo que llega del ratón y del teclado.
data Hand
  = Press WidgetId Grip (Double, Double) (Double, Double)
    -- ^ Coger esa tarjeta por ahí, con el puntero ahí; el ancho y el alto del
    -- lienzo, en px.
  | Point (Double, Double) Bool
    -- ^ El puntero se mueve, con Alt pulsado o no.
  | AltKey Bool
  | Release
  | Cancel
  deriving stock (Eq, Show)

-- | La tarjeta que se lleva, como se pinta: su rectángulo en unidades del lienzo,
-- sin pegar a la rejilla, y si donde está se deja soltar.
data Held = Held
  { heldId   :: WidgetId
  , heldX    :: Double
  , heldY    :: Double
  , heldW    :: Double
  , heldH    :: Double
  , heldFits :: Bool
  } deriving stock (Eq, Show)

-- | Lo que se pinta: cada tarjeta en su sitio (el del empuje, o la foto si no se deja),
-- la que se lleva, y el contorno de donde caerá ('Nothing' si no se deja).
data Scene = Scene
  { sceneCards  :: [WidgetConfig]
  , sceneHeld   :: Maybe Held
  , sceneTarget :: Maybe WidgetConfig
  } deriving stock (Eq, Show)

-- | Un layout sin nada cogido.
boardOf :: [WidgetConfig] -> Board
boardOf l = Board l Nothing

-- | Las divisiones del imán para 'applyDrag': la rejilla si está encendido y sin
-- Alt, o apagado y con Alt; si no, 0 (de 1 en 1).
magnetDivisions :: Bool -> Bool -> Int
magnetDivisions on alt
  | on /= alt = gridDivisions
  | otherwise = 0

-- | El tablero tras lo que llega, con el imán encendido o no. Coger mientras ya se
-- lleva otra, una tarjeta que no está o con un lienzo sin tamaño no hace nada, y
-- moverse o soltar sin llevar nada tampoco. Soltar donde no se deja y Esc dejan la
-- foto.
stepBoard :: Bool -> Hand -> Board -> Board
stepBoard magnet hand b = case (hand, boardCarry b) of
  (Press wid grip p (w, h), Nothing)
    | w > 0, h > 0, any ((== wid) . widgetId) photo ->
        b { boardCarry = Just (Carry wid grip p p (w / units, h / units) False) }
  (Point p alt, Just c) -> b { boardCarry = Just c { carryAt = p, carryAlt = alt } }
  (AltKey alt, Just c)  -> b { boardCarry = Just c { carryAlt = alt } }
  (Release, Just c)     -> Board (fromMaybe photo (pushed magnet photo c)) Nothing
  (Cancel, Just _)      -> Board photo Nothing
  _                     -> b
  where
    photo = boardLayout b
    units = fromIntegral canvasSpan

-- | Lo que se pinta con el imán encendido o no.
scene :: Bool -> Board -> Scene
scene magnet b = case boardCarry b of
  Nothing -> Scene photo Nothing Nothing
  Just c  -> case find ((== carryId c) . widgetId) photo of
    Nothing -> Scene photo Nothing Nothing
    Just w  ->
      let (x, y, wd, ht) = floating w c
          after          = pushed magnet photo c
      in Scene (fromMaybe photo after)
               (Just (Held (carryId c) x y wd ht (isJust after)))
               (after >>= find ((== carryId c) . widgetId))
  where photo = boardLayout b

-- | El estilo del slot de la que se lleva: como 'Common.Layout.slotStyle', sin
-- pegar a la rejilla (dos decimales).
heldStyle :: Held -> Text
heldStyle h = T.intercalate "; "
  [ "left: "   <> fraction (heldX h)
  , "top: "    <> fraction (heldY h)
  , "width: "  <> fraction (heldW h)
  , "height: " <> fraction (heldH h)
  ]
  where
    fraction v =
      "calc(" <> T.pack (showFFloat (Just 2) v "") <> " * 100% / " <> T.pack (show canvasSpan) <> ")"

-- | El rectángulo de la que se lleva: el de la foto más lo que se ha movido el
-- puntero, en la esquina (por el título) o en el tamaño (por la ◢). Sin salirse del
-- lienzo y, al estirar, sin bajar de los mínimos.
floating :: WidgetConfig -> Carry -> (Double, Double, Double, Double)
floating w c = case carryGrip c of
  ByTitle  -> ( within 0 (span' - wd) (x + dx), within 0 (span' - ht) (y + dy), wd, ht )
  ByCorner -> ( x, y
              , within (fromIntegral (minWidthFor (widgetType w))) (span' - x) (wd + dx)
              , within (fromIntegral (minHeightFor (widgetType w))) (span' - y) (ht + dy) )
  where
    span'  = fromIntegral canvasSpan
    x      = fromIntegral (wcX w)
    y      = fromIntegral (wcY w)
    wd     = fromIntegral (wcW w)
    ht     = fromIntegral (wcH w)
    dx     = moved fst
    dy     = moved snd
    moved pick = (pick (carryAt c) - pick (carryFrom c)) / pick (carryUnit c)
    within lo hi = max lo . min hi

-- | El layout si se soltara ahora: la esquina o el tamaño, redondeados y pegados al
-- imán, y el empuje sobre la foto. 'Nothing' si no se deja.
pushed :: Bool -> [WidgetConfig] -> Carry -> Maybe [WidgetConfig]
pushed magnet photo c = do
  w <- find ((== carryId c) . widgetId) photo
  let (x, y, wd, ht) = floating w c
      d              = magnetDivisions magnet (carryAlt c)
      snapped        = snapTo d . round
  applyDrag d photo $ case carryGrip c of
    ByTitle  -> MoveTo (carryId c) (snapped x) (snapped y)
    ByCorner -> ResizeTo (carryId c) (snapped wd) (snapped ht)
