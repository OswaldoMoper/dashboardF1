{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Expone el contenido del @\<head\>@ ('headW') y del @\<body\>@ ('bodyW'), y el
-- 'dispatch' que enruta cada 'Route' a su página. Hay una sola
-- ruta ('Dashboard') y todavía sin fetch. @Router@ (navegación) y @Client@ (XHR
-- + XSRF) llegan cuando haya navegación y datos reales.
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
bodyW :: DomBuilder t m => m ()
bodyW = divClass "app" $ dispatch Dashboard

-- | Enruta cada 'Route' a su página.
dispatch :: DomBuilder t m => Route -> m ()
dispatch Dashboard = dashboardPage
