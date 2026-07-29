-- | Tipos compartidos del dominio del F1 Functional Dashboard.

module Common.Types where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Identificador de un widget dentro de un 'Layout'.
newtype WidgetId = WidgetId Text
  deriving stock (Eq, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Identificador de un 'Layout'.
newtype LayoutId = LayoutId Text
  deriving stock (Eq, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Fila del widget de live timing.
data LiveTimingRow = LiveTimingRow
  { ltPosition :: Int
  , ltDriver   :: Text
  , ltTeam     :: Text
  , ltGap      :: Text  -- ^ Gap al líder (p. ej. @"+1.234"@ o @"LEADER"@).
  , ltInterval :: Text  -- ^ Intervalo al coche de delante.
  , ltLastLap  :: Text  -- ^ Última vuelta (p. ej. @"1:23.456"@).
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LiveTimingRow
instance FromJSON LiveTimingRow

-- | Punto de telemetría a lo largo de una vuelta.
data TelemetryPoint = TelemetryPoint
  { tpSessionTime :: Double  -- ^ Tiempo de sesión en segundos.
  , tpDistance    :: Double  -- ^ Distancia recorrida en metros.
  , tpSpeed       :: Double
  , tpThrottle    :: Double
  , tpBrake       :: Double
  , tpGear        :: Int
  , tpRpm         :: Int
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON TelemetryPoint
instance FromJSON TelemetryPoint

-- | Comparación de una vuelta entre dos drivers.
data LapComparison = MkLapComparison
  { lcDriverA :: Text
  , lcDriverB :: Text
  , lcLapA    :: Text        -- ^ Tiempo de vuelta del driver A.
  , lcLapB    :: Text        -- ^ Tiempo de vuelta del driver B.
  , lcDelta   :: [Double]    -- ^ Delta acumulado A-B a lo largo de la vuelta.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LapComparison
instance FromJSON LapComparison

-- | Stint de neumáticos (periodo con un mismo compuesto).
data TyreStint = TyreStint
  { tsDriver   :: Text
  , tsCompound :: Text  -- ^ SOFT/MEDIUM/HARD/INTER/WET.
  , tsStartLap :: Int
  , tsEndLap   :: Int
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON TyreStint
instance FromJSON TyreStint

-- | A qué entidad de la clasificación pertenece un 'HistoricalStat'.
--
-- La lista que sirve @\/api\/historical@ es __heterogénea__ (pilotos y
-- constructores) y una fila de constructor no tiene acrónimo ni nombre\/apellido,
-- así que el consumidor necesita saber qué proyección de etiqueta aplicar. Ver
-- (2026-07-29).
data StatEntity
  = DriverStat
  | ConstructorStat
  deriving stock (Eq, Show, Generic)

instance ToJSON StatEntity
instance FromJSON StatEntity

-- | Estadística histórica (KPI de un piloto o de un constructor).
--
-- La identidad va __estructurada__ (código + nombre + apellido) en vez de una sola
-- etiqueta: el consumidor elige qué mostrar sin poder reconstruir el código a partir
-- del nombre. Ver (2026-07-28).
--
-- 'hsEntity' marca de qué clasificación viene la fila
-- (2026-07-29). Para un constructor la convención es @hsCode@ = @constructorId@
-- (p. ej. @"red_bull"@), @hsFamilyName@ = @name@ (@"Red Bull"@) y @hsGivenName@
-- vacío.
data HistoricalStat = HistoricalStat
  { hsEntity     :: StatEntity  -- ^ Piloto o constructor.
  , hsCode       :: Text    -- ^ Acrónimo del piloto (p. ej. @"VER"@).
  , hsGivenName  :: Text    -- ^ Nombre (p. ej. @"Max"@).
  , hsFamilyName :: Text    -- ^ Apellido (p. ej. @"Verstappen"@).
  , hsValue      :: Double
  , hsUnit       :: Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON HistoricalStat
instance FromJSON HistoricalStat

-- | Tipo de widget del dashboard (ver ROADMAP §Fase 2).
data WidgetType
  = LiveTiming
  | Telemetry
  | LapComparison
  | TyreStrategy
  | HistoricalStats
  | Custom
  deriving stock (Eq, Show, Generic)

instance ToJSON WidgetType
instance FromJSON WidgetType

-- | Parámetros configurables de un widget (clave → valor).
newtype WidgetParams = WidgetParams (Map Text Text)
  deriving stock (Eq, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Configuración de un widget dentro de un 'Layout'.
data WidgetConfig = WidgetConfig
  { widgetId   :: WidgetId
  , widgetType :: WidgetType
  , params     :: WidgetParams
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON WidgetConfig
instance FromJSON WidgetConfig

-- | Conjunto de widgets organizados en una pantalla.
data Layout = Layout
  { layoutId :: LayoutId
  , widgets  :: [WidgetConfig]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Layout
instance FromJSON Layout
