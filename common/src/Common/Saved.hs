-- | Lo que se guarda de un layout en el navegador, cómo se vuelve a leer y el aviso
-- cuando lo guardado no encaja. Se guarda el rectángulo de cada tarjeta, por su id, y
-- de cada Lap Comparison el lado de su tabla de mando, la banda, el modo, la vuelta y
-- las gráficas ('Common.ComparisonCard.CardControl'); y los grupos del layout y en
-- cuáles está cada tarjeta.
--
-- Lo guardado solo pone eso; el tipo, los parámetros y la visibilidad de cada tarjeta
-- salen siempre del layout de fábrica.
module Common.Saved
  ( Restored (..)
  , SavedCard (..)
  , SavedLayout (..)
  , Shown (..)
  , atFactory
  , factoryControls
  , factoryShown
  , resetQuestion
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
import           Common.Traces         (Channel)
import           Common.Types          (CardGroup, GroupId, Layout (..),
                                        LayoutId (..), WidgetConfig (..),
                                        WidgetId, WidgetType (..))
import           Control.Applicative   ((<|>))
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
-- lado de su tabla de mando, la banda, el modo, la vuelta y las gráficas; y los grupos en
-- los que está. Lo que
-- no tiene no se escribe; ausente, se lee como 'Nothing'.
data SavedCard = SavedCard
  { savedId     :: WidgetId
  , savedX      :: Int
  , savedY      :: Int
  , savedW      :: Int
  , savedH      :: Int
  , savedSide   :: Maybe Side
  , savedBand   :: Maybe Bool
  , savedMode   :: Maybe ChartMode
  , savedLap    :: Maybe LapChoice
  , savedGroups :: Maybe [GroupId]
  , savedCharts :: Maybe [Channel]
  } deriving stock (Eq, Show, Generic)

instance ToJSON SavedCard where
  toJSON     = genericToJSON savedOptions
  toEncoding = genericToEncoding savedOptions

instance FromJSON SavedCard

savedOptions :: Options
savedOptions = defaultOptions { omitNothingFields = True }

-- | Lo que se guarda de un layout con grupos. Uno sin grupos se guarda como la lista
-- de sus tarjetas sola.
data SavedLayout = SavedLayout
  { savedCards        :: [SavedCard]
  , savedLayoutGroups :: [CardGroup]
  } deriving stock (Eq, Show, Generic)

instance ToJSON SavedLayout
instance FromJSON SavedLayout

-- | Lo que se ve de un layout y se guarda: lo de cada Lap Comparison, sus grupos y sus
-- tarjetas.
data Shown = Shown
  { shownControls :: Map WidgetId CardControl
  , shownGroups   :: [CardGroup]
  , shownCards    :: [WidgetConfig]
  } deriving stock (Eq, Show)

-- | De dónde sale un layout al abrir la página.
data Restored
  = FromFactory
    -- ^ No había nada guardado.
  | FromSaved Shown
    -- ^ Lo guardado encaja: las tarjetas de fábrica, en su orden, cada una con su
    -- rectángulo y sus grupos guardados, lo de cada Lap Comparison y los grupos.
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

-- | Lo que se ve de un layout de fábrica.
factoryShown :: Layout -> Shown
factoryShown l = Shown (factoryControls (widgets l)) (layoutGroups l) (widgets l)

-- | Si lo que se ve ya es el de fábrica del layout ('sameShown').
atFactory :: Layout -> Shown -> Bool
atFactory = sameShown . factoryShown

-- | Si dos estados de un layout se ven igual: cada tarjeta en el mismo rectángulo y en
-- los mismos grupos, sin importar el orden de las tarjetas; cada Lap Comparison con el
-- mismo lado, banda, modo, vuelta y gráficas, y los mismos grupos. El imán no cuenta.
sameShown :: Shown -> Shown -> Bool
sameShown a b =
  shownControls a == shownControls b && shownGroups a == shownGroups b && cards a == cards b
  where
    cards s = Map.fromList
      [(widgetId w, (wcX w, wcY w, wcW w, wcH w, widgetGroups w)) | w <- shownCards s]

-- | Lo que se escribe para un layout: el rectángulo de cada tarjeta y, si la tiene en
-- el mapa, lo de su Lap Comparison, siempre entero. Si ni el layout ni sus tarjetas
-- tienen grupos, la lista de tarjetas sola; si no, las tarjetas, con sus grupos, y los
-- grupos ('SavedLayout').
saveLayout :: Shown -> Text
saveLayout (Shown controls groups ws)
  | null groups && all (null . widgetGroups) ws = encode cards
  | otherwise                                    = encode (SavedLayout cards groups)
  where
    encode :: ToJSON a => a -> Text
    encode = LT.toStrict . encodeToLazyText
    cards = map card ws
    card w = SavedCard (widgetId w) (wcX w) (wcY w) (wcW w) (wcH w)
               (ccSide <$> c) (ccBand <$> c) (ccMode <$> c) (ccLap <$> c)
               (if null (widgetGroups w) then Nothing else Just (widgetGroups w))
               (ccCharts <$> c)
      where
        c = Map.lookup (widgetId w) controls

-- | El layout de fábrica con lo guardado encima. Lo guardado encaja si se lee, trae
-- las mismas tarjetas que el de fábrica (cada id una vez) y ninguna queda bajo su
-- mínimo, se sale del lienzo ('fitsAt') o se encima con otra ('overlaps').
--
-- Cada Lap Comparison lleva lo guardado; lo que no trae (guardado antes de que
-- existiera), el de fábrica, y unas gráficas guardadas sin ninguna, también. Un lado,
-- una banda, un modo, una vuelta o una gráfica ilegibles hacen que lo guardado no se
-- lea, y lo que no encaja no conserva nada. Los grupos y los de
-- cada tarjeta son los guardados; lo guardado sin grupos no tiene ninguno.
--
-- Supone que los ids del de fábrica no se repiten.
restoreLayout :: [WidgetConfig] -> Maybe Text -> Restored
restoreLayout _ Nothing = FromFactory
restoreLayout factory (Just t) = maybe Unfit FromSaved $ do
  (cards, groups) <- readCards
  guard (length cards == length factory)
  placed <- traverse (\w -> place w <$> find ((== widgetId w) . savedId) cards) factory
  guard (all fitsAt placed)
  guard (not (or [overlaps a b | a : rest <- tails placed, b <- rest]))
  pure (Shown (Map.intersection (controlsOf cards) controls <> controls) groups placed)
  where
    readCards     = (\cs -> (cs, [])) <$> decodeStrictText t
                      <|> (\s -> (savedCards s, savedLayoutGroups s)) <$> decodeStrictText t
    place w c     = w { wcX = savedX c, wcY = savedY c, wcW = savedW c, wcH = savedH c
                      , widgetGroups = fromMaybe [] (savedGroups c) }
    controls      = factoryControls factory
    controlsOf cs = Map.fromList [(savedId c, control c) | c <- cs]
    control c     = CardControl
      { ccSide = fromMaybe (ccSide defaultControl) (savedSide c)
      , ccBand = fromMaybe (ccBand defaultControl) (savedBand c)
      , ccMode = fromMaybe (ccMode defaultControl) (savedMode c)
      , ccLap  = fromMaybe (ccLap defaultControl) (savedLap c)
      , ccCharts = case savedCharts c of
          Just cs@(_ : _) -> cs
          _               -> ccCharts defaultControl
      }

-- | La pregunta de «Restablecer»; si el layout tiene grupos, dice cuántos se quitan.
resetQuestion :: Int -> Text
resetQuestion n = "¿Volver a la configuración predeterminada?" <> case n of
  _ | n <= 0 -> ""
  1          -> " Se quita 1 grupo."
  _          -> " Se quitan " <> T.pack (show n) <> " grupos."

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
