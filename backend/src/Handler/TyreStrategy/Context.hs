-- | Área estrategia de neumáticos — orquestación del caso de uso.
--
-- Coordina 'Handler.TyreStrategy.Manager' (efectos) y
-- 'Handler.TyreStrategy.Helper' (mapeo puro) para producir @[TyreStint]@, con la
-- cache STM del 'Env' como respaldo. En este scaffold aún devuelve el dummy
-- estático (sin red); el fetch real + cache + fallback se cablea en el commit
-- siguiente, espejo de 'Handler.Live.Context'.
module Handler.TyreStrategy.Context where

import           App          (Env)
import           Common.Types (TyreStint (..))

-- | Devuelve la estrategia de neumáticos (por ahora, el dummy estático).
getTyreStrategy :: Env -> IO [TyreStint]
getTyreStrategy _env = pure dummy

-- | Stints dummy por driver (respaldo cuando aún no hay respuesta de OpenF1).
dummy :: [TyreStint]
dummy =
  [ TyreStint "VER" "MEDIUM" 1 18
  , TyreStint "VER" "HARD" 19 44
  , TyreStint "LEC" "SOFT" 1 14
  , TyreStint "LEC" "HARD" 15 44
  ]
