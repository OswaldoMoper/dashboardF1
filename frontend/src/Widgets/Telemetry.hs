{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Telemetría (categoría Telemetry).
--
-- Renderiza una tabla con los 'TelemetryPoint' del dominio compartido
-- ('Common.Types'). Los datos son dummy locales, espejo del
-- @telemetryHandler@ del backend (@backend\/src\/Handler\/Telemetry.hs@). El
-- fetch real de @\/api\/telemetry@ (y un sparkline) llegan más adelante; por
-- ahora este módulo aporta el segundo widget de la pantalla.
module Widgets.Telemetry where

import           Common.Types (TelemetryPoint (..))
import           Data.Text    (Text)
import qualified Data.Text    as T
import           Reflex.Dom

-- | Tabla estática de telemetría.
telemetryWidget :: DomBuilder t m => m ()
telemetryWidget = divClass "widget widget--telemetry" $ do
  el "h2" $ text "Telemetry"
  elClass "table" "telemetry" $ do
    el "thead" $ el "tr" $ mapM_ (el "th" . text) headers
    el "tbody" $ mapM_ row dummy
  where
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

-- | Muestreo dummy a lo largo de una vuelta, espejo del @dummy@ de
-- @Handler.Telemetry@ (placeholder hasta el fetch real de @\/api\/telemetry@).
dummy :: [TelemetryPoint]
dummy =
  [ TelemetryPoint 0.0 0   312.5 1.0 0.0 8 11800
  , TelemetryPoint 0.5 42  298.1 0.0 0.6 7 10500
  , TelemetryPoint 1.0 78  265.3 0.0 1.0 5 9200
  , TelemetryPoint 1.5 110 289.7 0.8 0.0 6 10100
  , TelemetryPoint 2.0 156 320.4 1.0 0.0 8 12000
  ]
