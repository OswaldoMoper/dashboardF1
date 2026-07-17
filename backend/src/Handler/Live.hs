-- | Área Live timing — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/live@ y delega en la lógica del caso de uso. Fase 1: dummy
-- estático (ignora el 'Env'). En Fase 3 lo sustituye un @Handler.Live.Manager@
-- (efectos: cliente OpenF1) orquestado por un @Handler.Live.Context@, con las
-- transformaciones puras en @Handler.Live.Helper@.
module Handler.Live where

import App (Env)
import Common.Types (LiveTimingRow (..))
import Servant (Handler)

liveHandler :: Env -> Handler [LiveTimingRow]
liveHandler _env = pure dummy

-- | Top 3 estático (placeholder de la futura consulta a OpenF1).
dummy :: [LiveTimingRow]
dummy =
  [ LiveTimingRow 1 "VER" "Red Bull" "LEADER" "-" "1:29.345"
  , LiveTimingRow 2 "LEC" "Ferrari" "+1.234" "+1.234" "1:29.512"
  , LiveTimingRow 3 "NOR" "McLaren" "+3.877" "+2.643" "1:29.701"
  ]
