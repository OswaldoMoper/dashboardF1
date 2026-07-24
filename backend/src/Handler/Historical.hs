-- | Área estadísticas históricas — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/historical@. Fase 1: dummy estático (ignora el 'Env'); en
-- Fase 3 lo alimenta un @Handler.Historical.Manager@ sobre Jolpica, orquestado
-- por un @Handler.Historical.Context@.
module Handler.Historical where

import           App          (Env)
import           Common.Types (HistoricalStat (..))
import           Servant      (Handler)

historicalHandler :: Env -> Handler [HistoricalStat]
historicalHandler _env = pure dummy

-- | Estadísticas dummy (placeholder de la futura consulta a Jolpica).
dummy :: [HistoricalStat]
dummy =
  [ HistoricalStat "Wins" 63 "races"
  , HistoricalStat "Pole positions" 44 "quali"
  , HistoricalStat "Fastest laps" 34 "laps"
  ]
