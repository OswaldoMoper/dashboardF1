-- | Lo que se guarda de un layout en el navegador, cómo se vuelve a leer y el aviso
-- cuando lo guardado no encaja. Se guarda el rectángulo de cada tarjeta, por su id.
--
-- Lo guardado solo pone el rectángulo; el tipo, los parámetros, la visibilidad y el
-- grupo de cada tarjeta salen siempre del layout de fábrica.
module Common.Saved
  ( Restored (..)
  , SavedCard (..)
  , restoreLayout
  , saveLayout
  , savedKey
  , unfitNote
  ) where

import           Common.Layout   (fitsAt, overlaps)
import           Common.Types    (LayoutId (..), WidgetConfig (..), WidgetId)
import           Control.Monad   (guard)
import           Data.Aeson      (FromJSON, ToJSON, decodeStrictText)
import           Data.Aeson.Text (encodeToLazyText)
import           Data.List       (find, tails)
import           Data.Text       (Text)
import qualified Data.Text       as T
import qualified Data.Text.Lazy  as LT
import           GHC.Generics    (Generic)

-- | El rectángulo de una tarjeta, como se guarda.
data SavedCard = SavedCard
  { savedId :: WidgetId
  , savedX  :: Int
  , savedY  :: Int
  , savedW  :: Int
  , savedH  :: Int
  } deriving stock (Eq, Show, Generic)

instance ToJSON SavedCard
instance FromJSON SavedCard

-- | De dónde sale un layout al abrir la página.
data Restored
  = FromFactory
    -- ^ No había nada guardado.
  | FromSaved [WidgetConfig]
    -- ^ Lo guardado encaja: las tarjetas de fábrica, en su orden, cada una con su
    -- rectángulo guardado.
  | Unfit
    -- ^ Había algo guardado y no encaja: va el de fábrica, y se avisa.
  deriving stock (Eq, Show)

-- | La clave del navegador para un layout.
savedKey :: LayoutId -> Text
savedKey (LayoutId l) = "dashboardF1.layout." <> l

-- | Lo que se escribe para un layout.
saveLayout :: [WidgetConfig] -> Text
saveLayout = LT.toStrict . encodeToLazyText . map card
  where
    card w = SavedCard (widgetId w) (wcX w) (wcY w) (wcW w) (wcH w)

-- | El layout de fábrica con lo guardado encima. Lo guardado encaja si se lee, trae
-- las mismas tarjetas que el de fábrica (cada id una vez) y ninguna queda bajo su
-- mínimo, se sale del lienzo ('fitsAt') o se encima con otra ('overlaps').
--
-- Supone que los ids del de fábrica no se repiten.
restoreLayout :: [WidgetConfig] -> Maybe Text -> Restored
restoreLayout _ Nothing = FromFactory
restoreLayout factory (Just t) = maybe Unfit FromSaved $ do
  cards <- decodeStrictText t :: Maybe [SavedCard]
  guard (length cards == length factory)
  placed <- traverse (\w -> place w <$> find ((== widgetId w) . savedId) cards) factory
  guard (all fitsAt placed)
  guard (not (or [overlaps a b | a : rest <- tails placed, b <- rest]))
  pure placed
  where
    place w c = w { wcX = savedX c, wcY = savedY c, wcW = savedW c, wcH = savedH c }

-- | La nota de los layouts que volvieron al de fábrica, con sus nombres. Con uno solo
-- no lo nombra, porque la nota va bajo su botón; sin ninguno, vacía.
unfitNote :: [Text] -> Text
unfitNote names = case reverse names of
  []          -> ""
  [_]         -> "Volvió al de fábrica" <> because <> " (Pulsa para cerrar; el asterisco se queda" <> until'
  lastOne : r -> T.intercalate ", " (reverse r) <> " y " <> lastOne <> " volvieron al de fábrica" <> because
                   <> " (Pulsa para cerrar; los asteriscos se quedan" <> until'
  where
    because = ": lo guardado ya no encaja con el diseño de hoy."
    until'  = " hasta pulsar «✎ Editar layout».)"
