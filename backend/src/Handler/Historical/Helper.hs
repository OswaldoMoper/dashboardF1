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
    -- * Qué ronda se pide
  , StandingsAt (..)
  , resolveStandings
    -- * Qué se sirve de lo guardado
  , historicalFreshFor
  , keptToday
  , keptStandings
  , servedToday
  ) where

import           Common.Session       (SessionCode (..), SessionKey (..))
import           Common.Types         (HistoricalStat (..), StatEntity (..))
import           Control.Applicative  ((<|>))
import           Data.Aeson           (FromJSON (..), Object, withObject, (.!=),
                                       (.:), (.:?))
import           Data.Aeson.Types     (Parser)
import           Data.Maybe           (fromMaybe, mapMaybe)
import           Data.Text            (Text)
import qualified Data.Text            as T
import           Data.Time.Clock      (NominalDiffTime, UTCTime, diffUTCTime)
import           Handler.Query.Helper (sessionKeyParam)
import           Outcome              (Rejection)
import           Text.Read            (readMaybe)

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
-- completo a lo guardado o al error. El defecto es @\"\"@ y no @\"0\"@ porque declarar cero
-- victorias sería __inventar un dato__ que Jolpica no publicó.
data DriverStanding = DriverStanding
  { dsPoints   :: Text
  , dsWins     :: Text
  , dsPosition :: Text
  , dsDriver   :: JolpicaDriver
  }
  deriving (Eq, Show)

instance FromJSON DriverStanding where
  parseJSON = withObject "DriverStanding" $ \o ->
    DriverStanding
      <$> o .: "points"
      <*> o .:? "wins" .!= ""
      <*> standingPosition o
      <*> o .: "Driver"

-- | El puesto de una fila tal como lo escribe Jolpica: @positionText@, que es el que
-- dice «D» o «-» cuando no hay número (un excluido), y si falta, @position@. Sin
-- ninguno de los dos, la cadena vacía, que 'parsePosition' no lee.
standingPosition :: Object -> Parser Text
standingPosition o = do
  written <- o .:? "positionText"
  number  <- o .:? "position"
  pure (fromMaybe "" (written <|> number))

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
-- piloto sin @code@ tumbaba la lista completa hacia lo guardado o el error — los dos GET del
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
  , csPosition    :: Text
  , csConstructor :: Constructor
  }
  deriving (Eq, Show)

instance FromJSON ConstructorStanding where
  parseJSON = withObject "ConstructorStanding" $ \o ->
    ConstructorStanding
      <$> o .: "points"
      <*> o .:? "wins" .!= ""
      <*> standingPosition o
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
                     (parseNum (dsWins ds))
                     (parsePosition (dsPosition ds)))
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
                     (parseNum (csWins cs))
                     (parsePosition (csPosition cs)))
            <$> parseNum (csPoints cs)

-- | Parsea un campo numérico de Ergast (cadena) a 'Double'.
parseNum :: Text -> Maybe Double
parseNum = readMaybe . T.unpack

-- | El puesto, si es un número; lo que no lo es («D», «-», la cadena vacía) queda
-- sin puesto en vez de inventarle uno.
parsePosition :: Text -> Maybe Int
parsePosition = readMaybe . T.unpack

-- | De qué momento es la clasificación que se pide.
data StandingsAt
  = StandingsToday          -- ^ Sin @?session=@: la temporada a hoy (@current@).
  | StandingsAfter Int Int  -- ^ Tras esa ronda de ese año; la 0 es antes de la primera.
  deriving (Eq, Ord, Show)

-- | El @?session=@ de @\/api\/historical@: la carrera, tras su ronda; cualquier otra
-- sesión, tras la anterior (2026-11-13 (k)). Vacío, @latest@ o lo que no es una clave,
-- 'BadRequest'.
resolveStandings :: Maybe Text -> Either Rejection StandingsAt
resolveStandings param = maybe StandingsToday after <$> sessionKeyParam param
  where
    after (SessionKey year rnd Race) = StandingsAfter year rnd
    after (SessionKey year rnd _)    = StandingsAfter year (rnd - 1)

-- | Cuánto se sirve lo guardado sin volver a Jolpica: los diez minutos de su
-- @cache-control: max-age=600@ (2026-11-18 (b)).
historicalFreshFor :: NominalDiffTime
historicalFreshFor = 600

-- | La clasificación a hoy guardada a las @at@, si a las @now@ aún se sirve sin volver a
-- Jolpica: mientras tenga menos de 'historicalFreshFor'.
keptToday :: UTCTime -> Maybe (UTCTime, [a]) -> Maybe [a]
keptToday now kept = case kept of
  Just (at, rows) | fresh now at -> Just rows
  _                              -> Nothing

-- | La clasificación de una ronda guardada a las @at@, si a las @now@ se sirve sin volver a
-- Jolpica: con filas, siempre, porque la de una ronda corrida ya no cambia; sin filas (una
-- ronda aún sin correr), mientras tenga menos de 'historicalFreshFor'.
keptStandings :: UTCTime -> (UTCTime, [a]) -> Maybe [a]
keptStandings now (at, rows)
  | not (null rows) || fresh now at = Just rows
  | otherwise                       = Nothing

fresh :: UTCTime -> UTCTime -> Bool
fresh now at = diffUTCTime now at < historicalFreshFor

-- | Lo que se sirve de la clasificación a hoy con lo que contestó Jolpica y lo guardado,
-- cuando lo guardado ya no es reciente: con filas, las de Jolpica; vacía, lo guardado o, sin
-- nada, la lista vacía, que es la verdad antes de la primera ronda; si Jolpica falló, lo
-- guardado o, sin nada, el fallo, y no un ejemplo inventado (2026-11-18 (c)).
servedToday :: Maybe (t, [a]) -> Either e [a] -> Either e [a]
servedToday kept answer = case answer of
  Right rows | not (null rows) -> Right rows
  Right rows                   -> Right (maybe rows snd kept)
  Left e                       -> maybe (Left e) (Right . snd) kept
