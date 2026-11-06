-- | @dashboardF1-auto@: programa las comprobaciones de un día de GP en systemd.
--
-- * @dashboardF1-auto [día] [--horas p1=11:30,…] [--ensayo] [--log \<fichero\>]@ — enseña
--   el día, pide el OK y programa; después se queda enseñando la vista (Ctrl+C sale sin
--   cancelar). @--log@ es el fichero al que va la terminal de la instancia.
-- * @dashboardF1-auto estado@ — vuelve a enseñar la vista de la última carpeta.
-- * @dashboardF1-auto cancela@ — enseña lo que queda en systemd y, con el OK, lo para.
-- * @dashboardF1-auto dispara \<carpeta\> \<pieza\>@ — lo que corre cada temporizador.
--
-- Las carpetas del día van en @DASHBOARDF1_CARPETA@, o en @~\/MOPER@ sin ella ('mainFolder').
module Main (main) where

import           Auto.Context
import           Auto.Helper
import           Control.Concurrent  (threadDelay)
import           Control.Monad       (forM_, forever, unless, when)
import           Data.Maybe          (isJust, isNothing, listToMaybe)
import           Data.Text           (Text)
import qualified Data.Text           as T
import qualified Data.Text.IO        as TIO
import           Data.Time.Clock     (getCurrentTime)
import           Handler.Live.Helper (CalendarEntry (..))
import           System.Directory    (createDirectoryIfMissing,
                                      doesDirectoryExist, doesFileExist,
                                      findExecutable, getCurrentDirectory,
                                      getHomeDirectory, listDirectory,
                                      makeAbsolute)
import           System.Environment  (getArgs, getExecutablePath, lookupEnv)
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
    ["estado"]                        -> estado
    ["cancela"]                       -> cancela
    "dispara" : folder : label : rest -> dispara (T.unpack folder) label rest
    _                                 -> either quit launch (parseLaunch args)

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
  logFile <- traverse makeAbsolute (laLog l)
  forM_ logFile $ \f -> do
    exists <- doesFileExist f
    unless exists $ quit ("no existe " <> T.pack f <> ": revisa --log")
  busy <- either quit pure =<< autoUnits "dashboardF1-auto-*"
  unless (null busy) $ do
    say "Ya hay algo programado:"
    mapM_ (say . ("  " <>) . urUnit) busy
    quit "Para volver a lanzar, antes: dashboardF1-auto cancela"
  (port, answer) <- pickInstance
  let entries = case answer of
        Calendar es -> filter ((== day) . mexicoDay . ceStart) es
        _           -> []
      fromCalendar = slotsOn day (slotsFromCalendar entries)
      failure = calendarFailure answer
      relaunch hours = "  dashboardF1-auto " <> label <> " --horas " <> hours
  jolpica <-
    if isJust failure && isNothing manual then jolpicaDay day else pure Nothing
  forM_ failure $ \why -> do
    say (checkLine now Falla "calendario" why)
    when (isNothing manual && isNothing jolpica) $ do
      say "Vuelve a lanzar con las horas del día, p. ej.:"
      say (relaunch "p1=11:30,p2=15:00")
      say "(no se programa nada)"
      exitFailure
  let other = case (manual, jolpica) of
        (Just typed, _)   -> Just ("a mano", typed)
        (Nothing, Just j) -> Just ("Jolpica", j)
        _                 -> Nothing
      slots = maybe fromCalendar snd other
      cap = if laEnsayo l then 15 * 60 else capAfterStart
      plan = dayPlan cap now slots
      gp = listToMaybe (filter (not . T.null) (map ceGrandPrix entries))
      need = tokenNeed (case answer of Calendar es -> es; _ -> []) day slots
  when (null plan) $ do
    say "Ese día no hay sesiones por delante: no se programa nada."
    exitSuccess
  recorder <-
    maybe (quit "no encuentro dashboardF1-record: lanza con dashboardF1-auto") pure =<< findRecorder
  reader <-
    maybe (quit "no encuentro dashboardF1-observa: lanza con dashboardF1-auto") pure =<< findReader
  say (dayHeader day gp)
  say ""
  mapM_ say (dayTable now other plan)
  when (isJust manual && not (null fromCalendar)) $
    say ("  El calendario decía: " <> slotsSummary fromCalendar)
  (base, shown) <- existingBase
  existing <- listDirectory base
  let folder = nextFolder (dayFolder (if laEnsayo l then "ensayo" else label) day) existing
      path = base </> folder
  say ""
  say ("Carpeta: " <> shown <> "/" <> T.pack folder <> "/")
  ok <- confirm "¿Programar? [s/N] "
  unless ok $ do
    say "No se programa nada."
    forM_ jolpica $ \j -> do
      say "Para corregir una hora, vuelve a lanzar con:"
      say (relaunch (horasFlag j))
    exitSuccess
  okAt <- getCurrentTime
  let planned = dayPlan cap okAt slots
  when (null planned) $ do
    say ("El OK llegó a las " <> clockPair "%H:%M" okAt <> " y ya no queda nada por delante: no se programa nada.")
    exitSuccess
  createDirectoryIfMissing True path
  forM_ ((,) <$> failure <*> other) $ \(why, (source, _)) ->
    appendLine (path </> "comprobaciones.txt")
      (checkLine now Falla "calendario" (why <> "; horas " <> (if source == "Jolpica" then "de Jolpica" else source)))
  mapM_ (appendLine (path </> "resumen.txt")) (lateOkLines now plan okAt planned)
  exe <- getExecutablePath
  workDir <- getCurrentDirectory
  forM_ planned $ \p -> do
    let piece = plPiece p
        at = if plStart p <= okAt then Nothing else Just (plStart p)
    done <-
      schedule exe workDir path (unitName folder piece) (pieceLabel piece)
        (dispatchArgs (withChecks logFile need p (dispatchFor recorder reader port slots planned p))) at
    case done of
      Right () -> appendLine (path </> "resumen.txt") (programLine okAt p)
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
      say ( "Instancia: " <> instanceAt p
              <> T.concat ["  (en :" <> T.pack (show q) <> " no corre nada)" | q <- other] )
      pure (p, a)
    found -> choose found
  where
    choose found = do
      TIO.putStr "Corren las dos: ¿master (3000) o clon (3001)? [3000/3001] "
      hFlush stdout
      picked <- T.strip <$> TIO.getLine
      case [(p, a) | (p, a) <- found, T.pack (show p) == picked] of
        chosen@(p, _) : _ -> say ("Instancia: " <> instanceAt p) >> pure chosen
        []                -> choose found

-- | Repinta la vista de esa carpeta cada minuto, hasta Ctrl+C.
view :: FilePath -> IO ()
view folder = forever $ do
  (base, shown) <- baseFolder
  let path = base </> folder
      prefix = T.pack folder <> "-"
  events <- readLines (path </> "resumen.txt")
  units <- either (const []) id <$> autoUnits (prefix <> "*")
  timers <- either (const []) id <$> autoTimers (prefix <> "*")
  vigia <- readLines (path </> "vigia.txt")
  observer <- readLines (path </> "observador.txt")
  let states = unitStates units timers
      lines' =
        viewLines (viewHeader shown folder) events states (reconcile (expectedPending events) states)
          (lastOf vigia) (lastOf observer)
  TIO.putStr ("\ESC[2J\ESC[H" <> T.unlines lines')
  hFlush stdout
  threadDelay 60000000
  where
    lastOf xs = if null xs then Nothing else Just (last xs)

estado :: IO ()
estado = existingBase >> newestFolder >>= maybe (say "No hay ningún día lanzado.") view

-- | 'mainFolder' y cómo se enseña ('displayBase').
baseFolder :: IO (FilePath, Text)
baseFolder = do
  base <- mainFolder
  home <- getHomeDirectory
  pure (base, displayBase home base)

-- | Como 'baseFolder', pero si la carpeta no existe lo dice y sale.
existingBase :: IO (FilePath, Text)
existingBase = do
  found@(base, shown) <- baseFolder
  exists <- doesDirectoryExist base
  unless exists $
    quit ("No existe " <> shown <> ": créala, o pon otra carpeta en DASHBOARDF1_CARPETA.")
  pure found

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
  now <- getCurrentTime
  base <- mainFolder
  -- Antes de parar: lo que corre escribe su «para … (cancelado)» al pararse.
  mapM_ (\f -> appendLine (base </> f </> "resumen.txt") (cancelLine now)) newest
  stopUnits "dashboardF1-auto-"
  say "Cancelado."

-- | El grabador del store que pone @nix run .#auto@ en @DASHBOARDF1_RECORD@; sin ella, el
-- del @PATH@.
findRecorder :: IO (Maybe FilePath)
findRecorder = lookupEnv "DASHBOARDF1_RECORD" >>= maybe (findExecutable "dashboardF1-record") (pure . Just)

-- | El lector del store que pone @nix run .#auto@ en @DASHBOARDF1_OBSERVA@; sin ella, el
-- del @PATH@.
findReader :: IO (Maybe FilePath)
findReader = lookupEnv "DASHBOARDF1_OBSERVA" >>= maybe (findExecutable "dashboardF1-observa") (pure . Just)

-- | Lo que corre un temporizador al disparar: la pieza de su etiqueta.
dispara :: FilePath -> Text -> [Text] -> IO ()
dispara path label rest
  | label == pieceLabel Vigia = either quit (\d -> withSlot d (\s -> runVigia path label s d)) (parseDispara rest)
  | Right d <- parseDispara rest
  , Just s <- diSession d
  , account : _ <- [a | a <- [minBound .. maxBound], label == pieceLabel (Recording a s)] =
      maybe (quit "dispara: la grabación necesita --grabador")
        (\r -> withSlot d (\slot -> runRecording path label account slot r d)) (diRecorder d)
  | Right d <- parseDispara rest, label == pieceLabel (Checks (diSession d)) =
      maybe (quit "dispara: las comprobaciones necesitan --fin-hoy") (\t -> runChecks path label t d) (diTokenToday d)
  | Right d <- parseDispara rest, label == pieceLabel (Observer (diPause d)) =
      maybe (quit "dispara: el observador necesita --lector") (\r -> runObserver path label r d) (diReader d)
  | otherwise = either quit (const (quit ("dispara: no conozco la pieza «" <> label <> "»"))) (parseDispara rest)
  where
    withSlot d go = maybe (quit "dispara: falta --sesion o --inicio") go (watchedSlot d)
