-- | Área estrategia de neumáticos — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/tyre-strategy@ y delega en 'Handler.TyreStrategy.Context',
-- que orquesta el fetch a OpenF1 @/stints@ (vía 'Handler.TyreStrategy.Manager'),
-- el mapeo puro ('Handler.TyreStrategy.Helper') y la cache STM del 'Env'.
--
-- Responde con las cabeceras de procedencia ('Provenance'), como @\/api\/live@.
module Handler.TyreStrategy where

import           App                          (Env)
import           Common.Types                 (TyreStint)
import           Control.Monad.IO.Class       (liftIO)
import qualified Handler.TyreStrategy.Context as Context
import           Provenance                   (WithProvenance, withProvenance)
import           Servant                      (Handler)

-- | La respuesta de @\/api\/tyre-strategy@: los stints, más las tres cabeceras.
type TyreResponse = WithProvenance [TyreStint]

tyreStrategyHandler :: Env -> Handler TyreResponse
tyreStrategyHandler env = withProvenance <$> liftIO (Context.getTyreStrategy env)
