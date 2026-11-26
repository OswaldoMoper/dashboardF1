{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Tyre Strategy: una fila por coche con sus juegos como barras de color por
-- compuesto, sobre el mismo directo que Live Timing ('Widgets.Live').
--
-- __Lo que pinta lo calcula 'Common.TyreStrategy'__; aquí solo se elige qué estado
-- enseñar y se monta el DOM. Cuando la tabla no trae stints
-- ('Common.TyreStrategy.carriesStints'), el aviso 'Common.TyreStrategy.noStintsNotice' y
-- nada más.
module Widgets.TyreStrategy
  ( TyreState (..)
  , tyreStateOf
  , tyreStrategyWidget
  ) where

import           Common.Pilots               (highlightEdge, highlightFill)
import           Common.Session              (SessionKey, notFoundNotice,
                                              notRunNotice)
import           Common.TyreStrategy         (SetBar (..), SetRow (..),
                                              barNotches, compoundLegend,
                                              gridLines, lapTicks, leftStyle,
                                              noStintsNotice, notOutYet,
                                              rowLabel, scaleLabel, setStyle)
import           Control.Monad               (forM_)
import           Data.Maybe                  (isJust)
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Reflex.Dom
import           Widgets.Card                (CardExtras (..))
import           Widgets.Groups              (pill)
import           Widgets.Live                (LiveView (..), liveBadge)
import           Widgets.Live.Helper         (indicatorOf)
import           Widgets.TyreStrategy.Helper (TyreState (..), tyreStateOf,
                                              tyreViewOf)

-- | La tarjeta, alimentada por el directo que le pasa quien la monta, con lo que quien la
-- monta le pone dentro ('Widgets.Card.CardExtras'): junto al título, bajo la cabecera (lo
-- que devuelve es lo que devuelve la tarjeta) y las filas que destaca.
tyreStrategyWidget :: MonadWidget t m => Dynamic t (Maybe SessionKey) -> LiveView t -> CardExtras t m a -> m a
tyreStrategyWidget session live extras = divClass "widget widget--tyre-strategy" $ do
  divClass "widget__head" $ do
    el "h2" $ text "Tyre Strategy"
    cardBeside extras
    liveBadge (lvDelay live) (indicatorOf <$> (isJust <$> session) <*> lvPoll live)
  out <- cardUnder extras
  marked <- holdUniqDyn (cardHighlight extras)
  state <- holdUniqDyn (tyreViewOf <$> (isJust <$> session) <*> lvDelay live <*> lvWait live <*> lvPoll live)
  dyn_ (renderState <$> marked <*> state)
  pure out
  where
    renderState :: DomBuilder t m => [Text] -> TyreState -> m ()
    renderState _ Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState _ Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/live"
    renderState _ (Waiting label) =
      elClass "p" "status status--loading" $ text label
    renderState _ NotRun =
      elClass "p" "status status--empty" $ text notRunNotice
    renderState _ NotFound =
      elClass "p" "status status--empty" $ text notFoundNotice
    renderState _ NoStints =
      elClass "p" "status status--empty tyre-strategy__notice" $ text noStintsNotice
    renderState marked (Loaded scale rows) = do
      divClass "tyre-strategy__legend" $ do
        forM_ compoundLegend $ \(cls, letter) ->
          elClass "span" ("tyre-strategy__key tyre--" <> cls) $ text letter
        elClass "span" "tyre-strategy__scale" $ text (scaleLabel scale)
      divClass "tyre-strategy" $ do
        mapM_ (row scale marked) rows
        axis scale

    row :: DomBuilder t m => Int -> [Text] -> SetRow -> m ()
    -- Delante del nombre, la pastilla con la pareja del piloto (2026-11-21 (d)).
    row scale marked r = elAttr "div" ("class" =: "tyre-strategy__row" <> lit) $ do
      elClass "span" "tyre-strategy__label" $ pill (setDriver r) >> text (rowLabel r)
      divClass "tyre-strategy__track" $ do
        mapM_ (mark "tyre-strategy__grid") (gridLines scale)
        case setBars r of
          [] -> elClass "span" "tyre-strategy__empty" $ text notOutYet
          bs -> mapM_ bar bs
      where
        lit
          | setDriver r `elem` marked = "style" =: (highlightFill (setDriver r) <> ";" <> highlightEdge (setDriver r))
          | otherwise                 = mempty

    -- Las muescas y el número van dentro de la barra, el número el último para quedar
    -- encima; la hoja lo esconde donde la barra no le deja sitio.
    bar :: DomBuilder t m => SetBar -> m ()
    bar b = elAttr "span" attrs $ do
              mapM_ (mark "tyre-strategy__notch") (barNotches b)
              elClass "span" "tyre-strategy__total" $ text (T.pack (show (setTotal b)))
      where
        attrs = "class" =: T.unwords (barClasses b) <> "style" =: setStyle b <> "title" =: setTitle b

    barClasses b =
      ["tyre-strategy__bar", "tyre--" <> setClass b]
        ++ ["tyre-strategy__bar--thin" | setWidth b <= 0]
        ++ ["tyre-strategy__bar--used" | setUsed b]

    mark :: DomBuilder t m => Text -> Double -> m ()
    mark cls x = elAttr "span" ("class" =: cls <> "style" =: leftStyle x) blank

    axis :: DomBuilder t m => Int -> m ()
    axis scale = divClass "tyre-strategy__axis" $ do
      elClass "span" "tyre-strategy__label" blank
      divClass "tyre-strategy__track" $
        forM_ (lapTicks scale) $ \(lap, x) ->
          elAttr "span" ("class" =: "tyre-strategy__tick" <> "style" =: leftStyle x) $
            text (T.pack (show lap))
