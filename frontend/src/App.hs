{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Expone el contenido del @\<head\>@ ('headW') y del @\<body\>@ ('bodyW'), y el
-- 'dispatch' que enruta cada 'Route' a su página. Hay una sola
-- ruta ('Dashboard'); el fetch real vive en los widgets (constraint 'MonadWidget'
-- propagado desde 'liveTimingWidget'). @Router@ (navegación) llega cuando haya
-- múltiples rutas.
module App where

import           Pages.Dashboard (dashboardPage)
import           Reflex.Dom

-- | Ruta actual de la app. Sesión 1: una sola página.
data Route = Dashboard
  deriving (Eq, Show)

-- | Contenido del @\<head\>@.
headW :: DomBuilder t m => m ()
headW = el "title" $ text "F1 Functional Dashboard"

-- | Contenido del @\<body\>@: contenedor raíz + 'dispatch' de la ruta activa.
bodyW :: MonadWidget t m => m ()
bodyW = divClass "app" $ dispatch Dashboard

-- | Enruta cada 'Route' a su página.
dispatch :: MonadWidget t m => Route -> m ()
dispatch Dashboard = dashboardPage
