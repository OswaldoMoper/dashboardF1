-- | Un @try@ para el código que puede recibir una interrupción mientras espera.
module Sync
  ( trySync
  ) where

import           Control.Exception (SomeAsyncException (..), SomeException,
                                    fromException, tryJust)

-- | Como 'try', pero __deja pasar lo asíncrono__: el SIGINT de @cancela@ ('UserInterrupt')
-- tiene que llegar a la pieza aunque esté esperando una respuesta, y el aviso de 'timeout'
-- a quien puso el plazo.
trySync :: IO a -> IO (Either SomeException a)
trySync = tryJust (\e -> case fromException e of
  Just (SomeAsyncException _) -> Nothing
  Nothing                     -> Just e)
