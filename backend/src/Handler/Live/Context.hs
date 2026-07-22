-- | Área Live timing — orquestación del caso de uso.
--
-- Coordina 'Handler.Live.Manager' (efectos: GET a OpenF1) y
-- 'Handler.Live.Helper' (mapeo puro) para producir @[LiveTimingRow]@, con la
-- cache STM del 'Env' como respaldo.
module Handler.Live.Context where

import           App          (Env)
import           Common.Types (LiveTimingRow (..))

-- | Devuelve la tabla de live timing.
getLiveTiming :: Env -> IO [LiveTimingRow]
getLiveTiming _env = pure dummy

-- | Top 3 estático (respaldo cuando aún no hay respuesta real de OpenF1).
dummy :: [LiveTimingRow]
dummy =
  [ LiveTimingRow 1 "VER" "Red Bull" "LEADER" "-" "1:29.345"
  , LiveTimingRow 2 "LEC" "Ferrari" "+1.234" "+1.234" "1:29.512"
  , LiveTimingRow 3 "NOR" "McLaren" "+3.877" "+2.643" "1:29.701"
  ]
