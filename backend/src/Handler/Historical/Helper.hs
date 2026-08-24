-- | Área estadísticas históricas — lógica pura.
--
-- Modela solo la envoltura de Jolpica (Ergast) que se consume —
-- @\/current\/driverStandings@ y @\/current\/constructorStandings@ — y la traduce a
-- 'HistoricalStat'. Cada entrada produce __una fila__ con sus dos métricas en
-- columnas (puntos y victorias); los campos
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
-- omite, 'parseNum' falla y 'assembleStats' deja 'hsWins' en 'Nothing' con el
-- piloto y sus puntos intactos. Con @.:@ el decode entero fallaba y, como
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

-- | Traduce la clasificación de pilotos a 'HistoricalStat': __una fila por
-- piloto__, en el orden de la clasificación, con la identidad estructurada
-- (código, nombre, apellido) y la marca 'DriverStat', de modo que el consumidor
-- elige qué etiqueta mostrar.
--
-- Los dos campos numéricos __no se descartan igual__, y es la asimetría que
-- 2026-08-24 introdujo al pasar de una fila por métrica a una por entidad:
-- @points@ que no parsea descarta __al piloto__ ('mapMaybe'), porque una fila sin
-- la métrica obligatoria no tiene valor; @wins@ que no parsea o falta deja
-- 'hsWins' en 'Nothing' y el piloto se conserva. Antes las dos métricas caían por
-- el mismo 'mapMaybe' y descartarse a sí misma era gratis; hoy la única forma de
-- que salga barato es que el tipo admita la ausencia.
assembleStats :: Root -> [HistoricalStat]
assembleStats root =
  mapMaybe driverStat standings
  where
    standings =
      concatMap slStandings (stLists (mrTable (rootMRData root)))
    driverStat ds =
      let drv = dsDriver ds
       in (\pts -> HistoricalStat
                     DriverStat
                     (jdCode drv)
                     (jdGivenName drv)
                     (jdFamilyName drv)
                     pts
                     (parseNum (dsWins ds)))
            <$> parseNum (dsPoints ds)

-- | Espejo de 'assembleStats' para la clasificación de constructores: una fila por
-- equipo, mismas dos métricas (@points@\/@wins@), mismo reparto de descartes entre
-- ellas y marca 'ConstructorStat'. El identificador de Jolpica ocupa @hsCode@ y el
-- nombre legible @hsFamilyName@; @hsGivenName@ queda vacío (un equipo no tiene
-- nombre de pila).
assembleConstructorStats :: Root -> [HistoricalStat]
assembleConstructorStats root =
  mapMaybe constructorStat standings
  where
    standings =
      concatMap slConstructorStandings (stLists (mrTable (rootMRData root)))
    constructorStat cs =
      let con = csConstructor cs
       in (\pts -> HistoricalStat
                     ConstructorStat
                     (cnId con)
                     ""
                     (cnName con)
                     pts
                     (parseNum (csWins cs)))
            <$> parseNum (csPoints cs)

-- | Parsea un campo numérico de Ergast (cadena) a 'Double'.
parseNum :: Text -> Maybe Double
parseNum = readMaybe . T.unpack
