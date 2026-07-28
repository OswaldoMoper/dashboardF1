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
module Widgets.Historical where

import           Client        (fetchJson)
import           Common.Route  (historicalPath)
import           Common.Types  (HistoricalStat (..))
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

-- | Tabla de estadísticas históricas alimentada por @\/api\/historical@, con
-- selector de etiqueta.
historicalWidget :: MonadWidget t m => m ()
historicalWidget = divClass "widget widget--historical" $ do
  el "h2" $ text "Historical Stats"
  modeDyn <- labelSwitcher
  pb      <- getPostBuild
  resp    <- fetchJson (historicalPath <$ pb)
  state   <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ (uncurry renderState <$> zipDyn modeDyn state)
  where
    renderState :: DomBuilder t m => LabelMode -> HState -> m ()
    renderState _ Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState _ Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/historical"
    renderState mode (Loaded stats) =
      elClass "table" "historical" $ do
        el "thead" $ el "tr" $ mapM_ (el "th" . text) headers
        el "tbody" $ mapM_ (row mode) stats

    headers :: [Text]
    headers = ["Driver", "Value", "Unit"]

    row :: DomBuilder t m => LabelMode -> HistoricalStat -> m ()
    row mode s = el "tr" $ mapM_ (el "td" . text)
      [ driverLabel mode s
      , T.pack (show (hsValue s))
      , hsUnit s
      ]

-- | Etiqueta del piloto según el modo activo. Derivada de los campos ya cargados;
-- ningún modo requiere volver a consultar la API.
driverLabel :: LabelMode -> HistoricalStat -> Text
driverLabel Code   s = hsCode s
driverLabel Family s = hsFamilyName s
driverLabel Full   s = hsGivenName s <> " " <> hsFamilyName s

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

-- | Botón que emite un 'Event' al hacer click.
labelButton :: DomBuilder t m => Text -> m (Event t ())
labelButton label = do
  (e, _) <- elClass' "button" "label-switcher__btn" $ text label
  pure (domEvent Click e)
