-- | Área temporada — orquestación: las sesiones de la temporada de Jolpica
-- ('Handler.Historical.Manager.fetchSeasonOf', leídas por 'Handler.Season.Helper') con los
-- nombres de FastF1 ('Handler.Season.Manager'), y la caja del 'Env' como ahorro y como
-- respaldo.
module Handler.Season.Context
  ( getSeason
  , getSeasonForKey
  , getNamedSeason
  , seasonFreshFor
  , getCircuitSeasons
  ) where

import           App                        (Env (..))
import           Common.Session             (CircuitRound, SeasonRace,
                                             SessionKey (..), firstCircuitYear,
                                             readSessionKey, sameCircuit)
import           Config                     (Config)
import           Control.Concurrent.STM     (atomically, readTVarIO, writeTVar)
import           Control.Exception          (SomeException, displayException,
                                             throwIO, try)
import           Data.Maybe                 (catMaybes, fromMaybe, isJust)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.IO               as TIO
import           Data.Time.Calendar         (toGregorian)
import           Data.Time.Clock            (NominalDiffTime, UTCTime (..),
                                             diffUTCTime, getCurrentTime)
import qualified Handler.Historical.Manager as Manager
import           Handler.Season.Helper      (FastF1Circuit (..), FastF1Event,
                                             JolpicaRace,
                                             readJolpica, seasonHasStarted,
                                             seasonRaces, seasonYear,
                                             withFastF1Names)
import qualified Handler.Season.Manager     as Season
import           Provenance                 (isoInstant)
import           System.IO                  (stderr)

-- | La temporada: la guardada si llegó hace menos de 'seasonFreshFor'; si no, la de
-- Jolpica, y si Jolpica falla o no trae ninguna carrera, la guardada aunque sea vieja.
-- Sin ninguna, la lista vacía: nunca un calendario inventado. Los nombres, los que tenía
-- al guardarse: no vuelve a pedirlos ('getNamedSeason').
getSeason :: Env -> IO [SeasonRace]
getSeason env = do
  now <- getCurrentTime
  cached <- readTVarIO (envSeasonCache env)
  case cached of
    Just (at, _, races) | diffUTCTime now at < seasonFreshFor -> pure races
    _ -> do
      result <- try (fetchSeason (envConfig env) now) :: IO (Either SomeException (Bool, [SeasonRace]))
      case result of
        Right (named, races) | not (null races) -> do
          atomically (writeTVar (envSeasonCache env) (Just (now, named, races)))
          pure races
        _ -> pure (maybe [] (\(_, _, races) -> races) cached)

-- | 'getSeason' para casar una clave, cuando los nombres no importan: sin nada guardado, la de
-- Jolpica con sus nombres, sin esperar los de FastF1 y __sin guardarla__, para que la guarde
-- 'getNamedSeason' con los de FastF1 (2026-11-18 (j)); con algo guardado, 'getSeason'. Si
-- Jolpica falla, la lista vacía.
getSeasonForKey :: Env -> IO [SeasonRace]
getSeasonForKey env = do
  cached <- readTVarIO (envSeasonCache env)
  case cached of
    Just _  -> getSeason env
    Nothing -> do
      now <- getCurrentTime
      result <- try (fetchJolpicaSeason (envConfig env) now) :: IO (Either SomeException (Int, [JolpicaRace]))
      pure (either (const []) (withFastF1Names [] . seasonRaces . snd) result)

-- | 'getSeason' para la lista de la página: si lo guardado lleva los nombres de Jolpica y
-- ya estaba antes de esta llamada, vuelve a pedir los de FastF1 y, si llegan, los guarda con
-- el mismo sello (2026-11-17 (n)). Mientras el microservicio no los dé, cada llamada lo
-- intenta otra vez, hasta su techo; la que acaba de pedir la temporada no repite.
getNamedSeason :: Env -> IO [SeasonRace]
getNamedSeason env = do
  before <- readTVarIO (envSeasonCache env)
  races <- getSeason env
  cached <- readTVarIO (envSeasonCache env)
  case (cached, seasonYear races) of
    (Just (at, False, _), Just y) | stamp before == Just at -> do
      now <- getCurrentTime
      events <- fetchNames (envConfig env) now y
      case events of
        Just es -> do
          let named = withFastF1Names es races
          atomically (writeTVar (envSeasonCache env) (Just (at, True, named)))
          pure named
        Nothing -> pure races
    _ -> pure races
  where
    stamp = fmap (\(at, _, _) -> at)

-- | Cuánto se sirve la temporada guardada sin volver a Jolpica.
seasonFreshFor :: NominalDiffTime
seasonFreshFor = 3600

-- | La del año en curso (UTC) si alguna de sus sesiones empezó ya; si no, la anterior. Con
-- los nombres del calendario de FastF1 ('withFastF1Names'), y si lo son; si el
-- microservicio no los da, los de Jolpica.
fetchSeason :: Config -> UTCTime -> IO (Bool, [SeasonRace])
fetchSeason cfg now = do
  (y, races) <- fetchJolpicaSeason cfg now
  events <- fetchNames cfg now y
  pure (isJust events, withFastF1Names (fromMaybe [] events) (seasonRaces races))

-- | La temporada de Jolpica que toca y su año, sin nombres de FastF1 (la regla del año, en
-- 'fetchSeason').
fetchJolpicaSeason :: Config -> UTCTime -> IO (Int, [JolpicaRace])
fetchJolpicaSeason cfg now = do
  let (year, _, _) = toGregorian (utctDay now)
  this <- fetchYear (fromInteger year)
  if seasonHasStarted now this
    then pure (fromInteger year, this)
    else (,) (fromInteger year - 1) <$> fetchYear (fromInteger year - 1)
  where
    fetchYear :: Int -> IO [JolpicaRace]
    fetchYear y = either (throwIO . userError) pure . readJolpica =<< Manager.fetchSeasonOf cfg y

-- | Los nombres del calendario de FastF1 de ese año; 'Nothing', con una línea en el log, si
-- el microservicio falla o no trae ninguno.
fetchNames :: Config -> UTCTime -> Int -> IO (Maybe [FastF1Event])
fetchNames cfg now y = do
  names <- try (Season.fetchSchedule cfg y) :: IO (Either SomeException [FastF1Event])
  case names of
    Right events | not (null events) -> pure (Just events)
    Right _                          -> Nothing <$ note "sin ningún gran premio"
    Left e                           -> Nothing <$ note (T.pack (displayException e))
  where
    note :: Text -> IO ()
    note t = TIO.hPutStrLn stderr (isoInstant now <> " [season] el calendario de FastF1: " <> t)

-- | Los grandes premios de otros años en el mismo circuito y con la misma disposición que el
-- de la sesión @session@ ('Common.Session.sameCircuit'), con los circuitos de cada año desde
-- 'Common.Session.firstCircuitYear' hasta el suyo. Un año que el microservicio no da no
-- cuenta; sin el de la sesión, o con una sesión ilegible, la lista vacía.
getCircuitSeasons :: Env -> Maybe Text -> IO [CircuitRound]
getCircuitSeasons env session = case readSessionKey =<< session of
  Nothing -> pure []
  Just k  -> do
    years <- mapM yearOf [firstCircuitYear .. skYear k]
    pure (sameCircuit (skYear k, skRound k) (catMaybes years))
  where
    yearOf y = do
      r <- try (Season.fetchCircuits (envConfig env) y) :: IO (Either SomeException [FastF1Circuit])
      pure (either (const Nothing) (\cs -> Just (y, [(fcRound c, fcCircuit c, fcName c) | c <- cs])) r)
