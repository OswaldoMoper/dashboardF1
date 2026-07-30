-- | Área estadísticas históricas — lógica pura.
--
-- Modela solo la envoltura de Jolpica (Ergast) que se consume —
-- @\/current\/driverStandings@ y @\/current\/constructorStandings@ — y la traduce a
-- 'HistoricalStat'. Cada entrada produce dos KPIs (puntos y victorias); los campos
-- numéricos de Ergast vienen como cadena, así que se parsean a 'Double' aquí. La
-- identidad se propaga __estructurada__ (código, nombre, apellido) tal como llega de
-- Jolpica; es el consumidor quien elige la etiqueta
-- (2026-07-28) y cada fila lleva su 'StatEntity' para saber qué proyección aplicar
-- (2026-07-29). Sin efectos: determinista y testeable.
--
-- El decode distingue campos __obligatorios__ (@points@, @Driver@, @Constructor@ y
-- sus nombres: sin ellos la fila no tiene valor) de campos __prescindibles__
-- (@code@, @wins@), que son @.:?@ para que su ausencia degrade lo mínimo en vez de
-- tumbar la respuesta entera (2026-07-30).
module Handler.Historical.Helper
  ( -- * Envoltura cruda de Jolpica
    Root (..)
  , MRData (..)
  , StandingsTable (..)
  , StandingsList (..)
  , DriverStanding (..)
  , JolpicaDriver (..)
  , ConstructorStanding (..)
  , Constructor (..)
    -- * Transformación pura
  , assembleStats
  , assembleConstructorStats
  , parseNum
  ) where

import           Common.Types (HistoricalStat (..), StatEntity (..))
import           Data.Aeson   (FromJSON (..), withObject, (.!=), (.:), (.:?))
import           Data.Maybe   (fromMaybe, mapMaybe)
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

-- | @StandingsList.{DriverStandings,ConstructorStandings}@.
--
-- El mismo 'Root' decodifica las dos respuestas de Jolpica y cada una trae __solo
-- una__ de las dos claves, así que ambas son opcionales con defecto @[]@: con @.:@
-- el decode del otro endpoint fallaría.
data StandingsList = StandingsList
  { slStandings            :: [DriverStanding]
  , slConstructorStandings :: [ConstructorStanding]
  }
  deriving (Eq, Show)

instance FromJSON StandingsList where
  parseJSON = withObject "StandingsList" $ \o ->
    StandingsList
      <$> o .:? "DriverStandings" .!= []
      <*> o .:? "ConstructorStandings" .!= []

-- | Fila de clasificación: puntos y victorias (cadenas Ergast) + piloto.
--
-- @wins@ es __opcional con defecto no numérico__ (@\"\"@) a propósito: si Jolpica lo
-- omite, 'parseNum' falla y el 'mapMaybe' de 'assembleStats' descarta __solo__ ese
-- KPI, dejando la fila de puntos intacta. Con @.:@ el decode entero fallaba y, como
-- 'Handler.Historical.Context.fetchStats' hace los dos GET dentro de un solo @try@,
-- un campo ausente en cualquiera de las dos respuestas arrastraba el refresco
-- completo a cache\/dummy. El defecto es @\"\"@ y no @\"0\"@ porque declarar cero
-- victorias sería __inventar un dato__ que Jolpica no publicó.
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
      <*> o .:? "wins" .!= ""
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

-- | @code@ es __opcional con fallback al apellido__: Jolpica no publica acrónimo
-- para todo piloto (históricos y suplentes suelen carecer de él) y con @.:@ un solo
-- piloto sin @code@ tumbaba la lista completa hacia cache\/dummy — los dos GET del
-- 'Handler.Historical.Context' viven en un mismo @try@, así que el fallo no se
-- quedaba en su propia entidad. El apellido es el sustituto natural: es la etiqueta
-- que el widget ya muestra en los modos @Family@\/@Full@, así que la fila sigue
-- siendo identificable. __Cambio de semántica deliberado__
-- (2026-07-30): antes esa respuesta no se servía; ahora se sirve con
-- @hsCode == familyName@. @givenName@\/@familyName@ siguen obligatorios: sin
-- identidad legible la fila no tiene valor.
instance FromJSON JolpicaDriver where
  parseJSON = withObject "Driver" $ \o -> do
    familyName <- o .: "familyName"
    givenName  <- o .: "givenName"
    code       <- o .:? "code"
    pure (JolpicaDriver (fromMaybe familyName code) givenName familyName)

-- | Fila de clasificación de constructores: puntos y victorias (cadenas Ergast) +
-- constructor. Mismo criterio defensivo que 'DriverStanding' en @wins@ y por la misma
-- razón (los dos GET comparten un @try@).
data ConstructorStanding = ConstructorStanding
  { csPoints      :: Text
  , csWins        :: Text
  , csConstructor :: Constructor
  }
  deriving (Eq, Show)

instance FromJSON ConstructorStanding where
  parseJSON = withObject "ConstructorStanding" $ \o ->
    ConstructorStanding
      <$> o .: "points"
      <*> o .:? "wins" .!= ""
      <*> o .: "Constructor"

-- | @Constructor@: identidad del equipo tal como la publica Jolpica — identificador
-- (@"red_bull"@) y nombre legible (@"Red Bull"@). No hay acrónimo ni
-- nombre\/apellido, de ahí la marca de entidad en 'HistoricalStat'.
data Constructor = Constructor
  { cnId   :: Text
  , cnName :: Text
  }
  deriving (Eq, Show)

instance FromJSON Constructor where
  parseJSON = withObject "Constructor" $ \o ->
    Constructor
      <$> o .: "constructorId"
      <*> o .: "name"

-- | Aplana la clasificación de pilotos a KPIs: por cada piloto, en el orden de la
-- clasificación, emite @<piloto> puntos "points"@ y @<piloto> victorias "wins"@.
-- Cada fila lleva la identidad estructurada del piloto (código, nombre, apellido) y
-- la marca 'DriverStat', de modo que el consumidor elige qué etiqueta mostrar.
-- Descarta la métrica cuyo valor no parsee a 'Double' ('mapMaybe').
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
               DriverStat
               (jdCode drv)
               (jdGivenName drv)
               (jdFamilyName drv)
               v
               unit)
        <$> parseNum raw

-- | Espejo de 'assembleStats' para la clasificación de constructores: mismos dos
-- KPIs (@points@\/@wins@), mismo descarte de valores no parseables y marca
-- 'ConstructorStat'. El identificador de Jolpica ocupa @hsCode@ y el nombre legible
-- @hsFamilyName@; @hsGivenName@ queda vacío (un equipo no tiene nombre de pila).
assembleConstructorStats :: Root -> [HistoricalStat]
assembleConstructorStats root =
  concatMap constructorStats standings
  where
    standings =
      concatMap slConstructorStandings (stLists (mrTable (rootMRData root)))
    constructorStats cs =
      mapMaybe
        (\(unit, raw) -> mkStat (csConstructor cs) unit raw)
        [ ("points", csPoints cs)
        , ("wins", csWins cs)
        ]
    mkStat con unit raw =
      (\v -> HistoricalStat
               ConstructorStat
               (cnId con)
               ""
               (cnName con)
               v
               unit)
        <$> parseNum raw

-- | Parsea un campo numérico de Ergast (cadena) a 'Double'.
parseNum :: Text -> Maybe Double
parseNum = readMaybe . T.unpack
