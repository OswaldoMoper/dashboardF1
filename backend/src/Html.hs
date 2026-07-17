-- | Shell HTML del F1 Functional Dashboard (INFRA).
--
-- Página mínima generada con Lucid que sirve el SPA: expone @<div id="app">@
-- como punto de montaje del frontend Reflex (Fase 2) y carga el bundle
-- @frontend.js@.
module Html where

import Lucid

-- | Shell: @div#app@ + script del bundle Reflex.
page :: Html ()
page = doctypehtml_ $ do
  head_ $ do
    meta_ [charset_ "utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    title_ "F1 Functional Dashboard"
  body_ $ do
    div_ [id_ "app"] "F1 Functional Dashboard"
    script_ [src_ "frontend.js"] ("" :: Html ())
