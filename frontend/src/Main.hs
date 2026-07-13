{-# LANGUAGE OverloadedStrings #-}

-- | Frontend del F1 Functional Dashboard (Reflex-DOM).
--
-- En Fase 0 es solo el skeleton: monta un widget estático. El sistema de
-- widgets y layouts (@Dynamic t Layout@, @renderWidget@) llega en Fase 2.
module Main (main) where

import Reflex.Dom

main :: IO ()
main = mainWidget $ do
  el "h1" $ text "F1 Dashboard skeleton"
  el "p" $ text "Fase 0 — frontend Reflex operativo."
