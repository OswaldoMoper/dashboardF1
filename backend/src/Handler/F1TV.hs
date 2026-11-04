-- | Área cuenta de F1TV — capa de interfaz.
--
-- Expone @GET \/api\/f1tv@: si la cuenta con la que FastF1 abre el archivo de sesiones
-- acabadas vale, caducó o no hay, con la hora. Del fichero del token solo sale la hora.
module Handler.F1TV
  ( f1tvHandler
  ) where

import           Common.Types           (F1TVAccount)
import           Control.Monad.IO.Class (liftIO)
import qualified Handler.F1TV.Context   as Context
import           Servant                (Handler)

f1tvHandler :: Handler F1TVAccount
f1tvHandler = liftIO Context.getAccount
