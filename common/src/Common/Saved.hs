-- | Lo que se guarda de un layout en el navegador, cómo se vuelve a leer y el aviso
-- cuando lo guardado no encaja. Se guarda el rectángulo de cada tarjeta, por su id, y
-- el lado de la tabla de mando de cada Lap Comparison.
--
-- Lo guardado solo pone el rectángulo y el lado; el tipo, los parámetros, la
-- visibilidad y el grupo de cada tarjeta salen siempre del layout de fábrica.
module Common.Saved
  ( Restored (..)
  , SavedCard (..)
  , atFactory
  , factorySides
  , restoreLayout
  , saveLayout
  , savedKey
  , unfitNote
  ) where

import           Common.ComparisonCard (Side, defaultControlSide)
import           Common.Layout   (fitsAt, overlaps)
import           Common.Types    (LayoutId (..), WidgetConfig (..), WidgetId,
                                  WidgetType (..))
import           Control.Monad   (guard)
import           Data.Aeson      (FromJSON, Options (..), ToJSON (..),
                                  decodeStrictText, defaultOptions,
                                  genericToEncoding, genericToJSON)
import           Data.Aeson.Text (encodeToLazyText)
import           Data.List       (find, tails)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Text       (Text)
import qualified Data.Text       as T
import qualified Data.Text.Lazy  as LT
import           GHC.Generics    (Generic)

-- | El rectángulo de una tarjeta, como se guarda, y el lado de su tabla de mando si
-- lo tiene. Sin lado, la clave no se escribe; ausente, se lee como 'Nothing'.
data SavedCard = SavedCard
  { savedId   :: WidgetId
  , savedX    :: Int
  , savedY    :: Int
  , savedW    :: Int
  , savedH    :: Int
  , savedSide :: Maybe Side
  } deriving stock (Eq, Show, Generic)

instance ToJSON SavedCard where
  toJSON     = genericToJSON savedOptions
  toEncoding = genericToEncoding savedOptions

instance FromJSON SavedCard

savedOptions :: Options
savedOptions = defaultOptions { omitNothingFields = True }

-- | De dónde sale un layout al abrir la página.
data Restored
  = FromFactory
    -- ^ No había nada guardado.
  | FromSaved [WidgetConfig] (Map WidgetId Side)
    -- ^ Lo guardado encaja: las tarjetas de fábrica, en su orden, cada una con su
    -- rectángulo guardado, y el lado de cada Lap Comparison.
  | Unfit
    -- ^ Había algo guardado y no encaja: va el de fábrica, y se avisa.
  deriving stock (Eq, Show)

-- | La clave del navegador para un layout.
savedKey :: LayoutId -> Text
savedKey (LayoutId l) = "dashboardF1.layout." <> l

-- | El lado de fábrica de cada Lap Comparison de un layout; las demás tarjetas no
-- tienen lado.
factorySides :: [WidgetConfig] -> Map WidgetId Side
factorySides ws =
  Map.fromList [(widgetId w, defaultControlSide) | w <- ws, widgetType w == LapComparison]

-- | Si lo que se ve ya es el de fábrica @factory@: cada tarjeta en su rectángulo de
-- fábrica, sin importar el orden, y cada Lap Comparison con su lado de fábrica. El
-- imán no cuenta.
atFactory :: [WidgetConfig] -> Map WidgetId Side -> [WidgetConfig] -> Bool
atFactory factory sides shown = rects shown == rects factory && sides == factorySides factory
  where
    rects ws = Map.fromList [(widgetId w, (wcX w, wcY w, wcW w, wcH w)) | w <- ws]

-- | Lo que se escribe para un layout: el rectángulo de cada tarjeta y el lado que
-- tenga en el mapa.
saveLayout :: Map WidgetId Side -> [WidgetConfig] -> Text
saveLayout sides = LT.toStrict . encodeToLazyText . map card
  where
    card w = SavedCard (widgetId w) (wcX w) (wcY w) (wcW w) (wcH w) (Map.lookup (widgetId w) sides)

-- | El layout de fábrica con lo guardado encima. Lo guardado encaja si se lee, trae
-- las mismas tarjetas que el de fábrica (cada id una vez) y ninguna queda bajo su
-- mínimo, se sale del lienzo ('fitsAt') o se encima con otra ('overlaps').
--
-- Cada Lap Comparison lleva el lado guardado, o el de fábrica si no lo trae. Un lado
-- ilegible hace que lo guardado no se lea, y lo que no encaja no conserva su lado.
--
-- Supone que los ids del de fábrica no se repiten.
restoreLayout :: [WidgetConfig] -> Maybe Text -> Restored
restoreLayout _ Nothing = FromFactory
restoreLayout factory (Just t) = maybe Unfit (uncurry FromSaved) $ do
  cards <- decodeStrictText t :: Maybe [SavedCard]
  guard (length cards == length factory)
  placed <- traverse (\w -> place w <$> find ((== widgetId w) . savedId) cards) factory
  guard (all fitsAt placed)
  guard (not (or [overlaps a b | a : rest <- tails placed, b <- rest]))
  pure (placed, Map.intersection (sidesOf cards) sides <> sides)
  where
    place w c  = w { wcX = savedX c, wcY = savedY c, wcW = savedW c, wcH = savedH c }
    sides      = factorySides factory
    sidesOf cs = Map.fromList [(savedId c, s) | c <- cs, Just s <- [savedSide c]]

-- | La nota de los layouts que volvieron al de fábrica, con sus nombres. Con uno solo
-- no lo nombra, porque la nota va bajo su botón; sin ninguno, vacía.
unfitNote :: [Text] -> Text
unfitNote names = case reverse names of
  []          -> ""
  [_]         -> "Volvió a la configuración predeterminada" <> because
                   <> " (Pulsa para cerrar; el asterisco se queda" <> until'
  lastOne : r -> T.intercalate ", " (reverse r) <> " y " <> lastOne
                   <> " volvieron a la configuración predeterminada" <> because
                   <> " (Pulsa para cerrar; los asteriscos se quedan" <> until'
  where
    because = ": lo guardado ya no encaja con el diseño de hoy."
    until'  = " hasta pulsar «✎ Editar layout».)"
