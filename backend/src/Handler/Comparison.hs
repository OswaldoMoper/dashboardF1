-- | Área comparación de vueltas — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/comparison@. Fase 1: dummy estático (ignora el 'Env'); en
-- Fase 4 lo alimenta un @Handler.Comparison.Manager@ (FastF1), orquestado por
-- un @Handler.Comparison.Context@.
module Handler.Comparison where

import App (Env)
import Common.Types (LapComparison (..))
import Servant (Handler)

comparisonHandler :: Env -> Handler LapComparison
comparisonHandler _env = pure dummy

-- | Comparación dummy entre dos drivers (placeholder de FastF1).
dummy :: LapComparison
dummy =
  MkLapComparison
    { lcDriverA = "VER"
    , lcDriverB = "LEC"
    , lcLapA = "1:29.345"
    , lcLapB = "1:29.512"
    , lcDelta = [0.0, -0.05, 0.08, 0.12, 0.167]
    }
