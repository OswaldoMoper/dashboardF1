-- | Bootstrap del backend: construye el 'Env' a partir de la 'Config' (INFRA).
--
-- Fase 1: el 'Env' solo transporta la configuración. El pool de PostgreSQL y
-- los clientes de servicios externos se añaden aquí (en @mkEnv@) conforme
-- lleguen (Fases 3–4).
module App where

import Config (Config)

newtype Env = Env
  { envConfig :: Config
  }

mkEnv :: Config -> IO Env
mkEnv cfg = pure (Env cfg)
