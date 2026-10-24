{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Tyre Strategy: una fila por coche con sus stints como barras de color por
-- compuesto, sobre el mismo directo que Live Timing ('Widgets.Live').
--
-- __Lo que pinta lo calcula 'Common.TyreStrategy'__; aquí solo se elige qué estado
-- enseñar y se monta el DOM. Los stints solo los trae el feed: con otra fuente, el aviso
-- 'Common.TyreStrategy.noStintsNotice' y nada más.
module Widgets.TyreStrategy
  ( TyreState (..)
  , tyreStateOf
  , tyreStrategyWidget
  ) where

import           Common.Origin       (Source (..), Sourced (..))
import           Common.Shown        (Poll (..), delayWaitLabel)
import           Common.Types        (LiveTable (..))
import           Common.TyreStrategy (StintBar (..), StintRow (..), barStyle,
                                      compoundLegend, noStintsNotice, rowLabel,
                                      scaleLabel, stintRows, stintScale)
import           Control.Monad       (forM_)
import           Data.Text           (Text)
import           Reflex.Dom
import           Widgets.Live        (LiveView (..), indicatorOf, liveBadge)

-- | Qué enseña la tarjeta.
data TyreState
  = Loading
  | Failed
  | Waiting Text
    -- ^ Con retraso, mientras nada es tan viejo: el aviso de la espera.
  | NoStints
    -- ^ La tabla no sale del feed.
  | Loaded Int [StintRow]
    -- ^ La escala ('Common.TyreStrategy.stintScale') y las filas.
  deriving (Eq)

-- | Lo que se enseña a partir del estado del refresco, como
-- 'Widgets.LiveTiming.liveStateOf'.
tyreStateOf :: Poll (Sourced LiveTable) -> TyreState
tyreStateOf p =
  case pollShown p of
    Just shown
      | srcSource shown /= Just Feed -> NoStints
      | otherwise                    -> loaded (srcValue shown)
    Nothing
      | pollLastFailed p -> Failed
      | otherwise        -> Loading
  where
    loaded t = Loaded (stintScale (liveSession t) (liveStints t)) (stintRows t)

-- | La tarjeta, alimentada por el directo que le pasa quien la monta.
tyreStrategyWidget :: MonadWidget t m => LiveView t -> m ()
tyreStrategyWidget live = divClass "widget widget--tyre-strategy" $ do
  divClass "widget__head" $ do
    el "h2" $ text "Tyre Strategy"
    liveBadge (lvDelay live) (indicatorOf <$> lvPoll live)
  state <- holdUniqDyn (viewOf <$> lvDelay live <*> lvWait live <*> lvPoll live)
  dyn_ (renderState <$> state)
  where
    viewOf n (Just wait) _ = Waiting (delayWaitLabel n wait)
    viewOf _ Nothing p     = tyreStateOf p

    renderState :: DomBuilder t m => TyreState -> m ()
    renderState Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/live"
    renderState (Waiting label) =
      elClass "p" "status status--loading" $ text label
    renderState NoStints =
      elClass "p" "status status--empty tyre-strategy__notice" $ text noStintsNotice
    renderState (Loaded scale rows) = do
      divClass "tyre-strategy__legend" $ do
        forM_ compoundLegend $ \(cls, letter) ->
          elClass "span" ("tyre-strategy__key tyre--" <> cls) $ text letter
        elClass "span" "tyre-strategy__scale" $ text (scaleLabel scale)
      divClass "tyre-strategy" $ mapM_ row rows

    row :: DomBuilder t m => StintRow -> m ()
    row r = divClass "tyre-strategy__row" $ do
      elClass "span" "tyre-strategy__label" $ text (rowLabel r)
      divClass "tyre-strategy__track" $ mapM_ bar (srBars r)

    bar :: DomBuilder t m => StintBar -> m ()
    bar b = elAttr "span" attrs blank
      where
        attrs = "class" =: barClass <> "style" =: barStyle b <> "title" =: sbTitle b
        barClass
          | sbWidth b <= 0 = "tyre-strategy__bar tyre-strategy__bar--thin tyre--" <> sbClass b
          | otherwise      = "tyre-strategy__bar tyre--" <> sbClass b
