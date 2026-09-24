-- | Área estrategia de neumáticos — orquestación del caso de uso.
--
-- Coordina 'Handler.TyreStrategy.Manager' (efectos: GET a OpenF1 @/stints@ y
-- @/drivers@) y 'Handler.TyreStrategy.Helper' (mapeo puro) para producir
-- @[TyreStint]@, con la cache STM del 'Env' como respaldo: intenta el fetch
-- real; si funciona, refresca la cache y devuelve; si falla (red/4xx/5xx) o no
-- trae filas, sirve la última respuesta buena, y si nunca la hubo, el dummy
-- estático. Cada respuesta dice de qué peldaño salió ('Provenance'); el peldaño
-- lo decide 'Handler.TyreStrategy.Helper.tyreStep'. Espejo de 'Handler.Live.Context'.
module Handler.TyreStrategy.Context where

import           App                          (Env (..))
import           Common.Origin                (Origin (..))
import           Common.Types                 (TyreStint (..))
import           Config                       (Config)
import           Control.Concurrent.STM       (atomically, readTVar, writeTVar)
import           Control.Exception            (SomeException, try)
import           Data.Maybe                   (fromMaybe)
import           Data.Time.Clock              (getCurrentTime)
import           Handler.OpenF1.Manager       (fetchDrivers)
import           Handler.TyreStrategy.Helper  (assembleStints, tyreStep)
import qualified Handler.TyreStrategy.Manager as Manager
import           Provenance                   (Provenanced (..))

-- | Devuelve la estrategia de neumáticos (real de OpenF1, cache o dummy) con su
-- procedencia.
getTyreStrategy :: Env -> IO (Provenanced [TyreStint])
getTyreStrategy env = do
  result <-
    try (fetchStrategy (envConfig env)) :: IO (Either SomeException [TyreStint])
  now <- getCurrentTime
  served <- atomically $ do
    cached <- readTVar (envTyreCache env)
    let (shown, kept) = tyreStep now (either (const Nothing) Just result) cached
    writeTVar (envTyreCache env) kept
    pure shown
  pure (fromMaybe (Provenanced Sample Nothing Nothing dummy) served)

-- | Fetch de @/drivers@ + @/stints@ y ensamblado puro a @[TyreStint]@.
--
-- Recibe la 'Config' por el techo de duración de los GET, igual que
-- 'Handler.Live.Context.fetchRows'.
fetchStrategy :: Config -> IO [TyreStint]
fetchStrategy cfg = do
  drivers <- fetchDrivers cfg
  stints  <- Manager.fetchStints cfg
  pure (assembleStints drivers stints)

-- | Stints dummy por driver (respaldo cuando aún no hay respuesta de OpenF1).
dummy :: [TyreStint]
dummy =
  [ TyreStint "VER" "MEDIUM" 1 18
  , TyreStint "VER" "HARD" 19 44
  , TyreStint "LEC" "SOFT" 1 14
  , TyreStint "LEC" "HARD" 15 44
  ]
