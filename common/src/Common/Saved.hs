-- | Lo que se guarda de un layout en el navegador, cómo se vuelve a leer y el aviso
-- cuando lo guardado no encaja. Se guarda el rectángulo de cada tarjeta, por su id, y
-- de cada Lap Comparison el lado de su tabla de mando, la banda y el modo
-- ('Common.ComparisonCard.CardControl').
--
-- Lo guardado solo pone el rectángulo y eso; el tipo, los parámetros, la
-- visibilidad y el grupo de cada tarjeta salen siempre del layout de fábrica.
module Common.Saved
  ( Restored (..)
  , SavedCard (..)
  , atFactory
  , factoryControls
  , restoreLayout
  , sameShown
  , saveLayout
  , savedKey
  , unfitNote
  ) where

import           Common.Comparison     (LapChoice)
import           Common.ComparisonCard (CardControl (..), ChartMode, Side,
                                        defaultControl)
import           Common.Layout         (fitsAt, overlaps)
import           Common.Types          (LayoutId (..), WidgetConfig (..),
                                        WidgetId, WidgetType (..))
import           Control.Monad         (guard)
import           Data.Aeson            (FromJSON, Options (..), ToJSON (..),
                                        decodeStrictText, defaultOptions,
                                        genericToEncoding, genericToJSON)
import           Data.Aeson.Text       (encodeToLazyText)
import           Data.List             (find, tails)
import           Data.Map.Strict       (Map)
import qualified Data.Map.Strict       as Map
import           Data.Maybe            (fromMaybe)
import           Data.Text             (Text)
import qualified Data.Text             as T
import qualified Data.Text.Lazy        as LT
import           GHC.Generics          (Generic)

-- | El rectángulo de una tarjeta, como se guarda, y si es una Lap Comparison, el
-- lado de su tabla de mando, la banda y el modo. Lo que no tiene no se escribe;
-- ausente, se lee como 'Nothing'.
data SavedCard = SavedCard
  { savedId   :: WidgetId
  , savedX    :: Int
  , savedY    :: Int
  , savedW    :: Int
  , savedH    :: Int
  , savedSide :: Maybe Side
  , savedBand :: Maybe Bool
  , savedMode :: Maybe ChartMode
  , savedLap  :: Maybe LapChoice
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
  | FromSaved [WidgetConfig] (Map WidgetId CardControl)
    -- ^ Lo guardado encaja: las tarjetas de fábrica, en su orden, cada una con su
    -- rectángulo guardado, y lo de cada Lap Comparison.
  | Unfit
    -- ^ Había algo guardado y no encaja: va el de fábrica, y se avisa.
  deriving stock (Eq, Show)

-- | La clave del navegador para un layout.
savedKey :: LayoutId -> Text
savedKey (LayoutId l) = "dashboardF1.layout." <> l

-- | Lo de fábrica de cada Lap Comparison de un layout ('defaultControl'); las demás
-- tarjetas no tienen.
factoryControls :: [WidgetConfig] -> Map WidgetId CardControl
factoryControls ws =
  Map.fromList [(widgetId w, defaultControl) | w <- ws, widgetType w == LapComparison]

-- | Si lo que se ve ya es el de fábrica @factory@ ('sameShown').
atFactory :: [WidgetConfig] -> Map WidgetId CardControl -> [WidgetConfig] -> Bool
atFactory factory controls shown = sameShown (factoryControls factory, factory) (controls, shown)

-- | Si dos estados de un layout se ven igual: cada tarjeta en el mismo rectángulo,
-- sin importar el orden, y cada Lap Comparison con el mismo lado, banda, modo y
-- vuelta. El imán no cuenta.
sameShown :: (Map WidgetId CardControl, [WidgetConfig]) -> (Map WidgetId CardControl, [WidgetConfig])
          -> Bool
sameShown (controlsA, a) (controlsB, b) = controlsA == controlsB && rects a == rects b
  where
    rects ws = Map.fromList [(widgetId w, (wcX w, wcY w, wcW w, wcH w)) | w <- ws]

-- | Lo que se escribe para un layout: el rectángulo de cada tarjeta y, si la tiene en
-- el mapa, lo de su Lap Comparison, siempre entero.
saveLayout :: Map WidgetId CardControl -> [WidgetConfig] -> Text
saveLayout controls = LT.toStrict . encodeToLazyText . map card
  where
    card w = SavedCard (widgetId w) (wcX w) (wcY w) (wcW w) (wcH w)
               (ccSide <$> c) (ccBand <$> c) (ccMode <$> c) (ccLap <$> c)
      where
        c = Map.lookup (widgetId w) controls

-- | El layout de fábrica con lo guardado encima. Lo guardado encaja si se lee, trae
-- las mismas tarjetas que el de fábrica (cada id una vez) y ninguna queda bajo su
-- mínimo, se sale del lienzo ('fitsAt') o se encima con otra ('overlaps').
--
-- Cada Lap Comparison lleva lo guardado; lo que no trae (guardado antes de que
-- existiera), el de fábrica. Un lado, una banda, un modo o una vuelta ilegibles hacen
-- que lo guardado no se lea, y lo que no encaja no conserva nada.
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
  pure (placed, Map.intersection (controlsOf cards) controls <> controls)
  where
    place w c     = w { wcX = savedX c, wcY = savedY c, wcW = savedW c, wcH = savedH c }
    controls      = factoryControls factory
    controlsOf cs = Map.fromList [(savedId c, control c) | c <- cs]
    control c     = CardControl
      { ccSide = fromMaybe (ccSide defaultControl) (savedSide c)
      , ccBand = fromMaybe (ccBand defaultControl) (savedBand c)
      , ccMode = fromMaybe (ccMode defaultControl) (savedMode c)
      , ccLap  = fromMaybe (ccLap defaultControl) (savedLap c)
      }

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
