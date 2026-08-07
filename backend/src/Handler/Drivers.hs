-- | Área parrilla — capa de interfaz (BUSINESS).
--
-- Expone @GET \/api\/drivers@ y delega en 'Handler.Drivers.Context', que orquesta
-- el caso de uso: fetch al microservicio FastF1, cache STM por sesión y respaldo
-- al dummy. A diferencia de las cinco áreas anteriores, ésta nace sin dummy
-- propio en la Fase 1: llega ya con el 'Context' hecho.
module Handler.Drivers where

import           App                     (Env)
import           Common.Types            (DriverEntry)
import           Control.Monad.IO.Class  (liftIO)
import           Data.Text               (Text)
import qualified Handler.Drivers.Context as Context
import           Servant                 (Handler)

-- | El 'Maybe' viene del @QueryParam@ opcional de 'Server.Api' y baja sin
-- interpretar: quien decide qué significa su ausencia es
-- 'Handler.Drivers.Context.resolveParams'. Espejo de
-- 'Handler.Comparison.comparisonHandler' con un parámetro menos — la parrilla no
-- admite filtro por coche.
driversHandler :: Env -> Maybe Text -> Handler [DriverEntry]
driversHandler env session = liftIO (Context.getDrivers env session)
