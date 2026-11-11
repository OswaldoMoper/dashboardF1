-- | @dashboardF1-auto@: programa un GP, o un día de GP, en systemd. El modo lo pone el
-- lanzador en @DASHBOARDF1_MODO@ ('modeFrom').
--
-- * @dashboardF1-auto [gp] [--ensayo] [--calendario \<fichero\>] [--log \<fichero\>]@ — modo
--   «ver»: el GP que viene, una tanda de comprobaciones por día, con un solo OK.
-- * @dashboardF1-autodev gp [--ensayo] [--calendario \<fichero\>] [--relectura \<min\>]
--   [--log \<fichero\>]@ — modo «desarrollo»: el GP con todas sus piezas y la relectura
--   de horas. @--calendario@ es un @\/api\/calendar@ guardado en un fichero.
-- * @dashboardF1-autodev [día] [--horas p1=11:30,…] [--ensayo] [--log \<fichero\>]@ — un
--   día con todas sus piezas. @--log@ es el fichero al que va la terminal de la instancia.
--
-- Al lanzar el GP, en los dos modos, si nadie contesta en @:3000@ arranca @master@ como
-- unidad de @systemd --user@ y espera a que conteste; una pieza horaria lo vuelve a mirar.
-- Tras el OK se queda enseñando la vista (Ctrl+C sale sin cancelar).
-- * @dashboardF1-auto estado@ — vuelve a enseñar la vista de la última carpeta.
-- * @dashboardF1-auto cancela@ — enseña lo que queda en systemd y, con el OK, lo para.
-- * @dashboardF1-auto arranque@ — tras un apagado, vuelve a programar sin preguntar el GP
--   que se lanzó y no acabó ni se canceló; para un servicio, no para una terminal.
-- * @dashboardF1-auto dispara \<carpeta\> \<pieza\>@ — lo que corre cada temporizador.
--
-- Las carpetas del día van en @DASHBOARDF1_CARPETA@, o en @~\/MOPER@ sin ella ('mainFolder').
module Main (main) where

import           Auto.Context
import           Auto.Helper
import           Control.Concurrent  (threadDelay)
import           Control.Monad       (forM_, forever, join, unless, when)
import           Data.List           (find, nub, sortOn)
import           Data.Maybe          (fromMaybe, isJust, isNothing, listToMaybe,
                                      mapMaybe)
import           Data.Text           (Text)
import qualified Data.Text           as T
import qualified Data.Text.IO        as TIO
import           Data.Time.Calendar  (showGregorian)
import           Data.Time.Clock     (UTCTime, getCurrentTime)
import           Handler.Live.Helper (CalendarEntry (..))
import           System.Directory    (createDirectoryIfMissing,
                                      doesDirectoryExist, doesFileExist,
                                      findExecutable, getCurrentDirectory,
                                      getHomeDirectory, listDirectory,
                                      makeAbsolute)
import           System.Environment  (getArgs, getExecutablePath, lookupEnv)
import           System.Exit         (exitFailure, exitSuccess)
import           System.FilePath     (takeDirectory, takeFileName, (</>))
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
    ["arranque"]                      -> arranque
    "dispara" : folder : label : rest -> dispara (T.unpack folder) label rest
    _                                 -> either quit start (parseLaunch args)

-- | El día o el GP, en el modo del lanzador ('inMode'), tras comprobar que lo pedido casa
-- ('launchProblem') y que el modo lo hace ('modeProblem').
start :: Launch -> IO ()
start asked = do
  mode <- modeFrom <$> lookupEnv "DASHBOARDF1_MODO"
  let l = inMode mode asked
  forM_ (launchProblem l) quit
  forM_ (modeProblem mode l) quit
  if laGp l then launchGp mode l else launch l

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
    quit "el ensayo necesita --horas: p. ej. dashboardF1-autodev --horas p1=11:50,p2=12:05 --ensayo"
  manual <- traverse (either quit pure . parseHoras day) (laHoras l)
  logFile <- checkedLog l
  refuseIfBusy
  (port, answer) <- pickInstance
  let entries = case answer of
        Calendar es -> filter ((== day) . mexicoDay . ceStart) es
        _           -> []
      fromCalendar = slotsOn day (slotsFromCalendar entries)
      failure = calendarFailure answer
      relaunch hours = "  dashboardF1-autodev " <> label <> " --horas " <> hours
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
  tools <- findTools "dashboardF1-autodev"
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
  programDay logFile need Nothing tools port path folder slots okAt planned planned
  view folder

-- | El @--log@ en absoluto; si no existe, lo dice y sale.
checkedLog :: Launch -> IO (Maybe FilePath)
checkedLog l = do
  logFile <- traverse makeAbsolute (laLog l)
  forM_ logFile $ \f -> do
    exists <- doesFileExist f
    unless exists $ quit ("no existe " <> T.pack f <> ": revisa --log")
  pure logFile

-- | Si ya hay algo programado, lo enseña y sale.
refuseIfBusy :: IO ()
refuseIfBusy = do
  busy <- either quit pure =<< autoUnits "dashboardF1-auto-*"
  unless (null busy) $ do
    say "Ya hay algo programado:"
    mapM_ (say . ("  " <>) . urUnit) busy
    quit "Para volver a lanzar, antes: dashboardF1-auto cancela"

-- | Programa en systemd esas piezas de un día, en su carpeta, con el plan entero del día
-- (de él sale la sesión que mira el vigía), y apunta cada una en su @resumen.txt@; la que
-- no se puede programar lo dice en la terminal. El tramo del diario de @master@ es para
-- las tandas de un día sin tope ('withJournal').
programDay ::
  Maybe FilePath -> Maybe (UTCTime, Maybe UTCTime) -> Maybe (UTCTime, UTCTime) -> Tools -> Int -> FilePath -> FilePath
    -> [Slot] -> UTCTime -> [Planned] -> [Planned] -> IO ()
programDay logFile need journal tools port path folder slots okAt planned pieces = do
  exe <- getExecutablePath
  workDir <- getCurrentDirectory
  forM_ pieces $ \p -> do
    let piece = plPiece p
        at = if plStart p <= okAt then Nothing else Just (plStart p)
    done <-
      schedule exe workDir path (unitName folder piece) (pieceLabel piece)
        (dispatchArgs (withJournal journal p (withChecks logFile need p (dispatchFor tools port slots planned p)))) at
    case done of
      Right () -> appendLine (path </> "resumen.txt") (programLine okAt p)
      Left err -> TIO.hPutStrLn stderr ("no se pudo programar " <> pieceLabel piece <> ": " <> err)

-- | El GP que viene, todos sus días con un OK, en ese modo ('gpPlanFor'). Las horas: las
-- de @--calendario@, las de la instancia o, si esta no las da, las de Jolpica. Los
-- @resumen.txt@ se escriben del último día al primero, para que la última carpeta escrita
-- ('newestFolder', la de @estado@) sea la del primer día. Antes de nada mira @master@
-- ('lookAfterMaster') y, si lo arrancó, espera a que conteste. En la carpeta del primer
-- día van @gp.json@ y la mirada horaria a @master@; solo en «desarrollo», además, la
-- relectura de horas.
launchGp :: Mode -> Launch -> IO ()
launchGp mode l = do
  now <- getCurrentTime
  logFile <- checkedLog l
  refuseIfBusy
  nix <- maybe (quit "no encuentro nix en el PATH: master no se podría arrancar") pure =<< findExecutable "nix"
  dir <- masterDir <$> getHomeDirectory <*> lookupEnv "DASHBOARDF1_MASTER"
  action <- either (quit . ("no se pudo arrancar master: " <>)) pure =<< lookAfterMaster nix dir
  say (masterLine now action)
  unless (action == UseRunning) $ do
    up <- waitForMaster masterWaitStep masterWaitTries (\s -> say ("  master en :3000 aún no contesta (" <> T.pack (show s) <> " s)"))
    unless up $
      quit ("master no contesta en :3000 tras " <> T.pack (show (masterWaitStep * masterWaitTries `div` 60))
              <> " min: mira journalctl --user -u " <> masterUnit)
  (port, answer) <- pickInstance
  fromFile <- traverse readCalendarFile (laCalendario l)
  let failure = if isJust fromFile then Nothing else calendarFailure answer
      entries = case fromMaybe answer fromFile of
        Calendar es -> es
        _           -> []
  jolpica <- if isJust failure then jolpicaSeason else pure Nothing
  forM_ failure $ \why -> do
    say (checkLine now Falla "calendario" why)
    when (isNothing jolpica) $ do
      say "Jolpica tampoco da las horas: no se programa nada."
      exitFailure
  let other = case (laCalendario l, jolpica) of
        (Just _, _)       -> Just ("fichero", slotsFromCalendar entries)
        (Nothing, Just j) -> Just ("Jolpica", j)
        _                 -> Nothing
      slots = maybe (slotsFromCalendar entries) snd other
      cap = if laEnsayo l then 15 * 60 else capAfterStart
      days = gpPlanFor mode cap now slots
      starts = map slotStart (concatMap gdSlots days)
      gp = listToMaybe [ceGrandPrix e | e <- entries, not (T.null (ceGrandPrix e)), ceStart e `elem` starts]
      label d = if laEnsayo l then "ensayo" else gdLabel d
  when (null days) $ do
    say "No queda ningún GP por delante: no se programa nada."
    exitSuccess
  tools <- findTools (modeLauncher mode)
  (base, shown) <- existingBase
  existing <- listDirectory base
  let folders = map (\d -> nextFolder (dayFolder (label d) (gdDay d)) existing) days
      shownDays = zip days folders
  mapM_ say (gpSummary mode gp now shownDays)
  forM_ shownDays $ \(d, folder) -> do
    say ""
    say (dayHeader (gdDay d) gp)
    say ""
    -- La columna de la hora, con las sesiones de este GP: su nombre no se repite dentro de él.
    mapM_ say (dayTable now (fmap (\(source, _) -> (source, gdSlots d)) other) (gdPlan d))
    say ""
    say ("Carpeta: " <> shown <> "/" <> T.pack folder <> "/")
  say ""
  ok <- confirm (if length days == 1 then "¿Programar el día? [s/N] " else "¿Programar los " <> T.pack (show (length days)) <> " días? [s/N] ")
  unless ok $ say "No se programa nada." >> exitSuccess
  okAt <- getCurrentTime
  let planned = gpPlanFor mode cap okAt slots
  when (null planned) $ do
    say ("El OK llegó a las " <> clockPair "%H:%M" okAt <> " y ya no queda nada por delante: no se programa nada.")
    exitSuccess
  let kept = [(gdDay seen, f) | (seen, f) <- shownDays, any ((== gdDay seen) . gdDay) planned]
      journals = zip (map gdDay planned) (checksLogWindows okAt planned)
  forM_ (reverse shownDays) $ \(seen, folder) ->
    case find ((== gdDay seen) . gdDay) planned of
      Nothing -> say ("El OK llegó tarde: del " <> T.pack (showGregorian (gdDay seen)) <> " ya no queda nada, no se programa.")
      Just d -> do
        let path = base </> folder
        createDirectoryIfMissing True path
        forM_ ((,) <$> failure <*> other) $ \(why, _) ->
          appendLine (path </> "comprobaciones.txt") (checkLine now Falla "calendario" (why <> "; horas de Jolpica"))
        when (Just folder == fmap snd (listToMaybe kept)) $
          appendLine (path </> "resumen.txt") (masterLine now action)
        mapM_ (appendLine (path </> "resumen.txt")) (lateOkLines now (gdPlan seen) okAt (gdPlan d))
        programDay logFile (tokenNeed entries (gdDay d) (gdSlots d)) (join (lookup (gdDay d) journals)) tools port path folder
          (gdSlots d) okAt (gdPlan d) (gdPlan d)
  forM_ (listToMaybe kept) $ \(_, first) -> do
    let path = base </> first
        every = fromMaybe relecturaDefault (laRelectura l)
        -- La mirada a master, cada hora; en un ensayo, al paso de la relectura, para verla repetir.
        watchEvery = if laEnsayo l then every else relecturaDefault
        program = programEvery path
    writeGpState (path </> gpStateFile)
      GpState
        { gsSlots = concatMap gdSlots planned
        , gsPort = port
        , gsTools = tools
        , gsNix = nix
        , gsMasterDir = dir
        , gsLog = logFile
        , gsCapSeconds = round cap
        , gsEnsayo = laEnsayo l
        , gsCalendario = laCalendario l
        , gsFolders = kept
        , gsMode = Just mode
        , gsCancelled = False
        , gsLaunched = Just okAt
        }
    program (masterWatchUnit first) masterWatchLabel watchEvery (masterWatchLine okAt watchEvery)
    when (mode == Desarrollo) $
      program (relecturaUnit first) relecturaLabel every (relecturaLine okAt every)
  maybe (pure ()) (view . snd) (listToMaybe kept)

-- | Programa en systemd una pieza que se repite cada tantos minutos desde esa carpeta, y
-- la apunta en su @resumen.txt@ con esa línea; si no se puede, lo dice en la terminal.
programEvery :: FilePath -> Text -> Text -> Int -> Text -> IO ()
programEvery path unit what minutes line = do
  exe <- getExecutablePath
  workDir <- getCurrentDirectory
  done <- scheduleEvery exe workDir path unit what [] (fromIntegral (minutes * 60))
  case done of
    Right () -> appendLine (path </> "resumen.txt") line
    Left err -> TIO.hPutStrLn stderr ("no se pudo programar " <> what <> ": " <> err)

-- | Tras un apagado: vuelve a programar, sin preguntar, el GP que vuelve ('liveGp'), con
-- las horas, el modo, el puerto y las carpetas de su @gp.json@, y las herramientas de
-- ahora ('findTools'). Lo que ya empezó arranca en el acto. Deja 'returnLine' en el
-- @resumen.txt@ de cada día que programa. Si @master@ no arranca o no contesta, lo apunta
-- y programa igual. Sin calendario (ni el fichero del lanzamiento ni la instancia), la
-- cuenta del token se juzga solo con las horas de inicio ('tokenNeed'). Con algo ya
-- programado, o sin GP que vuelva, lo dice y sale sin error.
arranque :: IO ()
arranque = do
  busy <- either quit pure =<< autoUnits "dashboardF1-auto-*"
  unless (null busy) $ say "Ya hay algo programado: no se relanza nada." >> exitSuccess
  now <- getCurrentTime
  gps <- gpStates
  case [(f, s, m) | (f, s) <- gps, Just s == liveGp now (map snd gps), Just m <- [gsMode s]] of
    [] -> say "No hay ningún GP que volver a lanzar."
    (first, st, mode) : _ -> do
      say (returnHeader first st)
      base <- mainFolder
      tools <- findTools (modeLauncher mode)
      looked <- lookAfterMaster (gsNix st) (gsMasterDir st)
      masterNote <- case looked of
        Left err -> pure (masterFailLine now err)
        Right UseRunning -> pure (masterLine now UseRunning)
        Right action -> do
          say (masterLine now action)
          up <- waitForMaster masterWaitStep masterWaitTries (\s -> say ("  master en :3000 aún no contesta (" <> T.pack (show s) <> " s)"))
          failed <- getCurrentTime
          pure $
            if up
              then masterLine now action
              else masterFailLine failed ("no contesta tras " <> T.pack (show (masterWaitStep * masterWaitTries `div` 60)) <> " min")
      say masterNote
      -- El calendario, para la cuenta del token: el fichero del lanzamiento o la instancia.
      asked <- case gsCalendario st of
        Just file -> do
          exists <- doesFileExist file
          if exists then Just <$> calendarFromFile file else pure Nothing
        Nothing -> askCalendar (gsPort st)
      let entries = case asked of
            Just (Calendar es) -> es
            _                  -> []
      okAt <- getCurrentTime
      existing <- listDirectory base
      let planned = gpPlanFor mode (fromIntegral (gsCapSeconds st)) okAt (gsSlots st)
          label d = if gsEnsayo st then "ensayo" else gdLabel d
          folders = foldl (\fs d -> folderFor (label d) existing fs (gdDay d)) (gsFolders st) planned
          days = [(d, folder) | d <- planned, Just folder <- [lookup (gdDay d) folders]]
          journals = zip (map gdDay planned) (checksLogWindows okAt planned)
          path = base </> first
          noteIn = maybe first snd (listToMaybe days)
      mapM_ (say . uncurry returnDayLine) days
      -- Del último día al primero: la última carpeta escrita es la del primero que queda.
      forM_ (reverse days) $ \(d, folder) -> do
        let dayPath = base </> folder
        createDirectoryIfMissing True dayPath
        appendLine (dayPath </> "resumen.txt") (returnLine okAt st)
        when (folder == noteIn) $ appendLine (dayPath </> "resumen.txt") masterNote
        programDay (gsLog st) (tokenNeed entries (gdDay d) (gdSlots d)) (join (lookup (gdDay d) journals)) tools (gsPort st)
          dayPath folder (gdSlots d) okAt (gdPlan d) (gdPlan d)
      when (null days) $ appendLine (path </> "resumen.txt") masterNote
      writeGpState (path </> gpStateFile) st {gsTools = tools, gsFolders = folders}
      programEvery path (masterWatchUnit first) masterWatchLabel relecturaDefault (masterWatchLine okAt relecturaDefault)
      when (mode == Desarrollo) $
        programEvery path (relecturaUnit first) relecturaLabel relecturaDefault (relecturaLine okAt relecturaDefault)

-- | La mirada horaria a @master@ ('masterWatchLabel'), desde la carpeta del primer día:
-- tras el último tope del GP para su temporizador; si no, mira @master@
-- ('lookAfterMaster') y, solo cuando espera, arranca o no puede arrancar, lo apunta en el
-- @resumen.txt@ del día en curso ('folderInCourse').
runMasterWatch :: FilePath -> IO ()
runMasterWatch path = do
  st <- either quit pure =<< readGpState (path </> gpStateFile)
  now <- getCurrentTime
  let cap = fromIntegral (gsCapSeconds st)
      note line = forM_ (folderInCourse now (gsFolders st)) $ \folder ->
        appendLine (takeDirectory path </> folder </> "resumen.txt") line
  when (maybe True (now >=) (gpLastCap cap (gsSlots st))) $ do
    appendLine (path </> "resumen.txt") (quitLine now masterWatchLabel)
    stopTimer (masterWatchUnit (takeFileName path))
    exitSuccess
  looked <- lookAfterMaster (gsNix st) (gsMasterDir st)
  case looked of
    Left err         -> note (masterFailLine now err) >> quit err
    Right UseRunning -> pure ()
    Right action     -> note (masterLine now action)

-- | La relectura de horas de un GP: con las horas de ahora (OpenF1, o el fichero de
-- @--calendario@), cancela y programa lo que diga 'replan', escribe las líneas en las
-- carpetas y guarda las horas nuevas. Tras el último tope del GP para su temporizador.
runRelectura :: FilePath -> IO ()
runRelectura path = do
  st <- either quit pure =<< readGpState (path </> gpStateFile)
  now <- getCurrentTime
  let cap = fromIntegral (gsCapSeconds st)
      base = takeDirectory path
      summaryOf folder = base </> folder </> "resumen.txt"
  when (maybe True (now >=) (gpLastCap cap (gsSlots st))) $ do
    appendLine (path </> "resumen.txt") (quitLine now relecturaLabel)
    stopTimer (relecturaUnit (takeFileName path))
    exitSuccess
  entries <- case gsCalendario st of
    Just file -> do
      answer <- calendarFromFile file
      pure (case answer of
        Calendar es | not (null es) -> Just es
        _                           -> Nothing)
    Nothing -> openf1Calendar
  let moves = slotMoves (gsSlots st) (slotsFromCalendar <$> entries)
  unless (null moves) $ do
    timers <- either (const []) id <$> autoTimers "dashboardF1-auto-*"
    existing <- listDirectory base
    let steps = replan cap now (gsSlots st) moves (pendingKeys (gsFolders st) timers)
        reported = reportedMoves moves steps
        newSlots = applyMoves moves (gsSlots st)
        newDays = gpPlan cap now newSlots
        label d = if gsEnsayo st then "ensayo" else dayLabel d
        wanted = nub ([d | m <- reported, d <- moveDays m] <> [d | Schedule d _ <- steps])
        folders = foldl (\fs d -> folderFor (label d) existing fs d) (gsFolders st) wanted
        folderOf d = fromMaybe (T.unpack (label d)) (lookup d folders)
    forM_ wanted $ \d -> createDirectoryIfMissing True (base </> folderOf d)
    forM_ reported $ \m -> forM_ (moveDays m) $ \d -> appendLine (summaryOf (folderOf d)) (moveLine now m)
    forM_ steps $ \step -> case step of
      Unschedule d p -> do
        stopUnit (unitName (folderOf d) p)
        appendLine (summaryOf (folderOf d)) (quitLine now (pieceLabel p))
      Schedule d p -> do
        let day = find ((== d) . gdDay) newDays
            daySlots = maybe [] gdSlots day
        programDay (gsLog st) (tokenNeed (fromMaybe [] entries) d daySlots) Nothing (gsTools st) (gsPort st)
          (base </> folderOf d) (folderOf d) daySlots now (maybe [p] gdPlan day) [p]
    writeGpState (path </> gpStateFile) st {gsSlots = newSlots, gsFolders = folders}

-- | El calendario de @--calendario@: un @\/api\/calendar@ guardado. Si no existe o no se
-- entiende, lo dice y sale.
readCalendarFile :: FilePath -> IO CalendarAnswer
readCalendarFile file = do
  exists <- doesFileExist file
  unless exists $ quit ("no existe " <> T.pack file <> ": revisa --calendario")
  answer <- calendarFromFile file
  forM_ (calendarFailure answer) $ \why -> quit ("no entiendo " <> T.pack file <> ": " <> why)
  pure answer

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
  manual <- readLines (path </> "vigia-manual.txt")
  observer <- readLines (path </> "observador.txt")
  let states = unitStates units timers
      lines' =
        viewLines (viewHeader shown folder) events states (reconcile (expectedPending events) states)
          (lastOf vigia) (lastOf manual) (lastOf observer)
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

-- | Con el OK, para lo programado y marca cancelado cada GP que volvería ('gpAlive'). Sin
-- nada programado, enseña esos GP ('returningLines') y, con el OK, los marca.
cancela :: IO ()
cancela = do
  units <- either quit pure =<< autoUnits "dashboardF1-auto-*"
  timers <- either quit pure =<< autoTimers "dashboardF1-auto-*"
  base <- mainFolder
  let states = unitStates units timers
      returning at = filter (gpAlive at . snd) <$> gpStates
      mark = mapM_ (\(f, st) -> writeGpState (base </> f </> gpStateFile) st {gsCancelled = True})
  when (null units) $ do
    gps <- returning =<< getCurrentTime
    when (null gps) $ say "No hay nada programado." >> exitSuccess
    mapM_ say (returningLines gps)
    sure <- confirm (returningQuestion gps)
    unless sure $ say "No se cancela nada." >> exitSuccess
    at <- getCurrentTime
    mapM_ (\(f, _) -> appendLine (base </> f </> "resumen.txt") (cancelLine at)) gps
    mark gps
    say "Cancelado."
    exitSuccess
  folders <- sortOn (\f -> (folderDay f, f)) <$> autoFolders
  let pending = foldersWithUnits folders (map urUnit units)
  say (cancelHeader (nub (mapMaybe folderDay pending)))
  mapM_ (\(label, st) -> say ("  " <> T.justifyLeft 34 ' ' label <> st)) states
  ok <- confirm "¿Cancelar? [s/N] "
  unless ok $ say "No se cancela nada." >> exitSuccess
  now <- getCurrentTime
  -- Antes de parar: lo que corre escribe su «para … (cancelado)» al pararse.
  mapM_ (\f -> appendLine (base </> f </> "resumen.txt") (cancelLine now)) pending
  stopUnits "dashboardF1-auto-"
  -- Después de parar: la relectura reescribe @gp.json@ mientras corre.
  mark =<< returning now
  say "Cancelado."

-- | El grabador del store que pone @nix run .#auto@ en @DASHBOARDF1_RECORD@; sin ella, el
-- del @PATH@.
findRecorder :: IO (Maybe FilePath)
findRecorder = lookupEnv "DASHBOARDF1_RECORD" >>= maybe (findExecutable "dashboardF1-record") (pure . Just)

-- | El lector del store que pone @nix run .#auto@ en @DASHBOARDF1_OBSERVA@; sin ella, el
-- del @PATH@.
findReader :: IO (Maybe FilePath)
findReader = lookupEnv "DASHBOARDF1_OBSERVA" >>= maybe (findExecutable "dashboardF1-observa") (pure . Just)

-- | Lo que lanzan las piezas: de las variables que pone @nix run .#auto@ o, sin ellas, del
-- @PATH@. Si falta algo, lo dice (con el lanzador con que hay que lanzar) y sale.
findTools :: Text -> IO Tools
findTools launcher =
  Tools
    <$> found "dashboardF1-record" findRecorder
    <*> found "dashboardF1-observa" findReader
    <*> found "dashboardF1-memoria" (fromEnvOrPath "DASHBOARDF1_MEMORIA" "dashboardF1-memoria")
    <*> found "dashboardF1-vigia-manual" (fromEnvOrPath "DASHBOARDF1_VIGIA_MANUAL" "dashboardF1-vigia-manual")
  where
    found name look = maybe (quit ("no encuentro " <> name <> ": lanza con " <> launcher)) pure =<< look
    fromEnvOrPath var exe = lookupEnv var >>= maybe (findExecutable exe) (pure . Just)

-- | Lo que corre un temporizador al disparar: la pieza de su etiqueta.
dispara :: FilePath -> Text -> [Text] -> IO ()
dispara path label rest
  | label == relecturaLabel = runRelectura path
  | label == masterWatchLabel = runMasterWatch path
  | label == pieceLabel Vigia = either quit (\d -> withSlot d (\s -> runVigia path label s d)) (parseDispara rest)
  | Just piece <- find ((== label) . pieceLabel) [Memory, ManualVigia] =
      either quit
        (\d -> maybe (quit "dispara: la memoria y el vigía manual necesitan --guion") (\s -> runScript path label piece s d) (diScript d))
        (parseDispara rest)
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
