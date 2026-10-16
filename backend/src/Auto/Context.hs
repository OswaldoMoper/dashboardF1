-- | El automatismo del GP — los efectos: preguntar a la instancia, programar y parar
-- en systemd, y leer y escribir la carpeta del día. Las reglas viven en 'Auto.Helper'.
module Auto.Context
  ( instancePorts
  , askCalendar
  , askLive
  , openf1Status
  , runVigia
  , runRecording
  , runChecks
  , jolpicaDay
  , autoUnits
  , autoTimers
  , schedule
  , stopUnits
  , mainFolder
  , autoFolders
  , newestFolder
  , appendLine
  , readLines
  ) where

import           Auto.Helper                (CalendarAnswer, Dispatch (..),
                                             LiveReply (..), PageReply (..),
                                             RecordingEnd (..),
                                             RecordingStep (..), Slot (..),
                                             TimerRow, TokenFile (..), UnitRow,
                                             VigiaEnd (..), VigiaReading (..),
                                             VigiaWatch (..), askOrder,
                                             checkLine, checksSummary,
                                             instanceChange, jolpicaSlots,
                                             liveTable, logVerdict, onCalendar,
                                             openf1Check, pageCheck,
                                             readCalendar, recordingFile,
                                             recordingIdleSeconds, recordingLog,
                                             recordingName, recordingStep,
                                             recordingStopLine, relaunchLine,
                                             slotsOn, startLine, tokenCheck,
                                             tokenFile, vigiaDone,
                                             vigiaJsonName, vigiaLine,
                                             vigiaReading, vigiaStep,
                                             vigiaStopLine)
import           Common.Origin              (fetchedAtHeader, originHeader,
                                             sourceHeader)
import           Config                     (loadConfig)
import           Control.Concurrent         (threadDelay)
import           Control.Exception          (AsyncException (..), SomeException,
                                             handleJust, try)
import           Control.Monad              (forM_, when)
import           Control.Retry              (limitRetries)
import           Data.Aeson                 (FromJSON, eitherDecode)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Lazy       as BL
import           Data.IORef                 (newIORef, readIORef, writeIORef)
import           Data.List                  (isPrefixOf, sortOn)
import           Data.Maybe                 (isNothing)
import           Data.String                (fromString)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Text.Encoding         (decodeUtf8With, encodeUtf8)
import           Data.Text.Encoding.Error   (lenientDecode)
import           Data.Time.Calendar         (Day)
import           Data.Time.Clock            (NominalDiffTime, UTCTime,
                                             addUTCTime, diffUTCTime,
                                             getCurrentTime)
import           Handler.Historical.Manager (fetchSeasonSchedule)
import           Handler.OpenF1.Manager     (latestSession, openf1Base)
import qualified Network.HTTP.Client        as HC
import qualified Network.HTTP.Req           as R
import           Network.HTTP.Types.Header  (ResponseHeaders, hContentType)
import           Network.HTTP.Types.Status  (statusCode)
import           System.Directory           (createDirectoryIfMissing,
                                             doesDirectoryExist, doesFileExist,
                                             getHomeDirectory,
                                             getModificationTime, listDirectory)
import           System.Environment         (getEnvironment)
import           System.Exit                (ExitCode (..))
import           System.FilePath            ((</>))
import           System.IO                  (IOMode (..), openFile)
import           System.Process             (CreateProcess (..), ProcessHandle,
                                             StdStream (..), createProcess,
                                             getProcessExitCode,
                                             interruptProcessGroupOf, proc,
                                             readProcessWithExitCode,
                                             waitForProcess)
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
    timeout 6000000 (try (HC.httpLbs request manager))
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
    timeout (askTimeout + 1000000) (try (HC.withResponse request manager readAnswer))
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
    timeout (askTimeout + 1000000) (try (R.runReq config request))
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

-- | La grabación sin cuenta de esa sesión: lanza @dashboardF1-record@ (ese ejecutable)
-- a @grabacion-\<s\>.txt@ con su salida en @grabacion-\<s\>.log@, y cada minuto mira
-- @\/api\/live@ como el vigía ('recordingStep'). Con el Finalised o el tope le manda
-- SIGINT, como Ctrl+C, y espera a que cierre; si salió solo, lo relanza a @-2@, @-3@…
-- Con SIGINT (lo que manda @cancela@ a toda la unidad) espera al grabador y dice que la
-- cancelaron. Cada paso deja su línea en @resumen.txt@.
runRecording :: FilePath -> Text -> Slot -> FilePath -> Dispatch -> IO ()
runRecording folder label slot recorder d = do
  start <- getCurrentTime
  appendLine summary (startLine start label)
  current <- newIORef =<< launchRecorder 1
  (end, runs) <-
    handleJust cancelled (\e -> pure (e, 0)) (watch start current 1 (Just (diPort d)))
  readIORef current >>= mapM_ (\ph -> do
    alive <- isNothing <$> getProcessExitCode ph
    when (alive && end /= RecCancelled) (interruptProcessGroupOf ph)
    waitForProcess ph)
  stopped <- getCurrentTime
  appendLine summary (recordingStopLine stopped session runs end)
  where
    session = slotName slot
    summary = folder </> "resumen.txt"
    cancelled e = if e == UserInterrupt then Just RecCancelled else Nothing
    launchRecorder n = do
      withoutAccount <- filter ((/= "F1TV") . fst) <$> getEnvironment
      started <-
        try
          ( do
              logHandle <- openFile (folder </> recordingLog session) AppendMode
              (_, _, _, ph) <-
                createProcess
                  (proc recorder [folder </> recordingFile session n, show recordingIdleSeconds])
                    { std_out = UseHandle logHandle
                    , std_err = UseHandle logHandle
                    , create_group = True
                    , env = Just withoutAccount
                    }
              pure ph
          )
          :: IO (Either SomeException ProcessHandle)
      pure (either (const Nothing) Just started)
    watch start current runs answering = do
      waitNextMinute start
      (port, reply, _, at) <- firstAnswer (askOrder instancePorts (diPort d))
      forM_ (instanceChange at (recordingName session) answering port) (appendLine summary)
      alive <- maybe (pure False) (fmap isNothing . getProcessExitCode) =<< readIORef current
      now <- getCurrentTime
      case recordingStep now (diCap d) slot (liveTable =<< reply) alive runs of
        KeepRecording -> watch start current runs port
        Relaunch n -> do
          appendLine summary (relaunchLine now session n)
          writeIORef current =<< launchRecorder n
          watch start current n port
        StopRecording end -> pure (end, runs)

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
-- valer el token hoy (D202, D203): OpenF1, el token de F1TV, la página y el log de la
-- instancia, cada una con su línea en @comprobaciones.txt@; en @resumen.txt@, «arranca»
-- al empezar y «acaba» con la cuenta. __Del token solo sale la caducidad__ ('tokenExpiry').
runChecks :: FilePath -> Text -> UTCTime -> Dispatch -> IO ()
runChecks folder label tokenToday d = do
  start <- getCurrentTime
  appendLine summary (startLine start label)
  results <-
    mapM check
      [ ("OpenF1", openf1Check <$> openf1Status)
      , ("token F1TV", (\now -> tokenCheck now tokenToday (diTokenGp d)) <$> getCurrentTime <*> readTokenFile)
      , ("página", pageCheck asked <$> askPage asked)
      , ("log", logVerdict <$> traverse (\f -> (,) f <$> readIfExists f) (diLog d))
      ]
  done <- getCurrentTime
  appendLine summary (checksSummary done label results)
  where
    summary = folder </> "resumen.txt"
    asked = askOrder instancePorts (diPort d)
    check (what, judge) = do
      (verdict, detail) <- judge
      at <- getCurrentTime
      appendLine (folder </> "comprobaciones.txt") (checkLine at verdict what detail)
      pure (what, verdict)
    readIfExists f = do
      exists <- doesFileExist f
      if exists then Just <$> readLines f else pure Nothing

-- | Lo que hay en @~\/.local\/share\/fastf1\/f1auth.json@, donde FastF1 guarda el token.
readTokenFile :: IO TokenFile
readTokenFile = do
  file <- (</> ".local/share/fastf1/f1auth.json") <$> getHomeDirectory
  exists <- doesFileExist file
  if not exists
    then pure TokenMissing
    else either (const TokenUnreadable) tokenFile
           <$> (try (BS.readFile file) :: IO (Either SomeException BS.ByteString))

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
jolpicaDay day = do
  cfg <- loadConfig
  body <- try (fetchSeasonSchedule cfg) :: IO (Either SomeException BL.ByteString)
  pure $ case slotsOn day <$> (either (Left . show) Right body >>= jolpicaSlots) of
    Right slots@(_ : _) -> Just slots
    _                   -> Nothing

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

-- | @~\/MOPER@, donde viven las carpetas del día.
mainFolder :: IO FilePath
mainFolder = (</> "MOPER") <$> getHomeDirectory

-- | Las carpetas del automatismo que hay en @~\/MOPER@, por nombre.
autoFolders :: IO [FilePath]
autoFolders = do
  base <- mainFolder
  names <- filter ("dashboardF1-auto-" `isPrefixOf`) <$> listDirectory base
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
