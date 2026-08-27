{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Live timing (categoría Timing).
--
-- Renderiza una tabla con las filas de 'LiveTimingRow' del dominio compartido
-- ('Common.Types'). Consume @GET \/api\/live@ en runtime vía
-- 'Client.fetchJson' + 'Common.Route.livePath' (relativo, misma-origen: el
-- backend sirve el bundle y la API en el mismo puerto). Modela los tres estados
-- del fetch ('Loading' \/ 'Failed' \/ 'Loaded'); ya no hay datos dummy locales.
--
-- __La columna de estado se añade al final a propósito__ (2026-08-27). La hoja
-- alinea las columnas numéricas de esta tabla por @nth-child(1,4,5,6)@ —las
-- celdas de las seis primeras no llevan clase, son un @mapM_@ sobre una lista
-- fija—, así que meterla en cualquier otro sitio movería esos índices. La
-- séptima celda sí lleva clase, y la fila también: el @nth-child@ compartido es
-- deuda que el 2026-08-26 acabó de pagar en Historical
-- y lo nuevo no la reabre.
module Widgets.LiveTiming where

import           Client       (fetchJson)
import           Common.Route (livePath)
import           Common.Types (DriverStatus (..), LiveTimingRow (..),
                               statusLabel)
import           Data.Text    (Text)
import qualified Data.Text    as T
import           Reflex.Dom

-- | Estado del fetch de @\/api\/live@. 'Failed' (no 'Error') para no chocar con
-- nombres de @base@\/@Prelude@.
data LiveState
  = Loading
  | Failed
  | Loaded [LiveTimingRow]

-- | Tabla de live timing alimentada por @\/api\/live@.
liveTimingWidget :: MonadWidget t m => m ()
liveTimingWidget = divClass "widget widget--live-timing" $ do
  el "h2" $ text "Live Timing"
  pb    <- getPostBuild
  resp  <- fetchJson (livePath <$ pb)          -- Event t (Maybe [LiveTimingRow])
  state <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ (renderState <$> state)
  where
    renderState :: DomBuilder t m => LiveState -> m ()
    renderState Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/live"
    renderState (Loaded rows) =
      elClass "table" "live-timing" $ do
        el "thead" $ el "tr" $ mapM_ (el "th" . text) headers
        el "tbody" $ mapM_ row rows

    headers :: [Text]
    headers =
      ["Pos", "Driver", "Team", "Gap", "Interval", "Last Lap", "Estado"]

    row :: DomBuilder t m => LiveTimingRow -> m ()
    row r = elClass "tr" (rowClass (ltStatus r)) $ do
      mapM_ (el "td" . text)
        [ T.pack (show (ltPosition r))
        , ltDriver r
        , ltTeam r
        , ltGap r
        , ltInterval r
        , ltLastLap r
        ]
      elClass "td" "live-timing__state" $ text (statusLabel (ltStatus r))

    -- Modificador solo cuando hay algo que señalar: 16 de las 22 filas de una
    -- carrera son 'Running', y emitir un modificador que no modifica nada
    -- convierte la clase en ruido.
    --
    -- __Las tres marcas comparten modificador y no llevan uno cada una.__ La
    -- distinción la hace la sigla de la celda, que es texto y se lee; el
    -- modificador solo dice «esta fila no cuenta para la carrera», que es lo
    -- mismo en los tres casos. Tres reglas de color para tres estados que el
    -- usuario ya distingue leyendo serían tres cosas que mantener sincronizadas
    -- con el tipo de 'common'.
    rowClass :: DriverStatus -> Text
    rowClass Running = "live-timing__row"
    rowClass _       = "live-timing__row live-timing__row--out"
