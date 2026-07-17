{-# LANGUAGE OverloadedStrings #-}

-- | Punto de entrada del frontend (Reflex-DOM).
--
-- Solo ensambla la infra: monta el @\<head\>@ y el @\<body\>@ definidos en 'App'.
-- El sistema de widgets/layouts vive bajo 'App' (dispatch), @Pages.*@ y @Widgets.*@.
module Main where

import qualified App
import           Reflex.Dom (mainWidgetWithHead)

main :: IO ()
main = mainWidgetWithHead App.headW App.bodyW
