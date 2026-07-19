{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Página Dashboard (un módulo por flujo, convención @Pages.\<Flujo\>@).
--
-- Layout fijo con un único widget (Live timing). Los widgets adicionales
-- (Telemetry, …) y el layout conmutable llegan más adelante.
module Pages.Dashboard where

import           Reflex.Dom
import           Widgets.LiveTiming (liveTimingWidget)

-- | Pantalla del dashboard.
dashboardPage :: MonadWidget t m => m ()
dashboardPage = divClass "page page--dashboard" $ do
  el "h1" $ text "F1 Functional Dashboard"
  liveTimingWidget
