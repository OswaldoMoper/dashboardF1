-- | Cliente OpenF1 — tipos crudos compartidos (lógica pura).
--
-- Modela los campos de OpenF1 comunes a varias áreas de negocio. Hoy alberga
-- 'Of1Driver' (@/drivers@), consumido por 'Handler.Live' (identidad + equipo del
-- piloto) y por 'Handler.TyreStrategy' (cruce @driver_number → name_acronym@
-- para poblar 'Common.Types.TyreStint'). Los tipos crudos específicos de un área
-- siguen viviendo en el @Helper@ de esa área.
module Handler.OpenF1.Helper
  ( Of1Driver (..)
  ) where

import           Data.Aeson (FromJSON (..), withObject, (.:))
import           Data.Text  (Text)

-- | @/drivers@: identidad y equipo del piloto.
data Of1Driver = Of1Driver
  { odNumber  :: Int
  , odAcronym :: Text
  , odTeam    :: Text
  }
  deriving (Eq, Show)

instance FromJSON Of1Driver where
  parseJSON = withObject "Of1Driver" $ \o ->
    Of1Driver
      <$> o .: "driver_number"
      <*> o .: "name_acronym"
      <*> o .: "team_name"
