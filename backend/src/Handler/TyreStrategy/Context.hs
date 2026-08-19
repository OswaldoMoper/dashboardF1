-- | Área estrategia de neumáticos — orquestación del caso de uso.
--
-- Coordina 'Handler.TyreStrategy.Manager' (efectos: GET a OpenF1 @/stints@ y
-- @/drivers@) y 'Handler.TyreStrategy.Helper' (mapeo puro) para producir
-- @[TyreStint]@, con la cache STM del 'Env' como respaldo: intenta el fetch
-- real; si funciona, refresca la cache y devuelve; si falla (red/4xx/5xx) o no
-- trae filas, sirve la última respuesta buena, y si nunca la hubo, el dummy
-- estático. Espejo de 'Handler.Live.Context'.
module Handler.TyreStrategy.Context where

import           App                          (Env (..))
import           Common.Types                 (TyreStint (..))
import           Config                       (Config)
import           Control.Concurrent.STM       (atomically, readTVarIO,
                                               writeTVar)
import           Control.Exception            (SomeException, try)
import           Data.Maybe                   (fromMaybe)
import           Handler.OpenF1.Manager       (fetchDrivers)
import           Handler.TyreStrategy.Helper  (assembleStints)
import qualified Handler.TyreStrategy.Manager as Manager

-- | Devuelve la estrategia de neumáticos (real de OpenF1, cache o dummy).
getTyreStrategy :: Env -> IO [TyreStint]
getTyreStrategy env = do
  result <-
    try (fetchStrategy (envConfig env)) :: IO (Either SomeException [TyreStint])
  case result of
    Right rows | not (null rows) -> do
      atomically (writeTVar (envTyreCache env) (Just rows))
      pure rows
    _ -> do
      cached <- readTVarIO (envTyreCache env)
      pure (fromMaybe dummy cached)

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
