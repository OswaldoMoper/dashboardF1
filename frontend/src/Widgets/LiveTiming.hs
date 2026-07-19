{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Live timing (categoría Timing).
--
-- Renderiza una tabla con las filas de 'LiveTimingRow' del dominio compartido
-- ('Common.Types'). Consume @GET \/api\/live@ en runtime vía
-- 'Client.fetchJson' + 'Common.Route.livePath' (relativo, misma-origen: el
-- backend sirve el bundle y la API en el mismo puerto). Modela los tres estados
-- del fetch ('Loading' \/ 'Failed' \/ 'Loaded'); ya no hay datos dummy locales.
module Widgets.LiveTiming where

import           Client       (fetchJson)
import           Common.Route (livePath)
import           Common.Types (LiveTimingRow (..))
import           Data.Text    (Text)
import qualified Data.Text    as T
import           Reflex.Dom

-- | Estado del fetch de @\/api\/live@. 'Failed' (no 'Error') para no chocar con
-- nombres de @base@\/@Prelude@.
data LiveState
  = Loading
  | Failed
  | Loaded [LiveTimingRow]

-- | Tabla de live timing alimentada por @\/api\/live@.
liveTimingWidget :: MonadWidget t m => m ()
liveTimingWidget = divClass "widget widget--live-timing" $ do
  el "h2" $ text "Live Timing"
  pb    <- getPostBuild
  resp  <- fetchJson (livePath <$ pb)          -- Event t (Maybe [LiveTimingRow])
  state <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ (renderState <$> state)
  where
    renderState :: DomBuilder t m => LiveState -> m ()
    renderState Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/live"
    renderState (Loaded rows) =
      elClass "table" "live-timing" $ do
        el "thead" $ el "tr" $ mapM_ (el "th" . text) headers
        el "tbody" $ mapM_ row rows

    headers :: [Text]
    headers = ["Pos", "Driver", "Team", "Gap", "Interval", "Last Lap"]

    row :: DomBuilder t m => LiveTimingRow -> m ()
    row r = el "tr" $ mapM_ (el "td" . text)
      [ T.pack (show (ltPosition r))
      , ltDriver r
      , ltTeam r
      , ltGap r
      , ltInterval r
      , ltLastLap r
      ]
