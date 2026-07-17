{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Infra del frontend (INFRA, raíz — convención de módulos,
-- 2026-07-16).
--
-- Expone el contenido del @\<head\>@ ('headW') y del @\<body\>@ ('bodyW'), y el
-- 'dispatch' que enruta cada 'Route' a su página. Hay una sola
-- ruta ('Dashboard') y todavía sin fetch. @Router@ (navegación) y @Client@ (XHR
-- + XSRF) llegan cuando haya navegación y datos reales.
module App where

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

-- | Enruta cada 'Route' a su página. Sesión 1: contenedor vacío (la página
-- 'Pages.Dashboard' con el widget LiveTiming se engancha en el commit siguiente).
dispatch :: DomBuilder t m => Route -> m ()
dispatch Dashboard = blank
