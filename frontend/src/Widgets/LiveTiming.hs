{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Live timing (categoría Timing).
--
-- Renderiza una tabla con las filas de 'LiveTimingRow' del dominio compartido
-- ('Common.Types'). Los datos son dummy locales, espejo del
-- @liveHandler@ del backend (@backend\/src\/Handler\/Live.hs@).
module Widgets.LiveTiming where

import           Common.Types (LiveTimingRow (..))
import           Data.Text    (Text)
import qualified Data.Text    as T
import           Reflex.Dom

-- | Tabla estática de live timing.
liveTimingWidget :: DomBuilder t m => m ()
liveTimingWidget = divClass "widget widget--live-timing" $ do
  el "h2" $ text "Live Timing"
  elClass "table" "live-timing" $ do
    el "thead" $ el "tr" $ mapM_ (el "th" . text) headers
    el "tbody" $ mapM_ row dummy
  where
    headers :: [Text]
    headers = ["Pos", "Driver", "Team", "Gap", "Interval", "Last Lap"]

    row :: DomBuilder t m => LiveTimingRow -> m ()
    row r = el "tr" $ mapM_ (el "td" . text)
      [ T.pack (show (ltPosition r))
      , ltDriver r
      , ltTeam r
      , ltGap r
      , ltInterval r
      , ltLastLap r
      ]

-- | Top 3 estático, espejo del @dummy@ de @Handler.Live@ (placeholder hasta el
-- fetch real de @\/api\/live@).
dummy :: [LiveTimingRow]
dummy =
  [ LiveTimingRow 1 "VER" "Red Bull" "LEADER" "-" "1:29.345"
  , LiveTimingRow 2 "LEC" "Ferrari" "+1.234" "+1.234" "1:29.512"
  , LiveTimingRow 3 "NOR" "McLaren" "+3.877" "+2.643" "1:29.701"
  ]
