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
--
-- La lista que sirve @\/api\/telemetry@ es __plana y multi-piloto__: trae la
-- vuelta rápida de varios coches concatenada, así que cada punto va etiquetado
-- con 'tpDriver' y el consumidor agrupa o filtra. Lista etiquetada en vez de
-- lista anidada por el mismo criterio que hizo heterogéneo a 'HistoricalStat'
-- (2026-07-29): el tipo de @Server.Api@ sigue siendo
-- @[TelemetryPoint]@ y ni el enrutado ni el widget cambian de forma.
--
-- La identidad aquí es __solo el acrónimo__, a diferencia de 'HistoricalStat'
-- (código + nombre + apellido, 2026-07-28): una fila de
-- telemetría no es una fila de identidad — el acrónimo es la etiqueta de serie,
-- y repetir tres campos de identidad en cada una de las ~60 muestras por piloto
-- es payload sin información nueva. Ver (2026-07-31).
data TelemetryPoint = TelemetryPoint
  { tpDriver      :: Text    -- ^ Acrónimo del piloto (p. ej. @"VER"@).
  , tpSessionTime :: Double  -- ^ Tiempo de sesión en segundos.
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
--
-- La identidad va __por partida doble__: el acrónimo (@lcDriverA@) y el número
-- de coche (@lcCarA@). No es redundancia. La API de FastF1 habla __números de
-- coche__ y los widgets hablan __acrónimos__ (2026-08-01 y
-- 2026-08-03), y el acrónimo no permite reconstruir el número: solo el
-- microservicio conoce esa traducción. Sin @lcCarA@\/@lcCarB@ el consumidor
-- puede leer la comparación pero no puede pedir __otra__ — que es exactamente lo
-- que le faltaba a 'Widgets.Comparison' (2026-08-05).
data LapComparison = MkLapComparison
  { lcDriverA :: Text
  , lcDriverB :: Text
  , lcCarA    :: Text        -- ^ Número de coche de A (p. ej. @"1"@), el que acepta el query.
  , lcCarB    :: Text        -- ^ Número de coche de B (p. ej. @"16"@).
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
