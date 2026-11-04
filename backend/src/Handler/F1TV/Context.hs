-- | Área cuenta de F1TV — orquestación: la hora de ahora y el fichero del token.
module Handler.F1TV.Context
  ( getAccount
  ) where

import           Common.Types           (F1TVAccount)
import           Data.Time.Clock        (getCurrentTime)
import           Handler.FastF1.Helper  (accountFrom)
import           Handler.FastF1.Manager (readTokenFile)

-- | Lee el fichero en cada llamada, sin cache: un inicio de sesión en otra terminal
-- se ve en la siguiente.
getAccount :: IO F1TVAccount
getAccount = accountFrom <$> getCurrentTime <*> readTokenFile
