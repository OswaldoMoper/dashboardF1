-- | Área estrategia de neumáticos — lógica pura.
--
-- Modela solo los campos de OpenF1 @/stints@ que se consumen y los traduce a
-- 'TyreStint'. El cruce @driver_number → name_acronym@ (para 'tsDriver') usa
-- 'Of1Driver' del cliente compartido 'Handler.OpenF1.Helper'. Sin efectos:
-- determinista y testeable.
module Handler.TyreStrategy.Helper
  ( -- * Tipo crudo OpenF1 de stints
    Of1Stint (..)
    -- * Transformación pura
  , assembleStints
  ) where

import           Common.Types          (TyreStint (..))
import           Data.Aeson            (FromJSON (..), withObject, (.:))
import           Data.List             (find, sortOn)
import           Data.Maybe            (mapMaybe)
import           Data.Text             (Text)
import           Handler.OpenF1.Helper (Of1Driver (..))

-- | @/stints@: periodo con un mismo compuesto para un piloto.
data Of1Stint = Of1Stint
  { osNumber   :: Int   -- ^ @driver_number@.
  , osCompound :: Text  -- ^ SOFT/MEDIUM/HARD/INTER/WET.
  , osLapStart :: Int
  , osLapEnd   :: Int
  }
  deriving (Eq, Show)

instance FromJSON Of1Stint where
  parseJSON = withObject "Of1Stint" $ \o ->
    Of1Stint
      <$> o .: "driver_number"
      <*> o .: "compound"
      <*> o .: "lap_start"
      <*> o .: "lap_end"

-- | Ensambla los stints uniendo por @driver_number@ para resolver el acrónimo
-- del piloto. Un stint cuyo piloto no aparezca en @/drivers@ se omite. El
-- resultado se ordena por acrónimo y luego por vuelta de inicio.
assembleStints :: [Of1Driver] -> [Of1Stint] -> [TyreStint]
assembleStints drivers stints =
  sortOn (\t -> (tsDriver t, tsStartLap t)) (mapMaybe toStint stints)
  where
    toStint s = do
      d <- find ((== osNumber s) . odNumber) drivers
      pure
        TyreStint
          { tsDriver   = odAcronym d
          , tsCompound = osCompound s
          , tsStartLap = osLapStart s
          , tsEndLap   = osLapEnd s
          }
