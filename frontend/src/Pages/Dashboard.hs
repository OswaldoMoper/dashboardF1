{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Página Dashboard (un módulo por flujo, convención @Pages.\<Flujo\>@).
--
-- Layout fijo con dos widgets (Live timing + Telemetry), que es el entregable
-- "≥2 widgets en pantalla". El layout conmutable ('Dynamic t Layout' + botones
-- Race Overview / Qualy) llega después.
module Pages.Dashboard where

import           Reflex.Dom
import           Widgets.LiveTiming (liveTimingWidget)
import           Widgets.Telemetry  (telemetryWidget)

-- | Pantalla del dashboard.
dashboardPage :: MonadWidget t m => m ()
dashboardPage = divClass "page page--dashboard" $ do
  el "h1" $ text "F1 Functional Dashboard"
  liveTimingWidget
  telemetryWidget
