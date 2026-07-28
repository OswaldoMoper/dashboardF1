-- | Área estadísticas históricas — lógica pura.
--
-- Modela solo la envoltura de Jolpica (Ergast) @\/current\/driverStandings@ que se
-- consume y la traduce a 'HistoricalStat'. Cada piloto produce dos KPIs (puntos y
-- victorias); los campos numéricos de Ergast vienen como cadena, así que se parsean
-- a 'Double' aquí. La identidad del piloto se propaga __estructurada__ (código,
-- nombre, apellido) tal como llega de Jolpica; es el consumidor quien elige la
-- etiqueta (2026-07-28). Sin efectos: determinista y testeable.
module Handler.Historical.Helper
  ( -- * Envoltura cruda de Jolpica
    Root (..)
  , MRData (..)
  , StandingsTable (..)
  , StandingsList (..)
  , DriverStanding (..)
  , JolpicaDriver (..)
    -- * Transformación pura
  , assembleStats
  , parseNum
  ) where

import           Common.Types (HistoricalStat (..))
import           Data.Aeson   (FromJSON (..), withObject, (.:))
import           Data.Maybe   (mapMaybe)
import           Data.Text    (Text)
import qualified Data.Text    as T
import           Text.Read    (readMaybe)

-- | Raíz de la respuesta: @{ "MRData": … }@.
newtype Root = Root { rootMRData :: MRData }
  deriving (Eq, Show)

instance FromJSON Root where
  parseJSON = withObject "Root" $ \o -> Root <$> o .: "MRData"

-- | @MRData.StandingsTable@.
newtype MRData = MRData { mrTable :: StandingsTable }
  deriving (Eq, Show)

instance FromJSON MRData where
  parseJSON = withObject "MRData" $ \o -> MRData <$> o .: "StandingsTable"

-- | @StandingsTable.StandingsLists@ (una por temporada consultada).
newtype StandingsTable = StandingsTable { stLists :: [StandingsList] }
  deriving (Eq, Show)

instance FromJSON StandingsTable where
  parseJSON = withObject "StandingsTable" $ \o ->
    StandingsTable <$> o .: "StandingsLists"

-- | @StandingsList.DriverStandings@.
newtype StandingsList = StandingsList { slStandings :: [DriverStanding] }
  deriving (Eq, Show)

instance FromJSON StandingsList where
  parseJSON = withObject "StandingsList" $ \o ->
    StandingsList <$> o .: "DriverStandings"

-- | Fila de clasificación: puntos y victorias (cadenas Ergast) + piloto.
data DriverStanding = DriverStanding
  { dsPoints :: Text
  , dsWins   :: Text
  , dsDriver :: JolpicaDriver
  }
  deriving (Eq, Show)

instance FromJSON DriverStanding where
  parseJSON = withObject "DriverStanding" $ \o ->
    DriverStanding
      <$> o .: "points"
      <*> o .: "wins"
      <*> o .: "Driver"

-- | @Driver@: identidad del piloto tal como la publica Jolpica — código
-- (acrónimo, p. ej. @"VER"@), nombre y apellido. Los tres se consumen para poblar
-- la identidad estructurada de 'HistoricalStat'.
data JolpicaDriver = JolpicaDriver
  { jdCode       :: Text
  , jdGivenName  :: Text
  , jdFamilyName :: Text
  }
  deriving (Eq, Show)

instance FromJSON JolpicaDriver where
  parseJSON = withObject "Driver" $ \o ->
    JolpicaDriver
      <$> o .: "code"
      <*> o .: "givenName"
      <*> o .: "familyName"

-- | Aplana la clasificación a KPIs: por cada piloto, en el orden de la
-- clasificación, emite @<piloto> puntos "points"@ y @<piloto> victorias "wins"@.
-- Cada fila lleva la identidad estructurada del piloto (código, nombre, apellido),
-- de modo que el consumidor elige qué etiqueta mostrar. Descarta la métrica cuyo
-- valor no parsee a 'Double' ('mapMaybe').
assembleStats :: Root -> [HistoricalStat]
assembleStats root =
  concatMap driverStats standings
  where
    standings =
      concatMap slStandings (stLists (mrTable (rootMRData root)))
    driverStats ds =
      mapMaybe
        (\(unit, raw) -> mkStat (dsDriver ds) unit raw)
        [ ("points", dsPoints ds)
        , ("wins", dsWins ds)
        ]
    mkStat drv unit raw =
      (\v -> HistoricalStat
               (jdCode drv)
               (jdGivenName drv)
               (jdFamilyName drv)
               v
               unit)
        <$> parseNum raw

-- | Parsea un campo numérico de Ergast (cadena) a 'Double'.
parseNum :: Text -> Maybe Double
parseNum = readMaybe . T.unpack
