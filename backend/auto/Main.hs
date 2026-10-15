-- | @dashboardF1-auto@: programa las comprobaciones de un día de GP en systemd.
--
-- * @dashboardF1-auto [día] [--horas p1=11:30,…] [--ensayo]@ — enseña el día, pide el
--   OK y programa; después se queda enseñando la vista (Ctrl+C sale sin cancelar).
-- * @dashboardF1-auto estado@ — vuelve a enseñar la vista de la última carpeta.
-- * @dashboardF1-auto cancela@ — enseña lo que queda en systemd y, con el OK, lo para.
-- * @dashboardF1-auto dispara \<carpeta\> \<pieza\>@ — lo que corre cada temporizador.
module Main (main) where

import           Auto.Context
import           Auto.Helper
import           Control.Concurrent  (threadDelay)
import           Control.Monad       (forM_, forever, unless, when)
import           Data.Maybe          (fromMaybe, isJust, isNothing, listToMaybe)
import           Data.Text           (Text)
import qualified Data.Text           as T
import qualified Data.Text.IO        as TIO
import           Data.Time.Clock     (getCurrentTime)
import           Handler.Live.Helper (CalendarEntry (..))
import           System.Directory    (createDirectoryIfMissing,
                                      getCurrentDirectory, listDirectory)
import           System.Environment  (getArgs, getExecutablePath)
import           System.Exit         (exitFailure, exitSuccess)
import           System.FilePath     ((</>))
import           System.IO           (BufferMode (..), hFlush, hSetBuffering,
                                      hSetEncoding, stderr, stdin, stdout, utf8)

main :: IO ()
main = do
  mapM_ (`hSetEncoding` utf8) [stdin, stdout, stderr]
  hSetBuffering stdout LineBuffering
  args <- map T.pack <$> getArgs
  case args of
    ["estado"]                 -> estado
    ["cancela"]                -> cancela
    ["dispara", folder, label] -> dispara (T.unpack folder) label
    _                          -> either quit launch (parseLaunch args)

say :: Text -> IO ()
say = TIO.putStrLn

-- | Escribe el motivo y sale con error.
quit :: Text -> IO a
quit why = TIO.hPutStrLn stderr why >> exitFailure

-- | Una pregunta s/N: solo «s» (o «si», «sí») dice que sí.
confirm :: Text -> IO Bool
confirm question = do
  TIO.putStr question
  hFlush stdout
  answer <- T.toLower . T.strip <$> TIO.getLine
  pure (answer `elem` ["s", "si", "sí"])

launch :: Launch -> IO ()
launch l = do
  now <- getCurrentTime
  (label, day) <- either quit pure (resolveDay (mexicoDay now) (laDay l))
  when (laEnsayo l && isNothing (laHoras l)) $
    quit "el ensayo necesita --horas: p. ej. dashboardF1-auto --horas p1=11:50,p2=12:05 --ensayo"
  manual <- traverse (either quit pure . parseHoras day) (laHoras l)
  busy <- either quit pure =<< autoUnits "dashboardF1-auto-*"
  unless (null busy) $ do
    say "Ya hay algo programado:"
    mapM_ (say . ("  " <>) . urUnit) busy
    quit "Para volver a lanzar, antes: dashboardF1-auto cancela"
  (_, answer) <- pickInstance
  let entries = case answer of
        Calendar es -> filter ((== day) . mexicoDay . ceStart) es
        _           -> []
      fromCalendar = slotsOn day (slotsFromCalendar entries)
      failure = calendarFailure answer
      slots = fromMaybe fromCalendar manual
      cap = if laEnsayo l then 15 * 60 else capAfterStart
      plan = dayPlan cap now slots
      gp = listToMaybe (filter (not . T.null) (map ceGrandPrix entries))
  forM_ failure $ \why -> do
    say (checkLine now Falla "calendario" why)
    when (isNothing manual) $ do
      say "Vuelve a lanzar con las horas del día, p. ej.:"
      say ("  dashboardF1-auto " <> label <> " --horas p1=11:30,p2=15:00")
      say "(no se programa nada)"
      exitFailure
  when (null plan) $ do
    say "Ese día no hay sesiones por delante: no se programa nada."
    exitSuccess
  say (dayHeader day gp)
  say ""
  mapM_ say (dayTable now manual plan)
  when (isJust manual && not (null fromCalendar)) $
    say ("  El calendario decía: " <> slotsSummary fromCalendar)
  base <- mainFolder
  existing <- listDirectory base
  let folder = nextFolder (dayFolder (if laEnsayo l then "ensayo" else label) day) existing
      path = base </> folder
  say ""
  say ("Carpeta: ~/MOPER/" <> T.pack folder <> "/")
  ok <- confirm "¿Programar? [s/N] "
  unless ok $ say "No se programa nada." >> exitSuccess
  createDirectoryIfMissing True path
  forM_ failure $ \why ->
    appendLine (path </> "comprobaciones.txt") (checkLine now Falla "calendario" (why <> "; horas a mano"))
  exe <- getExecutablePath
  workDir <- getCurrentDirectory
  forM_ plan $ \p -> do
    let piece = plPiece p
        at = if plStart p <= now then Nothing else Just (plStart p)
    done <- schedule exe workDir path (unitName folder piece) (pieceLabel piece) at
    case done of
      Right () -> appendLine (path </> "resumen.txt") (programLine now p)
      Left err -> TIO.hPutStrLn stderr ("no se pudo programar " <> pieceLabel piece <> ": " <> err)
  view folder

-- | La instancia a la que se sigue: la que conteste en :3000 o :3001 y, si contestan
-- las dos, la que se elija.
pickInstance :: IO (Int, CalendarAnswer)
pickInstance = do
  answers <- mapM (\p -> fmap ((,) p) <$> askCalendar p) instancePorts
  case [a | Just a <- answers] of
    [] -> quit "No hay instancia en :3000 ni en :3001: arráncala y vuelve a lanzar."
    [(p, a)] -> do
      let other = [q | q <- instancePorts, q /= p]
      say ( "Instancia: " <> instanceName p <> " en :" <> T.pack (show p)
              <> T.concat ["  (en :" <> T.pack (show q) <> " no corre nada)" | q <- other] )
      pure (p, a)
    found -> choose found
  where
    choose found = do
      TIO.putStr "Corren las dos: ¿master (3000) o clon (3001)? [3000/3001] "
      hFlush stdout
      picked <- T.strip <$> TIO.getLine
      case [(p, a) | (p, a) <- found, T.pack (show p) == picked] of
        chosen@(p, _) : _ -> say ("Instancia: " <> instanceName p <> " en :" <> picked) >> pure chosen
        []                -> choose found

-- | Repinta la vista de esa carpeta cada minuto, hasta Ctrl+C.
view :: FilePath -> IO ()
view folder = forever $ do
  base <- mainFolder
  let path = base </> folder
      prefix = T.pack folder <> "-"
  events <- readLines (path </> "resumen.txt")
  units <- either (const []) id <$> autoUnits (prefix <> "*")
  timers <- either (const []) id <$> autoTimers (prefix <> "*")
  vigia <- readLines (path </> "vigia.txt")
  let states = unitStates units timers
      lines' =
        viewLines (viewHeader folder) events states (reconcile (expectedPending events) states) (lastOf vigia)
  TIO.putStr ("\ESC[2J\ESC[H" <> T.unlines lines')
  hFlush stdout
  threadDelay 60000000
  where
    lastOf xs = if null xs then Nothing else Just (last xs)

estado :: IO ()
estado = newestFolder >>= maybe (say "No hay ningún día lanzado.") view

cancela :: IO ()
cancela = do
  units <- either quit pure =<< autoUnits "dashboardF1-auto-*"
  timers <- either quit pure =<< autoTimers "dashboardF1-auto-*"
  let states = unitStates units timers
  when (null units) $ say "No hay nada programado." >> exitSuccess
  newest <- newestFolder
  say (cancelHeader (folderDay =<< newest))
  mapM_ (\(label, st) -> say ("  " <> T.justifyLeft 34 ' ' label <> st)) states
  ok <- confirm "¿Cancelar? [s/N] "
  unless ok $ say "No se cancela nada." >> exitSuccess
  stopUnits "dashboardF1-auto-"
  now <- getCurrentTime
  base <- mainFolder
  mapM_ (\f -> appendLine (base </> f </> "resumen.txt") (cancelLine now)) newest
  say "Cancelado."

-- | Lo que corre un temporizador al disparar: por ahora, la constancia.
dispara :: FilePath -> Text -> IO ()
dispara path label = do
  now <- getCurrentTime
  appendLine (path </> "resumen.txt") (firedLine now label)
