-- | El automatismo del GP — los efectos: preguntar a la instancia, programar y parar
-- en systemd, y leer y escribir la carpeta del día. Las reglas viven en 'Auto.Helper'.
module Auto.Context
  ( instancePorts
  , askCalendar
  , askLive
  , openf1Status
  , runVigia
  , runObserver
  , runScript
  , runRecording
  , runChecks
  , jolpicaDay
  , jolpicaSeason
  , calendarFromFile
  , autoUnits
  , autoTimers
  , schedule
  , scheduleEvery
  , stopUnit
  , stopTimer
  , unitState
  , lookAfterMaster
  , waitForMaster
  , journalToFile
  , openf1Slots
  , readGpState
  , writeGpState
  , stopUnits
  , mainFolder
  , autoFolders
  , newestFolder
  , appendLine
  , readLines
  ) where

import           App                        (ScheduledSession)
import           Auto.Helper                (Account, CalendarAnswer,
                                             Dispatch (..), GpState,
                                             LiveReply (..), MasterAction (..),
                                             ObserverEnd (..),
                                             ObserverEvent (..), PageReply (..),
                                             Piece (..), ReaderAnswer (..),
                                             RecordingEnd (..),
                                             RecordingRun (..),
                                             RecordingStep (..),
                                             RelaunchWhy (..), ScriptEnd (..),
                                             Slot (..), TimerRow, UnitRow (..),
                                             VigiaEnd (..), VigiaReading (..),
                                             VigiaWatch (..), askOrder,
                                             captureDue, captureName, checkLine,
                                             checksStopLine, checksSummary,
                                             inPause, instanceChange,
                                             jolpicaSlots, journalArgs,
                                             liveTable, logVerdict,
                                             manualVigiaDelay, masterAction,
                                             masterLogName, masterResetArgs,
                                             masterRunArgs, masterUnit,
                                             masterUnitRunning, observerLine,
                                             observerStopLine, onCalendar,
                                             openf1Check, pageCheck, pageUrl,
                                             pauseFrom, pauseLine, readCalendar,
                                             readerAnswer, readerRelaunchLine,
                                             readerTimeoutSeconds, recorderArgs,
                                             recordingFile, recordingLog,
                                             recordingName, recordingStep,
                                             recordingStepLine,
                                             recordingStopLine, reopenLine,
                                             scriptArgs, scriptLog, scriptStep,
                                             scriptStopLine, slotsFromCalendar,
                                             slotsOn, startLine, tokenCheck,
                                             unitName, vigiaDone, vigiaGone,
                                             vigiaJsonName, vigiaLine,
                                             vigiaReading, vigiaStep,
                                             vigiaStopLine)
import           Common.Origin              (fetchedAtHeader, originHeader,
                                             sourceHeader)
import           Config                     (loadConfig)
import           Control.Concurrent         (threadDelay)
import           Control.Exception          (AsyncException (..), SomeException,
                                             handleJust)
import           Control.Monad              (forM_, join, unless, void, when)
import           Control.Retry              (limitRetries)
import           Data.Aeson                 (FromJSON, eitherDecode, encode)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Char8      as BS8
import qualified Data.ByteString.Lazy       as BL
import           Data.IORef                 (newIORef, readIORef, writeIORef)
import           Data.List                  (isPrefixOf, sortOn)
import           Data.Map.Strict            (Map)
import           Data.Maybe                 (fromMaybe, isJust, isNothing)
import           Data.String                (fromString)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Text.Encoding         (decodeUtf8With, encodeUtf8)
import           Data.Text.Encoding.Error   (lenientDecode)
import qualified Data.Text.IO               as TIO
import           Data.Time.Calendar         (Day)
import           Data.Time.Clock            (NominalDiffTime, UTCTime,
                                             addUTCTime, diffUTCTime,
                                             getCurrentTime)
import           Handler.FastF1.Manager     (readTokenFile)
import           Handler.Historical.Manager (fetchSeasonSchedule)
import           Handler.Live.Context       (fetchSchedule)
import           Handler.Live.Helper        (calendarEntries)
import           Handler.OpenF1.Manager     (latestSession, openf1Base)
import qualified Network.HTTP.Client        as HC
import qualified Network.HTTP.Req           as R
import           Network.HTTP.Types.Header  (ResponseHeaders, hContentType)
import           Network.HTTP.Types.Status  (statusCode)
import           Sync                       (trySync)
import           System.Directory           (createDirectoryIfMissing,
                                             doesDirectoryExist, doesFileExist,
                                             getFileSize, getHomeDirectory,
                                             getModificationTime, listDirectory,
                                             makeAbsolute)
import           System.Environment         (getEnvironment, lookupEnv)
import           System.Exit                (ExitCode (..))
import           System.FilePath            (takeFileName, (</>))
import           System.IO                  (BufferMode (..), Handle,
                                             IOMode (..), hClose, hFlush,
                                             hSetBuffering, hSetEncoding,
                                             openFile, utf8)
import           System.Posix.Signals       (sigKILL, signalProcess)
import           System.Process             (CreateProcess (..), ProcessHandle,
                                             StdStream (..), createProcess,
                                             getPid, getProcessExitCode,
                                             interruptProcessGroupOf, proc,
                                             readProcessWithExitCode,
                                             terminateProcess, waitForProcess)
import           System.Timeout             (timeout)

-- | Donde puede correr la instancia: @master@ y el clon del plan del GP.
instancePorts :: [Int]
instancePorts = [3000, 3001]

-- | @GET \/api\/calendar@ de la instancia de ese puerto. 'Nothing' si no contesta en
-- 6 s: un puerto sin nadie no rechaza, se agota el tiempo.
askCalendar :: Int -> IO (Maybe CalendarAnswer)
askCalendar port = do
  manager <-
    HC.newManager
      HC.defaultManagerSettings {HC.managerResponseTimeout = HC.responseTimeoutMicro 5000000}
  request <- HC.parseRequest ("http://127.0.0.1:" <> show port <> "/api/calendar")
  answer <-
    timeout 6000000 (trySync (HC.httpLbs request manager))
      :: IO (Maybe (Either SomeException (HC.Response BL.ByteString)))
  pure $ case answer of
    Just (Right response) ->
      Just
        ( readCalendar
            (statusCode (HC.responseStatus response))
            (decodeUtf8With lenientDecode <$> lookup hContentType (HC.responseHeaders response))
            (HC.responseBody response)
        )
    _ -> Nothing

-- | Lo que espera el vigía a cada instancia y a OpenF1: 15 s, para que preguntar a las
-- dos y a OpenF1 quepa en su minuto.
askTimeout :: Int
askTimeout = 15000000

-- | Lo que contestó una instancia a un @GET@: el código, las cabeceras y el cuerpo.
data Answer = Answer
  { anCode    :: Int
  , anHeaders :: ResponseHeaders
  , anBody    :: BL.ByteString
  }

-- | La cabecera de ese nombre, en texto.
answerHeader :: Answer -> Text -> Maybe Text
answerHeader a name = decodeUtf8With lenientDecode <$> lookup (fromString (T.unpack name)) (anHeaders a)

-- | @GET@ de esa ruta en la instancia de ese puerto; el cuerpo, solo si se pide (el de
-- @all.js@ pesa unos 24 MB). 'Nothing' si no contesta en 'askTimeout'.
askPath :: Bool -> Int -> String -> IO (Maybe Answer)
askPath withBody port path = do
  manager <-
    HC.newManager
      HC.defaultManagerSettings {HC.managerResponseTimeout = HC.responseTimeoutMicro askTimeout}
  request <- HC.parseRequest ("http://127.0.0.1:" <> show port <> path)
  answer <-
    timeout (askTimeout + 1000000) (trySync (HC.withResponse request manager readAnswer))
      :: IO (Maybe (Either SomeException Answer))
  pure $ case answer of
    Just (Right a) -> Just a
    _              -> Nothing
  where
    readAnswer response = do
      body <- if withBody then BL.fromChunks <$> HC.brConsume (HC.responseBody response) else pure BL.empty
      pure (Answer (statusCode (HC.responseStatus response)) (HC.responseHeaders response) body)

-- | @GET \/api\/live@ de la instancia de ese puerto. 'Nothing' si no contesta 200 en
-- 'askTimeout'.
askLive :: Int -> IO (Maybe LiveReply)
askLive port = do
  answer <- askPath True port "/api/live"
  pure $ case answer of
    Just a | anCode a == 200 ->
      Just
        LiveReply
          { lrOrigin = answerHeader a originHeader
          , lrSource = answerHeader a sourceHeader
          , lrFetched = answerHeader a fetchedAtHeader
          , lrBody = anBody a
          }
    _ -> Nothing

-- | El código de @sessions?session_key=latest@ de OpenF1, sin reintentos; 'Nothing' si
-- no contesta en 'askTimeout'. Un 401 o un 429 es un código, no un fallo.
openf1Status :: IO (Maybe Int)
openf1Status = do
  answer <-
    timeout (askTimeout + 1000000) (trySync (R.runReq config request))
      :: IO (Maybe (Either SomeException Int))
  pure $ case answer of
    Just (Right code) -> Just code
    _                 -> Nothing
  where
    request =
      R.responseStatusCode
        <$> R.req R.GET (openf1Base R./: "sessions") R.NoReqBody R.ignoreResponse
              (latestSession <> R.responseTimeout askTimeout)
    config =
      R.defaultHttpConfig
        { R.httpConfigCheckResponse = \_ _ _ -> Nothing
        , R.httpConfigRetryPolicy = limitRetries 0
        }

-- | Cada cuánto escribe el vigía.
vigiaPeriod :: NominalDiffTime
vigiaPeriod = 60

-- | El vigía, en la carpeta del día, con la última sesión del día: cada 'vigiaPeriod'
-- pregunta a @\/api\/live@ (la instancia del lanzamiento y, si no contesta, la otra) y a
-- OpenF1, añade su línea a @vigia.txt@ y guarda el cuerpo en @vigia\/@. Para con
-- 'vigiaDone', con su tope o con SIGINT (lo que manda @cancela@), y cada parada y cada
-- cambio de instancia dejan su línea en @resumen.txt@.
runVigia :: FilePath -> Text -> Slot -> Dispatch -> IO ()
runVigia folder label lastSlot d = do
  start <- getCurrentTime
  appendLine summary (startLine start label)
  createDirectoryIfMissing True (folder </> "vigia")
  end <- handleJust cancelled pure (watch start Watching (Just (diPort d)))
  stopped <- getCurrentTime
  appendLine summary (vigiaStopLine stopped end)
  where
    summary = folder </> "resumen.txt"
    cancelled e = if e == UserInterrupt then Just VigiaCancelled else Nothing
    watch start seen answering = do
      now <- getCurrentTime
      if maybe False (now >=) (diCap d)
        then pure VigiaCapped
        else do
          (port, reply, seconds, at) <- firstAnswer (askOrder instancePorts (diPort d))
          code <- openf1Status
          let reading = vigiaReading at seconds reply code
              seen' = vigiaStep at lastSlot (vrTable reading) code seen
          forM_ (instanceChange at "vigía" answering port) (appendLine summary)
          appendLine (folder </> "vigia.txt") (vigiaLine reading)
          forM_ reply $ \r -> BL.writeFile (folder </> "vigia" </> vigiaJsonName at) (lrBody r)
          if vigiaDone seen'
            then pure VigiaQuiet
            else waitNextMinute start >> watch start seen' port

-- | Duerme hasta el siguiente múltiplo de 'vigiaPeriod' contado desde ese arranque, para
-- que un minuto lento no corra los demás.
waitNextMinute :: UTCTime -> IO ()
waitNextMinute start = do
  now <- getCurrentTime
  let ticks = floor (diffUTCTime now start / vigiaPeriod) + 1 :: Integer
      next = addUTCTime (fromInteger ticks * vigiaPeriod) start
  threadDelay (ceiling (realToFrac (diffUTCTime next now) * 1000000 :: Double))

-- | La grabación de esa sesión con esa cuenta: lanza @dashboardF1-record@ (ese ejecutable,
-- sin la variable @F1TV@ y con @--f1tv@ solo con cuenta; 'recorderArgs') a su fichero
-- ('recordingFile') con su salida en su @.log@, y cada minuto mira
-- @\/api\/live@ como el vigía y su fichero ('recordingStep'). Con el Finalised o el tope le
-- manda SIGINT, como Ctrl+C, y espera a que cierre; si salió solo o su fichero dejó de
-- crecer, lo para y lo relanza a @-2@, @-3@… (la vez que no conectó, en el mismo número).
-- Con SIGINT (lo que manda @cancela@ a toda la unidad) espera al grabador y dice que la
-- cancelaron. Cada paso deja su línea en @resumen.txt@.
runRecording :: FilePath -> Text -> Account -> Slot -> FilePath -> Dispatch -> IO ()
runRecording folder label account slot recorder d = do
  start <- getCurrentTime
  appendLine summary (startLine start label)
  current <- newIORef =<< launchRecorder 1
  (end, runs) <-
    handleJust cancelled (\e -> pure (e, 0))
      (watch start current (launched 1 0 start) (Just (diPort d)))
  readIORef current >>= mapM_ (\ph -> do
    alive <- isNothing <$> getProcessExitCode ph
    when alive (stopRecorder (end /= RecCancelled) ph))
  stopped <- getCurrentTime
  appendLine summary (recordingStopLine stopped account session runs end)
  where
    session = slotName slot
    summary = folder </> "resumen.txt"
    cancelled e = if e == UserInterrupt then Just RecCancelled else Nothing
    launchRecorder n = do
      withoutAccount <- filter ((/= "F1TV") . fst) <$> getEnvironment
      started <-
        trySync
          ( do
              logHandle <- openFile (folder </> recordingLog account session) AppendMode
              (_, _, _, ph) <-
                createProcess
                  (proc recorder (recorderArgs account (folder </> recordingFile account session n)))
                    { std_out = UseHandle logHandle
                    , std_err = UseHandle logHandle
                    , create_group = True
                    , env = Just withoutAccount
                    }
              pure ph
          )
          :: IO (Either SomeException ProcessHandle)
      pure (either (const Nothing) Just started)
    watch start current run answering = do
      waitNextMinute start
      (port, reply, _, at) <- firstAnswer (askOrder instancePorts (diPort d))
      forM_ (instanceChange at (recordingName account session) answering port) (appendLine summary)
      alive <- maybe (pure False) (fmap isNothing . getProcessExitCode) =<< readIORef current
      file <- fileState (folder </> recordingFile account session (rrRuns run))
      now <- getCurrentTime
      let seen = run {rrAlive = alive, rrFile = file}
          step = recordingStep now (diCap d) slot (liveTable =<< reply) seen
      forM_ (recordingStepLine now account session seen step) (appendLine summary)
      case step of
        KeepRecording -> watch start current seen port
        Connected -> watch start current seen {rrRetries = 0} port
        Relaunch n why -> do
          when alive (readIORef current >>= mapM_ (stopRecorder True))
          writeIORef current =<< launchRecorder n
          relaunched <- getCurrentTime
          let retries = if why == Unconnected then rrRetries seen + 1 else 0
          watch start current (launched n retries relaunched) port
        StopRecording end -> pure (end, rrRuns seen)
    launched n retries at =
      RecordingRun {rrAlive = True, rrRuns = n, rrRetries = retries, rrLaunched = at, rrFile = Nothing}

-- | Para al grabador: SIGINT a su grupo, como Ctrl+C (sin él si ya se lo mandó
-- @cancela@), y si en 30 s no ha salido, SIGTERM.
stopRecorder :: Bool -> ProcessHandle -> IO ()
stopRecorder interrupt ph = do
  when interrupt (interruptProcessGroupOf ph)
  gone <- timeout 30000000 (waitForProcess ph)
  when (isNothing gone) $ do
    terminateProcess ph
    _ <- timeout 10000000 (waitForProcess ph)
    pure ()

-- | El tamaño y la última escritura de un fichero; 'Nothing' si no se puede leer.
fileState :: FilePath -> IO (Maybe (Integer, UTCTime))
fileState path = either (const Nothing) Just <$> trySync ((,) <$> getFileSize path <*> getModificationTime path)

-- | El lector vivo: su entrada, su salida y su proceso.
data Reader = Reader Handle Handle ProcessHandle

-- | Si el servicio del vigía de esa carpeta del día corre (o está arrancando); 'Nothing'
-- si no se pudo preguntar a systemd.
vigiaRunning :: FilePath -> IO (Maybe Bool)
vigiaRunning folder =
  either (const Nothing) (Just . any ((`elem` ["active", "activating"]) . urActive))
    <$> autoUnits (unitName (takeFileName folder) Vigia <> ".service")

-- | La memoria o el vigía manual, en la carpeta del día: lanza su guion (ese ejecutable,
-- con 'scriptArgs') en su propio grupo y con la salida en su @.log@ —el vigía manual,
-- 'manualVigiaDelay' después de arrancar— y cada 'vigiaPeriod' mira si para
-- ('scriptStep'). Lo para como al grabador ('stopRecorder'); con SIGINT (lo que manda
-- @cancela@ a toda la unidad) espera a que salga. La parada deja su línea en @resumen.txt@.
runScript :: FilePath -> Text -> Piece -> FilePath -> Dispatch -> IO ()
runScript folder label piece script d = do
  start <- getCurrentTime
  appendLine summary (startLine start label)
  current <- newIORef Nothing
  end <-
    handleJust cancelled pure $ do
      when (piece == ManualVigia) $
        threadDelay (ceiling (realToFrac manualVigiaDelay * 1000000 :: Double))
      writeIORef current =<< launchScript
      watch start current (0 :: Int)
  readIORef current >>= mapM_ (\ph -> do
    alive <- isNothing <$> getProcessExitCode ph
    when alive (stopRecorder (end /= ScriptCancelled) ph))
  stopped <- getCurrentTime
  appendLine summary (scriptStopLine stopped label end)
  where
    summary = folder </> "resumen.txt"
    cancelled e = if e == UserInterrupt then Just ScriptCancelled else Nothing
    -- 'Nothing' si no arrancó: en su primer minuto, 'scriptStep' lo da por salido.
    launchScript = do
      started <-
        trySync
          ( do
              logHandle <- openFile (folder </> scriptLog piece) AppendMode
              (_, _, _, ph) <-
                createProcess
                  (proc script (scriptArgs piece (diPort d) folder))
                    { std_out = UseHandle logHandle
                    , std_err = UseHandle logHandle
                    , create_group = True
                    }
              pure ph
          )
          :: IO (Either SomeException ProcessHandle)
      pure (either (const Nothing) Just started)
    watch start current n = do
      waitNextMinute start
      now <- getCurrentTime
      alive <- vigiaRunning folder
      running <- maybe (pure False) (fmap isNothing . getProcessExitCode) =<< readIORef current
      case scriptStep piece now (diCap d) (n + 1) alive running of
        Just e  -> pure e
        Nothing -> watch start current (n + 1)

-- | El observador, en la carpeta del día: lanza el lector (ese
-- ejecutable) y cada 'vigiaPeriod' abre la página en la primera instancia que la sirve,
-- o la lee y, cuando toca ('captureDue'), la captura. Escribe su línea en
-- @observador.txt@ y cada lectura tal cual en @observador\/@. __En la pausa de la foto
-- del reloj cierra la página y no pregunta nada a la instancia.__ Un lector que no
-- contesta en 'readerTimeoutSeconds' se relanza. Para cuando el vigía ya no corre
-- ('vigiaGone'), con su tope o con SIGINT (lo que manda @cancela@).
runObserver :: FilePath -> Text -> FilePath -> Dispatch -> IO ()
runObserver folder label readerExe d = do
  start <- getCurrentTime
  appendLine summary (startLine start label)
  mapM_ (createDirectoryIfMissing True . (folder </>)) ["observador", "capturas"]
  reader <- newIORef =<< startReader
  end <- handleJust cancelled pure (watch start reader 0 Nothing (Just (diPort d)) False)
  readIORef reader >>= stopReader
  stopped <- getCurrentTime
  appendLine summary (observerStopLine stopped end)
  where
    summary = folder </> "resumen.txt"
    note t e = appendLine (folder </> "observador.txt") (observerLine t e)
    cancelled e = if e == UserInterrupt then Just ObserverCancelled else Nothing
    window = pauseFrom <$> diPause d
    vigiaAlive = vigiaRunning folder

    startReader = do
      logHandle <- openFile (folder </> "observador.log") AppendMode
      (hin, hout, _, ph) <-
        createProcess
          (proc readerExe [])
            { std_in = CreatePipe
            , std_out = CreatePipe
            , std_err = UseHandle logHandle
            , create_group = True
            }
      case (hin, hout) of
        (Just i, Just o) -> do
          hSetEncoding i utf8
          hSetBuffering i LineBuffering
          pure (Reader i o ph)
        _ -> ioError (userError "el lector arrancó sin entrada o sin salida")

    -- Una orden y su línea de respuesta; 'Nothing' si el lector no contestó a tiempo, y
    -- entonces queda relanzado y sin página.
    ask reader order = do
      Reader i o _ <- readIORef reader
      answer <-
        timeout (readerTimeoutSeconds * 1000000) (trySync (TIO.hPutStrLn i order >> hFlush i >> BS8.hGetLine o))
          :: IO (Maybe (Either SomeException BS.ByteString))
      case answer of
        Just (Right line) -> pure (Just line)
        _ -> do
          now <- getCurrentTime
          note now ReaderHung
          appendLine summary (readerRelaunchLine now)
          readIORef reader >>= stopReader
          writeIORef reader =<< startReader
          pure Nothing

    watch start reader n page answering paused = do
      now <- getCurrentTime
      alive <- vigiaAlive
      if maybe False (now >=) (diCap d)
        then pure ObserverCapped
        else
          if vigiaGone n alive
            then pure ObserverVigiaGone
            else do
              (page', answering', paused') <-
                if inPause now window
                  then pausing now reader page answering paused
                  else looking now reader n page answering paused
              waitNextMinute start
              watch start reader (n + 1) page' answering' paused'

    -- Al entrar en la pausa, una sola línea, haya página o no; después, nada.
    pausing now reader page answering paused = do
      unless paused $
        forM_ (snd <$> window) $ \reopen ->
          if isJust page
            then do
              _ <- ask reader "cierra"
              note now (PageClosed reopen)
              appendLine summary (pauseLine now reopen)
            else note now (PausedWithoutPage reopen)
      pure (Nothing, answering, True)

    looking now reader n page answering paused = do
      port <- firstServing (askOrder instancePorts (diPort d))
      forM_ (instanceChange now "observador" answering port) (appendLine summary)
      case port of
        Nothing -> note now NoInstance >> pure (page, port, paused)
        Just p
          | page /= Just p -> do
              reply <- ask reader ("abre " <> pageUrl p)
              case readerAnswer <$> reply of
                Nothing -> pure (Nothing, port, paused)
                Just (Just a) | raOk a -> do
                  note now (PageOpened p (raMs a))
                  when paused (appendLine summary (reopenLine now p))
                  pure (Just p, port, False)
                Just a -> do
                  note now (PageNotOpened p (failure a))
                  pure (Nothing, port, paused)
          | otherwise -> do
              reply <- ask reader "lee"
              case (reply, readerAnswer =<< reply) of
                (Nothing, _) -> pure (Nothing, port, paused)
                (Just raw, Just a) | raOk a, Just r <- raReading a -> do
                  BS.writeFile (folder </> "observador" </> vigiaJsonName now) raw
                  shot <- if captureDue n then capture now reader else pure (Just Nothing)
                  note now (PageRead r (join shot))
                  pure (if isNothing shot then Nothing else page, port, paused)
                (Just _, a) -> do
                  -- Una lectura que falla vuelve a abrir la página al minuto siguiente.
                  note now (PageNotRead (failure a))
                  pure (Nothing, port, paused)

    failure = maybe "respuesta que no se entiende" (fromMaybe "sin error" . raError)

    -- La captura del minuto: su nombre si salió; 'Nothing' dentro si no; 'Nothing' fuera
    -- si el lector se colgó.
    capture now reader = do
      let name = captureName now
      reply <- ask reader ("captura " <> T.pack (folder </> "capturas" </> name))
      pure $ case reply of
        Nothing -> Nothing
        Just raw -> Just (if maybe False raOk (readerAnswer raw) then Just name else Nothing)

-- | Cierra la entrada del lector, que entonces cierra el navegador y sale; si en 10 s
-- no ha salido, SIGINT a su grupo; si en otros 10 s sigue vivo, SIGKILL (el navegador
-- cae con él) y otros 10 s para que salga.
stopReader :: Reader -> IO ()
stopReader (Reader i _ ph) = do
  _ <- trySync (hClose i)
  gone <- timeout 10000000 (waitForProcess ph)
  when (isNothing gone) $ do
    interruptProcessGroupOf ph
    gone' <- timeout 10000000 (waitForProcess ph)
    when (isNothing gone') $ do
      getPid ph >>= mapM_ (signalProcess sigKILL)
      _ <- timeout 10000000 (waitForProcess ph)
      pure ()

-- | La primera instancia que sirve la página (@GET \/@ en 200), por orden. No pregunta
-- a @\/api\/live@.
firstServing :: [Int] -> IO (Maybe Int)
firstServing [] = pure Nothing
firstServing (p : rest) = do
  answer <- askPath False p "/"
  if fmap anCode answer == Just 200 then pure (Just p) else firstServing rest

-- | La primera instancia que contesta, por orden: su puerto, la respuesta, lo que tardó
-- ella y cuándo llegó. Sin ninguna, lo que se esperó en total.
firstAnswer :: [Int] -> IO (Maybe Int, Maybe LiveReply, Double, UTCTime)
firstAnswer ports = getCurrentTime >>= go ports
  where
    go [] begun = do
      now <- getCurrentTime
      pure (Nothing, Nothing, realToFrac (diffUTCTime now begun), now)
    go (p : rest) begun = do
      asked <- getCurrentTime
      reply <- askLive p
      now <- getCurrentTime
      case reply of
        Just r  -> pure (Just p, Just r, realToFrac (diffUTCTime now asked), now)
        Nothing -> go rest begun

-- | Una tanda de comprobaciones en la carpeta del día, con la hora hasta la que tiene que
-- valer el token hoy: OpenF1, el token de F1TV, la página y el log de la
-- instancia, cada una con su línea en @comprobaciones.txt@; en @resumen.txt@, «arranca»
-- al empezar y «acaba» con la cuenta, o, con SIGINT (lo que manda @cancela@), su línea de
-- parada. __Del token solo sale la caducidad__ ('tokenExpiry').
runChecks :: FilePath -> Text -> UTCTime -> Dispatch -> IO ()
runChecks folder label tokenToday d = do
  start <- getCurrentTime
  appendLine summary (startLine start label)
  results <-
    handleJust cancelled (const (pure Nothing)) . fmap Just $
      mapM check
        [ ("OpenF1", openf1Check <$> openf1Status)
        , ("token F1TV", (\now -> tokenCheck now tokenToday (diTokenGp d)) <$> getCurrentTime <*> readTokenFile)
        , ("página", pageCheck asked <$> askPage asked)
        , ("log", logVerdict <$> logSource)
        ]
  done <- getCurrentTime
  appendLine summary (maybe (checksStopLine done label) (checksSummary done label) results)
  where
    summary = folder </> "resumen.txt"
    cancelled e = if e == UserInterrupt then Just () else Nothing
    asked = askOrder instancePorts (diPort d)
    check (what, judge) = do
      (verdict, detail) <- judge
      at <- getCurrentTime
      appendLine (folder </> "comprobaciones.txt") (checkLine at verdict what detail)
      pure (what, verdict)
    readIfExists f = do
      exists <- doesFileExist f
      if exists then Just <$> readLines f else pure Nothing
    -- El log que se juzga: si la unidad de master está en marcha y la orden trae el tramo
    -- del día, el diario volcado a master.log en la carpeta; si no, el de --log.
    logSource = do
      running <- maybe (pure False) (const (masterUnitRunning <$> unitState masterUnit)) (diJournal d)
      case (running, diJournal d) of
        (True, Just window) -> do
          let file = folder </> masterLogName
          journalToFile window file
          Just . (,) file <$> readIfExists file
        _ -> traverse (\f -> (,) f <$> readIfExists f) (diLog d)

-- | La página en la primera instancia que contesta @/@, por ese orden: @/@, @/all.js@
-- (sin leer el cuerpo) y @\/api\/live@. 'Nothing' si no contesta ninguna.
askPage :: [Int] -> IO (Maybe PageReply)
askPage [] = pure Nothing
askPage (port : rest) = do
  index <- askPath True port "/"
  case index of
    Nothing -> askPage rest
    Just i -> do
      script <- askPath False port "/all.js"
      live <- askPath True port "/api/live"
      pure $
        Just
          PageReply
            { pgPort = port
            , pgIndex = anCode i
            , pgIndexType = answerHeader i "Content-Type"
            , pgScript = anCode <$> script
            , pgLive = (\a -> (anCode a, anBody a)) <$> live
            }

-- | Las sesiones de ese día según Jolpica. 'Nothing' si no contesta, no se entiende o no
-- trae ninguna ese día.
jolpicaDay :: Day -> IO (Maybe [Slot])
jolpicaDay day = (nonEmpty . slotsOn day =<<) <$> jolpicaSeason

-- | Las sesiones de la temporada según Jolpica. 'Nothing' si no contesta, no se entiende o
-- no trae ninguna.
jolpicaSeason :: IO (Maybe [Slot])
jolpicaSeason = do
  cfg <- loadConfig
  body <- trySync (fetchSeasonSchedule cfg) :: IO (Either SomeException BL.ByteString)
  pure (either (const Nothing) nonEmpty (either (Left . show) Right body >>= jolpicaSlots))

nonEmpty :: [a] -> Maybe [a]
nonEmpty xs = if null xs then Nothing else Just xs

-- | Un @\/api\/calendar@ guardado en ese fichero, leído como el de la instancia
-- ('readCalendar'). El fichero tiene que existir.
calendarFromFile :: FilePath -> IO CalendarAnswer
calendarFromFile file = readCalendar 200 Nothing <$> BL.readFile file

-- | Las unidades cuyo nombre casa con el patrón, también las que fallaron.
autoUnits :: Text -> IO (Either Text [UnitRow])
autoUnits pattern = systemctlJson ["list-units", T.unpack pattern, "--all"]

autoTimers :: Text -> IO (Either Text [TimerRow])
autoTimers pattern = systemctlJson ["list-timers", T.unpack pattern, "--all"]

systemctlJson :: FromJSON a => [String] -> IO (Either Text a)
systemctlJson args = do
  (code, out, err) <-
    readProcessWithExitCode "systemctl" (["--user", "--no-pager", "-o", "json"] <> args) ""
  pure $ case code of
    ExitSuccess -> either (Left . T.pack) Right (eitherDecode (BL.fromStrict (encodeUtf8 (T.pack out))))
    _           -> Left (T.strip (T.pack err))

-- | Programa una pieza con @systemd-run --user@: a esa hora (UTC) o, con 'Nothing', al
-- segundo. Al disparar corre @\<ejecutable\> dispara \<carpeta\> \<descripción\> \<args\>@
-- desde ese directorio. La descripción es la que luego enseña la vista. Parar la unidad
-- le manda SIGINT, como Ctrl+C, para que la pieza diga que la cancelaron.
schedule :: FilePath -> FilePath -> FilePath -> Text -> Text -> [Text] -> Maybe UTCTime -> IO (Either Text ())
schedule exe workDir folder unit label args at = do
  (code, _, err) <-
    readProcessWithExitCode
      "systemd-run"
      ( [ "--user"
        , "--unit=" <> T.unpack unit
        , "--description=" <> T.unpack label
        , maybe "--on-active=1s" (("--on-calendar=" <>) . onCalendar) at
        , "--timer-property=AccuracySec=1s"
        , "--property=KillSignal=SIGINT"
        , "--working-directory=" <> workDir
        , "--"
        , exe
        , "dispara"
        , folder
        , T.unpack label
        ]
          <> map T.unpack args
      )
      ""
  pure $ case code of
    ExitSuccess -> Right ()
    _           -> Left (T.strip (T.pack err))

-- | Como 'schedule', pero se repite: la primera vez tras ese intervalo y después cada
-- ese intervalo desde que arrancó la anterior.
scheduleEvery :: FilePath -> FilePath -> FilePath -> Text -> Text -> [Text] -> NominalDiffTime -> IO (Either Text ())
scheduleEvery exe workDir folder unit label args every = do
  let seconds = show (max 1 (round every :: Integer)) <> "s"
  (code, _, err) <-
    readProcessWithExitCode
      "systemd-run"
      ( [ "--user"
        , "--unit=" <> T.unpack unit
        , "--description=" <> T.unpack label
        , "--on-active=" <> seconds
        , "--on-unit-active=" <> seconds
        , "--timer-property=AccuracySec=1s"
        , "--property=KillSignal=SIGINT"
        , "--working-directory=" <> workDir
        , "--"
        , exe
        , "dispara"
        , folder
        , T.unpack label
        ]
          <> map T.unpack args
      )
      ""
  pure $ case code of
    ExitSuccess -> Right ()
    _           -> Left (T.strip (T.pack err))

-- | Para el temporizador y el servicio de esa unidad, y nada más: el nombre exacto, no un
-- patrón (el de @…-grabacion-q@ casaría con @…-grabacion-q-cuenta@).
stopUnit :: Text -> IO ()
stopUnit unit =
  mapM_
    (\args -> readProcessWithExitCode "systemctl" ("--user" : args) "")
    [ ["stop", T.unpack unit <> ".timer"]
    , ["stop", T.unpack unit <> ".service"]
    , ["reset-failed", T.unpack unit <> ".timer", T.unpack unit <> ".service"]
    ]

-- | Para solo el temporizador de esa unidad: lo que corre su servicio acaba por sí mismo.
stopTimer :: Text -> IO ()
stopTimer unit = void (readProcessWithExitCode "systemctl" ["--user", "stop", T.unpack unit <> ".timer"] "")

-- | El @ActiveState@ de esa unidad de @systemd --user@ («inactive» si no existe);
-- 'Nothing' si systemctl no contesta.
unitState :: Text -> IO (Maybe Text)
unitState unit = do
  (code, out, _) <-
    readProcessWithExitCode "systemctl" ["--user", "show", T.unpack unit, "-p", "ActiveState", "--value"] ""
  pure $ case code of
    ExitSuccess -> Just (T.strip (T.pack out))
    _           -> Nothing

-- | Mira @master@ y hace lo que toque ('masterAction'): si nadie contesta en @:3000@ y su
-- unidad no corre, la arranca con @systemd-run@ ('masterRunArgs', con ese @nix@ y desde esa
-- carpeta), aunque la unidad hubiera acabado en fallo. 'Left' si el arranque falla. No
-- espera a que conteste: eso es 'waitForMaster'.
lookAfterMaster :: FilePath -> FilePath -> IO (Either Text MasterAction)
lookAfterMaster nix dir = do
  answers <- isJust <$> askCalendar 3000
  state <- unitState masterUnit
  case masterAction answers state of
    StartMaster -> do
      void (readProcessWithExitCode "systemctl" masterResetArgs "")
      (code, _, err) <- readProcessWithExitCode "systemd-run" (masterRunArgs nix dir) ""
      pure $ case code of
        ExitSuccess -> Right StartMaster
        _           -> Left (T.strip (T.pack err))
    action -> pure (Right action)

-- | Espera a que alguien conteste en @:3000@: cada 'masterWaitStep' segundos pregunta, hasta
-- tantas veces, y tras cada vez sin respuesta llama a eso con los segundos que lleva.
-- 'False' si se agotan.
waitForMaster :: Int -> Int -> (Int -> IO ()) -> IO Bool
waitForMaster step tries report = go 1
  where
    go n
      | n > tries = pure False
      | otherwise = do
          threadDelay (step * 1000000)
          answers <- isJust <$> askCalendar 3000
          if answers
            then pure True
            else report (n * step) >> go (n + 1)

-- | Ese tramo del diario de 'masterUnit' ('journalArgs'), tal cual, a ese fichero, que se
-- sustituye.
journalToFile :: (UTCTime, UTCTime) -> FilePath -> IO ()
journalToFile window file = do
  out <- openFile file WriteMode
  (_, _, _, ph) <- createProcess (proc "journalctl" (journalArgs window)) {std_out = UseHandle out}
  void (waitForProcess ph)
  hClose out

-- | Las sesiones que OpenF1 da ahora (las que no han terminado), como las sirve @master@.
-- 'Nothing' si no contesta (un 401, por ejemplo) o no trae ninguna.
openf1Slots :: IO (Maybe [Slot])
openf1Slots = do
  cfg <- loadConfig
  now <- getCurrentTime
  result <- trySync (fetchSchedule cfg now) :: IO (Either SomeException ([ScheduledSession], Map Int Text))
  pure (either (const Nothing) (nonEmpty . slotsFromCalendar . calendarEntries . fst) result)

-- | El 'GpState' de ese fichero; 'Left' con el motivo si no existe o no se entiende.
readGpState :: FilePath -> IO (Either Text GpState)
readGpState file = do
  exists <- doesFileExist file
  if not exists
    then pure (Left ("no existe " <> T.pack file))
    else either (Left . T.pack) Right . eitherDecode <$> BL.readFile file

writeGpState :: FilePath -> GpState -> IO ()
writeGpState file = BL.writeFile file . encode

-- | Para todo lo que casa con el prefijo y limpia lo que había fallado. Primero los
-- temporizadores y después los servicios: al revés, parar un servicio descarga su
-- temporizador y el @stop@ de este sale con error aunque todo quede parado.
stopUnits :: Text -> IO ()
stopUnits prefix =
  mapM_
    (\args -> readProcessWithExitCode "systemctl" ("--user" : args) "")
    [ ["stop", T.unpack prefix <> "*.timer"]
    , ["stop", T.unpack prefix <> "*.service"]
    , ["reset-failed", T.unpack prefix <> "*"]
    ]

-- | Donde viven las carpetas del día: @DASHBOARDF1_CARPETA@ si está puesta y no vacía
-- (relativa al directorio actual), y si no @~\/MOPER@. Siempre absoluta; no comprueba
-- que exista.
mainFolder :: IO FilePath
mainFolder = do
  chosen <- lookupEnv "DASHBOARDF1_CARPETA"
  case chosen of
    Just dir | not (null dir) -> makeAbsolute dir
    _                         -> (</> "MOPER") <$> getHomeDirectory

-- | Las carpetas del automatismo que hay en 'mainFolder', por nombre; ninguna si
-- 'mainFolder' no existe.
autoFolders :: IO [FilePath]
autoFolders = do
  base <- mainFolder
  exists <- doesDirectoryExist base
  names <-
    if exists
      then filter ("dashboardF1-auto-" `isPrefixOf`) <$> listDirectory base
      else pure []
  map snd . filter fst <$> mapM (\n -> (\d -> (d, n)) <$> doesDirectoryExist (base </> n)) names

-- | La carpeta en la que se escribió lo último (por su @resumen.txt@).
newestFolder :: IO (Maybe FilePath)
newestFolder = do
  base <- mainFolder
  folders <- autoFolders
  stamped <- mapM (\n -> (\t -> (t, n)) <$> stampOf (base </> n)) folders
  pure $ case reverse (sortOn fst stamped) of
    (_, n) : _ -> Just n
    []         -> Nothing
  where
    stampOf dir = do
      let summary = dir </> "resumen.txt"
      exists <- doesFileExist summary
      getModificationTime (if exists then summary else dir)

-- | Añade una línea a un fichero, en UTF-8 sea cual sea la configuración regional.
appendLine :: FilePath -> Text -> IO ()
appendLine file line = BS.appendFile file (encodeUtf8 (line <> "\n"))

-- | Las líneas de un fichero; ninguna si no existe.
readLines :: FilePath -> IO [Text]
readLines file = do
  exists <- doesFileExist file
  if exists
    then T.lines . decodeUtf8With lenientDecode <$> BS.readFile file
    else pure []
