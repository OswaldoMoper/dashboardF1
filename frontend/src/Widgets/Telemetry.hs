{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Telemetría (categoría Telemetry).
--
-- Renderiza una tabla con los 'TelemetryPoint' del dominio compartido
-- ('Common.Types'). Consume @GET \/api\/telemetry@ en runtime
-- vía 'Client.fetchJson' + 'Common.Route.telemetryPath' (relativo, misma-origen:
-- el backend sirve el bundle y la API en el mismo puerto). Modela los tres
-- estados del fetch ('Loading' \/ 'Failed' \/ 'Loaded'); ya no hay datos dummy
-- locales (patrón espejo de 'Widgets.LiveTiming').
module Widgets.Telemetry where

import           Client       (fetchJson)
import           Common.Route (telemetryPath)
import           Common.Types (TelemetryPoint (..))
import           Data.Text    (Text)
import qualified Data.Text    as T
import           Reflex.Dom

-- | Estado del fetch de @\/api\/telemetry@. 'Failed' (no 'Error') para no chocar
-- con nombres de @base@\/@Prelude@ (mismo criterio que 'Widgets.LiveTiming').
data TState
  = Loading
  | Failed
  | Loaded [TelemetryPoint]

-- | Tabla de telemetría alimentada por @\/api\/telemetry@.
telemetryWidget :: MonadWidget t m => m ()
telemetryWidget = divClass "widget widget--telemetry" $ do
  el "h2" $ text "Telemetry"
  pb    <- getPostBuild
  resp  <- fetchJson (telemetryPath <$ pb)
  state <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ (renderState <$> state)
  where
    renderState :: DomBuilder t m => TState -> m ()
    renderState Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/telemetry"
    renderState (Loaded points) =
      elClass "table" "telemetry" $ do
        el "thead" $ el "tr" $ mapM_ (el "th" . text) headers
        el "tbody" $ mapM_ row points

    headers :: [Text]
    headers =
      ["Session Time", "Distance", "Speed", "Throttle", "Brake", "Gear", "RPM"]

    row :: DomBuilder t m => TelemetryPoint -> m ()
    row p = el "tr" $ mapM_ (el "td" . text)
      [ T.pack (show (tpSessionTime p))
      , T.pack (show (tpDistance p))
      , T.pack (show (tpSpeed p))
      , T.pack (show (tpThrottle p))
      , T.pack (show (tpBrake p))
      , T.pack (show (tpGear p))
      , T.pack (show (tpRpm p))
      ]
