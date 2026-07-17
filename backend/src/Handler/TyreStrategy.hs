-- | Área estrategia de neumáticos — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/tyre-strategy@. Fase 1: dummy estático (ignora el 'Env');
-- en Fase 3 lo alimenta un @Handler.TyreStrategy.Manager@ sobre los stints de
-- OpenF1, orquestado por un @Handler.TyreStrategy.Context@.
module Handler.TyreStrategy where

import App (Env)
import Common.Types (TyreStint (..))
import Servant (Handler)

tyreStrategyHandler :: Env -> Handler [TyreStint]
tyreStrategyHandler _env = pure dummy

-- | Stints dummy por driver (placeholder de OpenF1).
dummy :: [TyreStint]
dummy =
  [ TyreStint "VER" "MEDIUM" 1 18
  , TyreStint "VER" "HARD" 19 44
  , TyreStint "LEC" "SOFT" 1 14
  , TyreStint "LEC" "HARD" 15 44
  ]
