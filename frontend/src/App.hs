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
--
-- El @\<link\>@ de la hoja de estilos se emite __aquí y no en
-- @frontend\/index.html@__: 'Reflex.Dom.mainWidgetWithHead' reemplaza el
-- contenido del @\<head\>@ al arrancar (@setInnerHTML \"\"@ antes de montar),
-- así que un enlace escrito en el HTML se carga y acto seguido se borra — y el
-- fallo se ve como «el CSS no se aplica», sin error ninguno
-- (2026-08-21). La hoja viaja al store junto al @.jsexe@
-- desde @packages.frontend@, de ahí que la ruta sea relativa.
headW :: DomBuilder t m => m ()
headW = do
  el "title" $ text "F1 Functional Dashboard"
  elAttr "link" ("rel" =: "stylesheet" <> "href" =: "dashboard.css") blank

-- | Contenido del @\<body\>@: contenedor raíz + 'dispatch' de la ruta activa.
bodyW :: MonadWidget t m => m ()
bodyW = divClass "app" $ dispatch Dashboard

-- | Enruta cada 'Route' a su página.
dispatch :: MonadWidget t m => Route -> m ()
dispatch Dashboard = dashboardPage
