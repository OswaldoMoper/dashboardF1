-- | Área estrategia de neumáticos — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/tyre-strategy@ y delega en 'Handler.TyreStrategy.Context',
-- que orquesta el fetch a OpenF1 @/stints@ (vía 'Handler.TyreStrategy.Manager'),
-- el mapeo puro ('Handler.TyreStrategy.Helper') y la cache STM del 'Env'.
module Handler.TyreStrategy where

import           App                          (Env)
import           Common.Types                 (TyreStint)
import           Control.Monad.IO.Class       (liftIO)
import qualified Handler.TyreStrategy.Context as Context
import           Servant                      (Handler)

tyreStrategyHandler :: Env -> Handler [TyreStint]
tyreStrategyHandler env = liftIO (Context.getTyreStrategy env)
