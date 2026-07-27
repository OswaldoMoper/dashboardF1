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

-- | Tabla de estadísticas históricas alimentada por @\/api\/historical@.
historicalWidget :: MonadWidget t m => m ()
historicalWidget = divClass "widget widget--historical" $ do
  el "h2" $ text "Historical Stats"
  pb    <- getPostBuild
  resp  <- fetchJson (historicalPath <$ pb)
  state <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ (renderState <$> state)
  where
    renderState :: DomBuilder t m => HState -> m ()
    renderState Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/historical"
    renderState (Loaded stats) =
      elClass "table" "historical" $ do
        el "thead" $ el "tr" $ mapM_ (el "th" . text) headers
        el "tbody" $ mapM_ row stats

    headers :: [Text]
    headers = ["Label", "Value", "Unit"]

    row :: DomBuilder t m => HistoricalStat -> m ()
    row s = el "tr" $ mapM_ (el "td" . text)
      [ hsLabel s
      , T.pack (show (hsValue s))
      , hsUnit s
      ]
