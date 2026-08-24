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

-- | Un coche de la parrilla de una sesión: el par número↔acrónimo, con el equipo.
--
-- Es el __estado final__ del desajuste de vocabularios que 'LapComparison'
-- resolvió a medias (2026-08-05). Allí el número viaja
-- __dentro de lo mostrado__, así que el consumidor sabe de qué coches habla lo
-- que pinta pero no qué otros hay; aquí la traducción se publica entera, que es
-- lo que permite pedir datos de un coche que todavía no se ha visto.
--
-- __La lista es la de una sesión concreta__, no la del campeonato: un piloto
-- sustituto o un tercer coche en libres la cambian, y por eso el backend la
-- cachea por @session_key@.
--
-- 'deCode' puede __repetir__ el número cuando FastF1 no resuelve el acrónimo
-- (fallback de @_driver_label@ en @telemetry-service@): el coche está en la
-- sesión aunque no se sepa quién lo lleva, y esconderlo daría una parrilla
-- incompleta sin decirlo. 'deTeam' es lo único prescindible de los tres — es
-- decoración (agrupar, colorear), no identidad —, y llega vacío cuando el
-- servicio no lo publica.
data DriverEntry = MkDriverEntry
  { deNumber :: Text  -- ^ Número de coche (p. ej. @"1"@), el que acepta el query.
  , deCode   :: Text  -- ^ Acrónimo (p. ej. @"NOR"@), o el número si no resuelve.
  , deTeam   :: Text  -- ^ Equipo (p. ej. @"McLaren"@), o vacío.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON DriverEntry
instance FromJSON DriverEntry

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

-- | Estadística histórica de un piloto o de un constructor: __una fila por
-- entidad__, con una columna por métrica.
--
-- La identidad va __estructurada__ (código + nombre + apellido) en vez de una sola
-- etiqueta: el consumidor elige qué mostrar sin poder reconstruir el código a partir
-- del nombre. Ver (2026-07-28).
--
-- 'hsEntity' marca de qué clasificación viene la fila
-- (2026-07-29). Para un constructor la convención es @hsCode@ = @constructorId@
-- (p. ej. @"red_bull"@), @hsFamilyName@ = @name@ (@"Red Bull"@) y @hsGivenName@
-- vacío. Sigue siendo la marca que permite __partir__ la lista heterogénea que
-- sirve @\/api\/historical@ en las dos tablas que el widget pinta.
--
-- __La métrica está en las columnas y no en los datos__, que es el cambio de
-- 2026-08-24: hasta entonces el tipo era @(entidad, identidad, valor, unidad)@ y
-- cada entidad producía __dos__ filas —una de puntos y otra de victorias—, así que
-- un piloto salía en dos renglones de la tabla.
--
-- 'hsWins' admite ausencia y 'hsPoints' no, y el reparto no es defensivo sino
-- estructural. Con una fila por métrica, un @wins@ que no parseaba se descartaba
-- __solo a sí mismo__ y la fila de puntos sobrevivía; con una fila por entidad esa
-- salida no existe, y la alternativa a @Maybe@ sería descartar __la entidad
-- entera__ o inventar un cero que Jolpica no publicó. Que @wins@ pueda faltar es
-- un caso previsto del decode desde (2026-07-30), no una
-- observación: medido el 2026-08-24, Jolpica lo publica para las 34 entidades.
data HistoricalStat = HistoricalStat
  { hsEntity     :: StatEntity  -- ^ Piloto o constructor.
  , hsCode       :: Text    -- ^ Acrónimo del piloto (p. ej. @"VER"@).
  , hsGivenName  :: Text    -- ^ Nombre (p. ej. @"Max"@).
  , hsFamilyName :: Text    -- ^ Apellido (p. ej. @"Verstappen"@).
  , hsPoints     :: Double  -- ^ Puntos de la temporada en curso.
  , hsWins       :: Maybe Double  -- ^ Victorias, @Nothing@ si Jolpica no las publica.
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
