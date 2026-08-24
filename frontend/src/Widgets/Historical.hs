{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Estadísticas Históricas (categoría HistoricalStats).
--
-- Renderiza una tabla con los 'HistoricalStat' del dominio compartido
-- ('Common.Types'). Consume @GET \/api\/historical@ en runtime
-- vía 'Client.fetchJson' + 'Common.Route.historicalPath' (relativo, misma-origen:
-- el backend sirve el bundle y la API en el mismo puerto, con datos reales de
-- Jolpica). Modela los tres estados del fetch ('Loading' \/ 'Failed' \/ 'Loaded');
-- sin datos dummy locales.
--
-- La columna de etiqueta es conmutable ('LabelMode'): código \/ apellido \/ nombre
-- completo. El modo es __estado local del widget__ y se deriva de la identidad
-- estructurada que ya trae cada 'HistoricalStat' (2026-07-28),
-- así que conmutar __no re-dispara el fetch__: el @getPostBuild@ vive fuera del
-- 'dyn_' y solo se re-renderiza la tabla.
--
-- La lista es __heterogénea__ (pilotos y constructores), así que hay un segundo
-- estado local, el 'EntityFilter', y la etiqueta se proyecta según la marca
-- 'StatEntity' de cada fila (2026-07-29). Ambos selectores
-- viven fuera del 'dyn_': filtrar tampoco re-dispara el fetch.
module Widgets.Historical where

import           Client        (fetchJson)
import           Common.Route  (historicalPath)
import           Common.Types  (HistoricalStat (..), StatEntity (..))
import           Data.Text     (Text)
import qualified Data.Text     as T
import           Reflex.Dom

-- | Estado del fetch de @\/api\/historical@. 'Failed' (no 'Error') para no chocar
-- con nombres de @base@\/@Prelude@ (mismo criterio que 'Widgets.Telemetry').
data HState
  = Loading
  | Failed
  | Loaded [HistoricalStat]

-- | Qué identidad del piloto se muestra en la columna de etiqueta.
data LabelMode
  = Code    -- ^ Acrónimo (@"VER"@).
  | Family  -- ^ Apellido (@"Verstappen"@).
  | Full    -- ^ Nombre completo (@"Max Verstappen"@).
  deriving (Eq, Show)

-- | Qué entidades de la clasificación se listan.
data EntityFilter
  = AllEntities       -- ^ Pilotos y constructores (por defecto).
  | OnlyDrivers
  | OnlyConstructors
  deriving (Eq, Show)

-- | Tabla de estadísticas históricas alimentada por @\/api\/historical@, con
-- selector de etiqueta y filtro de entidad.
historicalWidget :: MonadWidget t m => m ()
historicalWidget = divClass "widget widget--historical" $ do
  el "h2" $ text "Historical Stats"
  modeDyn   <- labelSwitcher
  filterDyn <- entitySwitcher
  pb        <- getPostBuild
  resp      <- fetchJson (historicalPath <$ pb)
  state     <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ $ ffor (zipDyn (zipDyn modeDyn filterDyn) state) $
    \((mode, filt), st) -> renderState mode filt st
  where
    renderState :: DomBuilder t m => LabelMode -> EntityFilter -> HState -> m ()
    renderState _ _ Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState _ _ Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/historical"
    renderState mode filt (Loaded stats) =
      elClass "table" "historical" $ do
        el "thead" $ el "tr" $ mapM_ (el "th" . text) headers
        el "tbody" $ mapM_ (row mode) (filter (matchesFilter filt) stats)

    headers :: [Text]
    headers = ["Driver", "Puntos", "Victorias"]

    row :: DomBuilder t m => LabelMode -> HistoricalStat -> m ()
    row mode s = elClass "tr" (rowClass s) $ mapM_ (el "td" . text)
      [ statLabel mode s
      , T.pack (show (hsPoints s))
      , winsLabel s
      ]

-- | Etiqueta de la fila según el modo activo. Derivada de los campos ya cargados;
-- ningún modo requiere volver a consultar la API.
--
-- Un constructor lleva __etiqueta fija__ (su nombre legible): Jolpica no publica
-- acrónimo ni nombre\/apellido para un equipo, y mostrar el @constructorId@
-- (@"red_bull"@) sería exponer un identificador interno. El 'LabelMode' solo
-- proyecta sobre las filas de piloto.
statLabel :: LabelMode -> HistoricalStat -> Text
statLabel mode s = case hsEntity s of
  ConstructorStat -> hsFamilyName s
  DriverStat      -> case mode of
    Code   -> hsCode s
    Family -> hsFamilyName s
    Full   -> hsGivenName s <> " " <> hsFamilyName s

-- | Victorias de la fila, o una raya cuando Jolpica no las publica.
--
-- La raya __no es un cero__ y la distinción es la que 'Common.Types.hsWins' existe
-- para conservar: pintar @0@ afirmaría que la entidad no ganó ninguna carrera,
-- que es un dato que nadie dio. Con dato real no se ve —Jolpica publica @wins@
-- siempre, medido el 2026-08-24—; el dummy de 'Handler.Historical.Context' trae un
-- caso a propósito para que la rama sea visible sin editar código.
winsLabel :: HistoricalStat -> Text
winsLabel = maybe "—" (T.pack . show) . hsWins

-- | Clase del @\<tr\>@ por entidad. Hoy no hay hoja de estilos; queda como gancho
-- para cuando llegue.
rowClass :: HistoricalStat -> Text
rowClass s = case hsEntity s of
  DriverStat      -> "historical__row--driver"
  ConstructorStat -> "historical__row--constructor"

-- | Si la fila pasa el filtro activo.
matchesFilter :: EntityFilter -> HistoricalStat -> Bool
matchesFilter AllEntities      _ = True
matchesFilter OnlyDrivers      s = hsEntity s == DriverStat
matchesFilter OnlyConstructors s = hsEntity s == ConstructorStat

-- | Barra de botones que conmutan el modo de etiqueta. Sostiene el modo activo en
-- un @Dynamic t LabelMode@ (arranca en 'Code', la etiqueta previa al toggle).
-- Mismo patrón que 'Pages.Dashboard.layoutSwitcher'; el botón se replica aquí en
-- lugar de importarlo para no acoplar un widget a una página.
labelSwitcher :: MonadWidget t m => m (Dynamic t LabelMode)
labelSwitcher = divClass "label-switcher" $ do
  codeClick   <- switcherButton "Código"
  familyClick <- switcherButton "Apellido"
  fullClick   <- switcherButton "Nombre completo"
  holdDyn Code $ leftmost
    [ Code   <$ codeClick
    , Family <$ familyClick
    , Full   <$ fullClick
    ]

-- | Barra de botones que conmutan el filtro de entidad. Mismo patrón que
-- 'labelSwitcher' (arranca en 'AllEntities'); se monta __fuera__ del 'dyn_' del
-- fetch, así que filtrar no vuelve a consultar @\/api\/historical@.
entitySwitcher :: MonadWidget t m => m (Dynamic t EntityFilter)
entitySwitcher = divClass "entity-switcher" $ do
  allClick          <- switcherButton "Todos"
  driversClick      <- switcherButton "Pilotos"
  constructorsClick <- switcherButton "Constructores"
  holdDyn AllEntities $ leftmost
    [ AllEntities      <$ allClick
    , OnlyDrivers      <$ driversClick
    , OnlyConstructors <$ constructorsClick
    ]

-- | Botón que emite un 'Event' al hacer click. Compartido por los dos switchers
-- del widget (etiqueta y entidad).
--
-- La clase es @switcher__btn@ y no @label-switcher__btn@ desde el 2026-08-21: el
-- 'entitySwitcher' no tiene botón propio, así que sus botones salían al DOM con
-- el nombre del otro switcher y @frontend\/dashboard.css@ los estilaba por un
-- nombre que mentía. La hoja de estilos es la que lo hizo visible, que es el
-- orden que 2026-08-21 (b) buscaba. El __bloque__
-- (@label-switcher@ \/ @entity-switcher@) sí se conserva: son contenedores
-- distintos de verdad.
switcherButton :: DomBuilder t m => Text -> m (Event t ())
switcherButton label = do
  (e, _) <- elClass' "button" "switcher__btn" $ text label
  pure (domEvent Click e)
