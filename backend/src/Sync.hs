-- | Un @try@ para el código que puede recibir una interrupción mientras espera, y una
-- bajada a la vez por clave.
module Sync
  ( trySync
  , Flights
  , newFlights
  , joinFlight
  ) where

import           Control.Concurrent.STM (TMVar, TVar, atomically, modifyTVar',
                                         newEmptyTMVar, newTVarIO, putTMVar,
                                         readTMVar, readTVar, writeTVar)
import           Control.Exception      (SomeAsyncException (..), SomeException,
                                         fromException, mask, throwIO, try,
                                         tryJust)
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map

-- | Como 'try', pero __deja pasar lo asíncrono__: el SIGINT de @cancela@ ('UserInterrupt')
-- tiene que llegar a la pieza aunque esté esperando una respuesta, y el aviso de 'timeout'
-- a quien puso el plazo.
trySync :: IO a -> IO (Either SomeException a)
trySync = tryJust (\e -> case fromException e of
  Just (SomeAsyncException _) -> Nothing
  Nothing                     -> Just e)

-- | Las bajadas en marcha, por clave ('joinFlight').
type Flights k a = TVar (Map k (TMVar (Either SomeException a)))

-- | Sin ninguna bajada en marcha.
newFlights :: IO (Flights k a)
newFlights = newTVarIO Map.empty

-- | Ejecuta la acción, salvo si ya hay una en marcha con la misma clave: entonces no la
-- repite, espera y recibe su mismo resultado, también su excepción (aunque sea asíncrona,
-- como el 'timeout' de quien la lanzó). Al acabar la clave queda libre, así que la
-- siguiente llamada vuelve a ejecutarla: no guarda nada.
joinFlight :: Ord k => Flights k a -> k -> IO a -> IO a
joinFlight flights key act = mask $ \restore -> do
  joined <- atomically $ do
    running <- readTVar flights
    case Map.lookup key running of
      Just slot -> pure (Left slot)
      Nothing   -> do
        slot <- newEmptyTMVar
        writeTVar flights (Map.insert key slot running)
        pure (Right slot)
  case joined of
    Left slot -> restore (atomically (readTMVar slot)) >>= either throwIO pure
    Right slot -> do
      result <- try (restore act)
      atomically $ do
        putTMVar slot result
        modifyTVar' flights (Map.delete key)
      either throwIO pure result
