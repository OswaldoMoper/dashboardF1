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
    headers = ["Driver", "Entity", "Value", "Unit"]

    row :: DomBuilder t m => LabelMode -> HistoricalStat -> m ()
    row mode s = elClass "tr" (rowClass s) $ mapM_ (el "td" . text)
      [ statLabel mode s
      , entityLabel s
      , T.pack (show (hsValue s))
      , hsUnit s
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

-- | Entidad de la fila, en la columna @Entity@.
entityLabel :: HistoricalStat -> Text
entityLabel s = case hsEntity s of
  DriverStat      -> "Piloto"
  ConstructorStat -> "Constructor"

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
  codeClick   <- labelButton "Código"
  familyClick <- labelButton "Apellido"
  fullClick   <- labelButton "Nombre completo"
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
  allClick          <- labelButton "Todos"
  driversClick      <- labelButton "Pilotos"
  constructorsClick <- labelButton "Constructores"
  holdDyn AllEntities $ leftmost
    [ AllEntities      <$ allClick
    , OnlyDrivers      <$ driversClick
    , OnlyConstructors <$ constructorsClick
    ]

-- | Botón que emite un 'Event' al hacer click. Compartido por los dos switchers
-- del widget (etiqueta y entidad); conserva la clase @label-switcher__btn@ hasta que
-- exista una hoja de estilos que justifique separarlas.
labelButton :: DomBuilder t m => Text -> m (Event t ())
labelButton label = do
  (e, _) <- elClass' "button" "label-switcher__btn" $ text label
  pure (domEvent Click e)
