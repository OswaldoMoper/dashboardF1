-- | El automatismo del GP — los efectos: preguntar a la instancia, programar y parar
-- en systemd, y leer y escribir la carpeta del día. Las reglas viven en 'Auto.Helper'.
module Auto.Context
  ( instancePorts
  , askCalendar
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

import           Auto.Helper                (CalendarAnswer, Slot, TimerRow,
                                             UnitRow, jolpicaSlots, onCalendar,
                                             readCalendar, slotsOn)
import           Config                     (loadConfig)
import           Control.Exception          (SomeException, try)
import           Data.Aeson                 (FromJSON, eitherDecode)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Lazy       as BL
import           Data.List                  (isPrefixOf, sortOn)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Text.Encoding         (decodeUtf8With, encodeUtf8)
import           Data.Text.Encoding.Error   (lenientDecode)
import           Data.Time.Calendar         (Day)
import           Data.Time.Clock            (UTCTime)
import           Handler.Historical.Manager (fetchSeasonSchedule)
import qualified Network.HTTP.Client        as HC
import           Network.HTTP.Types.Status  (statusCode)
import           System.Directory           (doesDirectoryExist, doesFileExist,
                                             getHomeDirectory,
                                             getModificationTime, listDirectory)
import           System.Exit                (ExitCode (..))
import           System.FilePath            ((</>))
import           System.Process             (readProcessWithExitCode)
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
      Just (readCalendar (statusCode (HC.responseStatus response)) (HC.responseBody response))
    _ -> Nothing

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
-- segundo. Al disparar corre @\<ejecutable\> dispara \<carpeta\> \<descripción\>@ desde ese
-- directorio. La descripción es la que luego enseña la vista.
schedule :: FilePath -> FilePath -> FilePath -> Text -> Text -> Maybe UTCTime -> IO (Either Text ())
schedule exe workDir folder unit label at = do
  (code, _, err) <-
    readProcessWithExitCode
      "systemd-run"
      ( [ "--user"
        , "--unit=" <> T.unpack unit
        , "--description=" <> T.unpack label
        , maybe "--on-active=1s" (("--on-calendar=" <>) . onCalendar) at
        , "--timer-property=AccuracySec=1s"
        , "--working-directory=" <> workDir
        , "--"
        , exe
        , "dispara"
        , folder
        , T.unpack label
        ]
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
