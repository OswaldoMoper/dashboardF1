-- | El automatismo del GP — lógica pura.
--
-- Las reglas con las que @dashboardF1-auto@ programa un día de GP y juzga lo que ve:
-- qué sesiones hay ese día, cuándo arranca y cuándo para cada pieza, y qué dice cada
-- línea de los ficheros de la carpeta del día. Sin efectos.
module Auto.Helper
  ( -- * Las horas
    mexicoZone
  , mexicoDay
  , clockPair
  , resolveDay
  , Slot (..)
  , slotsFromCalendar
  , slotsOn
    -- * Lo que se programa
  , Piece (..)
  , Planned (..)
  , recordingLead
  , capAfterStart
  , dayPlan
  , clockPhotoWindow
  , pauseFrom
    -- * Cuándo para cada pieza
  , pastCap
  , sessionFinalised
  , VigiaWatch (..)
  , openf1QuietMinutes
  , vigiaStep
  , vigiaDone
  , inPause
  , captureDue
  , vigiaGone
    -- * Lo que se juzga
  , Verdict (..)
  , verdictWord
  , openf1Verdict
  , LogCount (..)
  , sinceLastStart
  , countLog
  , logCheck
    -- * Las comprobaciones de una tanda
  , openf1Check
  , TokenFile (..)
  , tokenExpiry
  , tokenFile
  , tokenNeed
  , tokenCheck
  , isHtml
  , PageReply (..)
  , pageCheck
  , logVerdict
  , checksSummary
  , checksStopLine
    -- * Las líneas de los ficheros
  , checkLine
  , eventLine
  , VigiaReading (..)
  , LiveReply (..)
  , liveTable
  , vigiaReading
  , vigiaLine
  , vigiaWords
  , vigiaJsonName
  , startLine
  , VigiaEnd (..)
  , vigiaStopLine
  , readerTimeoutSeconds
  , pageUrl
  , captureName
  , PageReading (..)
  , ReaderAnswer (..)
  , readerAnswer
  , ObserverEvent (..)
  , observerLine
  , bandWords
  , pauseLine
  , reopenLine
  , readerRelaunchLine
  , ObserverEnd (..)
  , observerStopLine
  , recordingIdleSeconds
  , recordingStallAfter
  , maxRelaunches
  , recordingFile
  , recordingLog
  , RecordingEnd (..)
  , RecordingRun (..)
  , RelaunchWhy (..)
  , RecordingStep (..)
  , recordingStep
  , recordingStopLine
  , recordingStepLine
  , recordingName
  , dayFolder
    -- * Lo que recibe cada pieza al disparar
  , Dispatch (..)
  , dispatchFor
  , withChecks
  , watchedSlot
  , dispatchArgs
  , parseDispara
  , askOrder
  , instanceChange
    -- * Los nombres
  , sessionShort
  , sessionLabel
  , pieceLabel
  , unitName
  , nextFolder
  , folderDay
    -- * Lo que pide quien lo lanza
  , Launch (..)
  , parseLaunch
  , parseHoras
  , jolpicaSlots
  , CalendarAnswer (..)
  , readCalendar
  , calendarFailure
  , instanceName
  , instanceAt
    -- * Lo que enseña el comando
  , dayHeader
  , dayTable
  , slotsSummary
  , horasFlag
  , onCalendar
  , programLine
  , lateOkLines
  , cancelLine
    -- * Lo que dice systemd
  , UnitRow (..)
  , TimerRow (..)
  , unitStates
  , expectedPending
  , reconcile
  , cancelHeader
  , viewHeader
  , viewLines
  ) where

import           Common.Types               (LapProgress (..), LiveTable (..),
                                             SessionInfo (..),
                                             SessionState (..),
                                             StateReading (..),
                                             sessionStateLabel)
import           Config                     (startupMark)
import           Data.Aeson                 (FromJSON (..), Object, Value,
                                             eitherDecode, eitherDecodeStrict,
                                             withObject, (.:), (.:?))
import           Data.Aeson.Types           (Parser, parseEither)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Base64.URL as B64U
import qualified Data.ByteString.Char8      as BS8
import qualified Data.ByteString.Lazy       as BL
import           Data.Char                  (isDigit)
import           Data.List                  (find, nub, sortOn, (\\))
import           Data.Maybe                 (catMaybes, fromMaybe, isNothing,
                                             listToMaybe, mapMaybe)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Time.Calendar         (Day, DayOfWeek (..), addDays,
                                             dayOfWeek, showGregorian,
                                             toGregorian)
import           Data.Time.Clock            (NominalDiffTime, UTCTime,
                                             addUTCTime, diffUTCTime)
import           Data.Time.Clock.POSIX      (posixSecondsToUTCTime)
import           Data.Time.Format           (defaultTimeLocale, formatTime,
                                             parseTimeM)
import           Data.Time.LocalTime        (LocalTime (..), TimeZone, localDay,
                                             localTimeToUTC, minutesToTimeZone,
                                             utcToLocalTime, utcToZonedTime)
import           Handler.Live.Helper        (CalendarEntry (..))
import           Text.Printf                (printf)

-- | La hora de México, fija en UTC−6: sin horario de verano desde 2022, y sin
-- depender de la zona del proceso, que bajo systemd es la del sistema (UTC).
mexicoZone :: TimeZone
mexicoZone = minutesToTimeZone (-360)

-- | El día de México en que cae un instante.
mexicoDay :: UTCTime -> Day
mexicoDay = localDay . utcToLocalTime mexicoZone

-- | El día que pide el comando, con su nombre para la carpeta (sin acentos).
--
-- Sin nada es hoy; con un día de la semana, __el próximo, hoy incluido__. Acepta
-- mayúsculas y acentos. 'Left' lleva el mensaje para quien lo lanzó.
resolveDay :: Day -> Maybe Text -> Either Text (Text, Day)
resolveDay today Nothing = Right (weekdayName (dayOfWeek today), today)
resolveDay today (Just word) =
  case lookup (fold word) [(weekdayName d, d) | d <- [Monday .. Sunday]] of
    Nothing -> Left ("no conozco el día «" <> word <> "»: lunes … domingo, o nada para hoy")
    Just wanted ->
      let ahead = (fromEnum wanted - fromEnum (dayOfWeek today)) `mod` 7
       in Right (weekdayName wanted, addDays (toInteger ahead) today)
  where
    fold = T.map unaccent . T.toLower . T.strip
    unaccent c = fromMaybe c (lookup c (zip "áéíóú" "aeiou"))

weekdayName :: DayOfWeek -> Text
weekdayName d = case d of
  Monday    -> "lunes"
  Tuesday   -> "martes"
  Wednesday -> "miercoles"
  Thursday  -> "jueves"
  Friday    -> "viernes"
  Saturday  -> "sabado"
  Sunday    -> "domingo"

-- | Una sesión que programar: lo único que hace falta de ella. El nombre es el que
-- da el feed (@\"Practice 1\"@), que es por el que se reconoce su @Finalised@.
data Slot = Slot
  { slotName  :: Text
  , slotStart :: UTCTime
  }
  deriving (Eq, Show)

slotsFromCalendar :: [CalendarEntry] -> [Slot]
slotsFromCalendar = map (\e -> Slot (ceName e) (ceStart e))

-- | Las sesiones que empiezan ese día de México, por hora.
slotsOn :: Day -> [Slot] -> [Slot]
slotsOn day = sortOn slotStart . filter ((== day) . mexicoDay . slotStart)

data Piece
  = Checks (Maybe Text)  -- ^ Una tanda de comprobaciones: al lanzar, o antes de esa sesión.
  | Vigia
  | Observer (Maybe UTCTime)  -- ^ El observador, con el inicio de su pausa ('clockPhotoWindow').
  | Recording Text    -- ^ La grabación sin cuenta de esa sesión.
  deriving (Eq, Show)

-- | Una pieza con su hora de arranque y su tope.
data Planned = Planned
  { plPiece :: Piece
  , plStart :: UTCTime
  , plCap   :: Maybe UTCTime  -- ^ 'Nothing' para lo que no se queda corriendo.
  }
  deriving (Eq, Show)

-- | Cuánto antes de la sesión arranca su grabación (T−45, como lo manual).
recordingLead :: NominalDiffTime
recordingLead = 45 * 60

-- | El tope de seguridad, desde el inicio previsto de la sesión.
capAfterStart :: NominalDiffTime
capAfterStart = 6 * 3600

-- | Lo que se programa para esas sesiones, lanzado en ese instante, con ese tope.
--
-- Comprobaciones, vigía y observador al lanzar; por sesión, a T−45, la grabación y otra
-- tanda de comprobaciones. __Lo que ya debía haber arrancado arranca al lanzar__, y
-- entonces su tanda de T−45 sobra (la de lanzar la cubre). Una sesión cuyo tope ya pasó
-- no se programa. Sin sesiones, nada: ni el vigía.
dayPlan :: NominalDiffTime -> UTCTime -> [Slot] -> [Planned]
dayPlan cap now slots =
  case live of
    [] -> []
    _ ->
      sortOn plStart $
        Planned (Checks Nothing) now Nothing
          : Planned Vigia now (Just (capOf (last live)))
          : Planned (Observer (fst <$> clockPhotoWindow slots)) now (Just (capOf (last live)))
          : concatMap perSlot live
  where
    live = filter ((> now) . capOf) (sortOn slotStart slots)
    capOf s = addUTCTime cap (slotStart s)
    perSlot s =
      let lead = addUTCTime (negate recordingLead) (slotStart s)
       in Planned (Recording (slotName s)) (max now lead) (Just (capOf s))
            : [Planned (Checks (Just (slotName s))) lead Nothing | lead > now]

-- | Cuánto después del inicio previsto de la P1 empieza la foto del reloj, y cuánto dura:
-- de 11:30 a 12:00–12:15, la ventana en que la pestaña se cierra a mano (D213).
clockPhotoAfter, clockPhotoLength :: NominalDiffTime
clockPhotoAfter = 30 * 60
clockPhotoLength = 15 * 60

-- | La ventana en que el observador no mira: la foto del reloj de la P1 de esas
-- sesiones, contada desde su hora prevista. Sin P1, ninguna.
clockPhotoWindow :: [Slot] -> Maybe (UTCTime, UTCTime)
clockPhotoWindow slots = pauseFrom . addUTCTime clockPhotoAfter . slotStart <$> find ((== "Practice 1") . slotName) slots

-- | La ventana que empieza en ese instante.
pauseFrom :: UTCTime -> (UTCTime, UTCTime)
pauseFrom start = (start, addUTCTime clockPhotoLength start)

-- | Si ese instante cae en la ventana: desde su inicio y antes de su fin.
inPause :: UTCTime -> Maybe (UTCTime, UTCTime) -> Bool
inPause now = maybe False (\(from, to) -> from <= now && now < to)

pastCap :: UTCTime -> Planned -> Bool
pastCap now = maybe False (now >=) . plCap

-- | Si @\/api\/live@ da esa sesión por finalizada en ese instante. Cuenta igual el estado
-- oído que el deducido del calendario, como el @estado=@ del vigía manual. __Antes de su
-- hora prevista no cuenta__: hasta entonces @\/api\/live@ puede enseñar otra sesión acabada
-- que se llame igual.
sessionFinalised :: UTCTime -> Slot -> Maybe LiveTable -> Bool
sessionFinalised now slot table =
  case liveSession =<< table of
    Just si ->
      now >= slotStart slot
        && siName si == slotName slot
        && fmap srState (siState si) == Just SessionFinalised
    Nothing -> False

-- | Lo que el vigía lleva visto para saber cuándo parar.
data VigiaWatch
  = Watching       -- ^ La última sesión del día aún no ha acabado.
  | QuietFor Int   -- ^ Ya acabó, y OpenF1 lleva esos minutos seguidos en 200.
  deriving (Eq, Show)

openf1QuietMinutes :: Int
openf1QuietMinutes = 5

-- | Un minuto más del vigía: el instante, la última sesión del día, la respuesta de
-- @\/api\/live@ y el código de OpenF1 ('Nothing' si no contestó). Los minutos en 200
-- cuentan __después__ del de @Finalised@, y uno que no sea 200 los vuelve a cero.
vigiaStep :: UTCTime -> Slot -> Maybe LiveTable -> Maybe Int -> VigiaWatch -> VigiaWatch
vigiaStep now lastSlot table _ Watching
  | sessionFinalised now lastSlot table = QuietFor 0
  | otherwise                           = Watching
vigiaStep _ _ _ code (QuietFor n)
  | code == Just 200 = QuietFor (n + 1)
  | otherwise        = QuietFor 0

vigiaDone :: VigiaWatch -> Bool
vigiaDone (QuietFor n) = n >= openf1QuietMinutes
vigiaDone Watching     = False

data Verdict = Ok | Aviso | Falla
  deriving (Eq, Show)

verdictWord :: Verdict -> Text
verdictWord v = case v of
  Ok    -> "OK"
  Aviso -> "AVISO"
  Falla -> "FALLA"

-- | 401 es OpenF1 cerrado y 429 su límite de ritmo: esperables en un GP, AVISO.
openf1Verdict :: Maybe Int -> Verdict
openf1Verdict code = case code of
  Just 200 -> Ok
  Just 401 -> Aviso
  Just 429 -> Aviso
  _        -> Falla

-- | Las líneas del log de la instancia que dicen «error», por clase.
data LogCount = LogCount
  { lcErrors      :: Int  -- ^ Las que cuentan como error.
  , lcRateLimited :: Int  -- ^ Los 429 de OpenF1, cuyo cuerpo dice @"error"@.
  , lcBrokenPipe  :: Int  -- ^ Los cortes del feed (@Broken pipe@, @SSLError@).
  }
  deriving (Eq, Show)

-- | Las líneas del log de la instancia que corre: las que siguen a su última línea
-- de arranque (startupMark). Sin ninguna, el log entero.
sinceLastStart :: [Text] -> [Text]
sinceLastStart = reverse . takeWhile (not . (T.pack startupMark `T.isInfixOf`)) . reverse

-- | Sin distinguir mayúsculas. Un corte del feed ocupa tres líneas y cuenta tres.
countLog :: [Text] -> LogCount
countLog = foldr (tally . T.toLower) (LogCount 0 0 0)
  where
    tally l c
      | not ("error" `T.isInfixOf` l)                      = c
      | "[openf1]" `T.isInfixOf` l && " 429 " `T.isInfixOf` l = c {lcRateLimited = lcRateLimited c + 1}
      | "broken pipe" `T.isInfixOf` l || "ssl" `T.isInfixOf` l = c {lcBrokenPipe = lcBrokenPipe c + 1}
      | otherwise                                          = c {lcErrors = lcErrors c + 1}

-- | El juicio del log y su detalle: un error es FALLA; solo 429 o cortes, AVISO.
logCheck :: LogCount -> (Verdict, Text)
logCheck c = (verdict, T.pack (printf "%d con «error», %d de OpenF1 429, %d de Broken pipe/SSL" (lcErrors c) (lcRateLimited c) (lcBrokenPipe c)))
  where
    verdict
      | lcErrors c > 0                          = Falla
      | lcRateLimited c > 0 || lcBrokenPipe c > 0 = Aviso
      | otherwise                               = Ok

-- | OpenF1 con su código, o «sin respuesta» (D202).
openf1Check :: Maybe Int -> (Verdict, Text)
openf1Check code = (openf1Verdict code, maybe "sin respuesta" (T.pack . show) code)

-- | Lo que hay en @f1auth.json@, el fichero en que FastF1 guarda el token de F1TV.
data TokenFile
  = TokenMissing
  | TokenUnreadable          -- ^ Vacío (FastF1 lo crea así) o algo que no es un token.
  | TokenExpires UTCTime
  deriving (Eq, Show)

-- | La caducidad (@exp@) del token, un JWT en texto. __Solo devuelve la hora__: el resto
-- del token lleva datos del suscriptor y no sale de aquí.
tokenExpiry :: BS.ByteString -> Maybe UTCTime
tokenExpiry raw = case BS8.split '.' (BS8.strip raw) of
  [_, payload, _] -> do
    claims <- either (const Nothing) Just (B64U.decodeUnpadded payload)
    secs <- either (const Nothing) Just (eitherDecodeStrict claims >>= parseEither (withObject "token" (.: "exp")))
    pure (posixSecondsToUTCTime (fromInteger secs))
  _ -> Nothing

tokenFile :: BS.ByteString -> TokenFile
tokenFile = maybe TokenUnreadable TokenExpires . tokenExpiry

-- | Hasta cuándo tiene que valer el token, con todo el calendario, ese día y sus sesiones:
-- el fin de la última sesión de hoy y el de la última de su gran premio (el de hoy si no se
-- sabe cuál es): las del mismo nombre y del mismo año de México. Sin calendario de ese día,
-- el inicio de la última sesión y 'Nothing'. 'Nothing' del todo si no hay sesiones.
tokenNeed :: [CalendarEntry] -> Day -> [Slot] -> Maybe (UTCTime, Maybe UTCTime)
tokenNeed entries day slots = case todays of
  [] -> (\s -> (maximum s, Nothing)) <$> nonEmpty (map slotStart slots)
  _ ->
    let todayEnd = maximum (map ceEnd todays)
        gp = find (not . T.null) (map ceGrandPrix todays)
        sameGp g e = ceGrandPrix e == g && yearOf (mexicoDay (ceStart e)) == yearOf day
        gpEnd = maybe todayEnd (\g -> maximum (todayEnd : [ceEnd e | e <- entries, sameGp g e])) gp
     in Just (todayEnd, Just gpEnd)
  where
    todays = filter ((== day) . mexicoDay . ceStart) entries
    nonEmpty xs = if null xs then Nothing else Just xs
    yearOf d = let (y, _, _) = toGregorian d in y

-- | El juicio del token en ese instante, con lo que tiene que cubrir ('tokenNeed': hoy y,
-- con calendario, el gran premio) y lo que hay en el fichero (D202, D203).
tokenCheck :: UTCTime -> UTCTime -> Maybe UTCTime -> TokenFile -> (Verdict, Text)
tokenCheck now today gp file = case file of
  TokenMissing    -> (Falla, "no hay token (no existe ~/.local/share/fastf1/f1auth.json)")
  TokenUnreadable -> (Falla, "no hay token (no se entiende f1auth.json)")
  TokenExpires e
    | e <= now -> (Falla, "caducó el " <> dated e)
    | e < today -> withoutCalendar (Falla, "caduca a las " <> clockPair "%H:%M" e <> ", antes del fin de hoy")
    | maybe False (e <) gp -> (Aviso, "vale hoy; caduca el " <> dated e <> ", antes del fin del GP")
    | otherwise -> withoutCalendar (Ok, "vale hasta " <> dated e)
  where
    dated t =
      T.take 3 (weekdayName (dayOfWeek (mexicoDay t))) <> " "
        <> T.pack (formatTime defaultTimeLocale "%-d" (utcToLocalTime mexicoZone t)) <> " "
        <> clockPair "%H:%M" t
    withoutCalendar (v, detail) = case gp of
      Nothing -> (v, detail <> "; sin calendario: comparado con el inicio de la última sesión de hoy")
      Just _  -> (v, detail)

-- | Si un @Content-Type@ es el de una página HTML.
isHtml :: Maybe Text -> Bool
isHtml = maybe False (("text/html" `T.isPrefixOf`) . T.toLower)

-- | Lo que contestó a la página la primera instancia que contestó @/@: su puerto, el código
-- y el tipo de @/@, el código de @/all.js@ y el código y el cuerpo de @\/api\/live@
-- ('Nothing': no contestó).
data PageReply = PageReply
  { pgPort      :: Int
  , pgIndex     :: Int
  , pgIndexType :: Maybe Text
  , pgScript    :: Maybe Int
  , pgLive      :: Maybe (Int, BL.ByteString)
  }

-- | El juicio de la página, con las instancias por el orden en que se preguntó (la del
-- lanzamiento primero) y lo que contestó la primera que contestó (D202, D203). Si contestó
-- otra, AVISO; cualquier petición que no dé lo esperado, FALLA.
pageCheck :: [Int] -> Maybe PageReply -> (Verdict, Text)
pageCheck asked Nothing = (Falla, "no contesta " <> T.intercalate " ni " (map instanceAt asked))
pageCheck asked (Just r) = (verdict, prefix <> T.intercalate " · " [indexPart, scriptPart, livePart])
  where
    home = listToMaybe asked
    moved = home /= Just (pgPort r)
    prefix
      | moved = instanceAt (pgPort r) <> "; " <> maybe "" instanceName home <> " no contesta · "
      | otherwise = ""
    indexOk = pgIndex r == 200 && isHtml (pgIndexType r)
    indexPart = "/ " <> code (pgIndex r) <> (if pgIndex r == 200 && not indexOk then " sin HTML" else "")
    scriptPart = "all.js " <> maybe "sin respuesta" code (pgScript r)
    (liveOk, livePart) = case pgLive r of
      Nothing -> (False, "/api/live sin respuesta")
      Just (200, body) -> case eitherDecode body of
        Right t -> (True, "/api/live 200 (" <> maybe "sin sesión" siName (liveSession t) <> ")")
        Left _  -> (False, "/api/live 200 sin entender")
      Just (c, _) -> (False, "/api/live " <> code c)
    verdict
      | not (indexOk && pgScript r == Just 200 && liveOk) = Falla
      | moved = Aviso
      | otherwise = Ok
    code = T.pack . show

-- | El juicio del log de la instancia: sin @--log@ ('Nothing'), AVISO; si el fichero no
-- existe (sus líneas, 'Nothing'), FALLA; si existe, sus líneas desde el último arranque.
logVerdict :: Maybe (FilePath, Maybe [Text]) -> (Verdict, Text)
logVerdict given = case given of
  Nothing                -> (Aviso, "sin --log: no se mira")
  Just (path, Nothing)   -> (Falla, "no existe " <> T.pack path)
  Just (_, Just content) -> logCheck (countLog (sinceLastStart content))

-- | La línea «acaba» de una tanda en @resumen.txt@ (D202, D203): cuántas salieron con cada
-- palabra y, entre paréntesis, cuáles no salieron OK.
checksSummary :: UTCTime -> Text -> [(Text, Verdict)] -> Text
checksSummary t label results = eventLine t "acaba" (label <> ": " <> T.intercalate ", " counts)
  where
    counts =
      [ T.pack (show (length names)) <> " " <> verdictWord v <> listed v names
      | v <- [Ok, Aviso, Falla]
      , let names = [what | (what, w) <- results, w == v]
      , not (null names)
      ]
    listed Ok _    = ""
    listed _ names = " (" <> T.intercalate ", " names <> ")"

-- | La línea de @resumen.txt@ de una tanda que cancelaron a mitad (D204): «para
-- comprobaciones de arranque (canceladas)».
checksStopLine :: UTCTime -> Text -> Text
checksStopLine t label = eventLine t "para" (label <> " (canceladas)")

-- | La hora de México y, entre paréntesis, la UTC.
clockPair :: String -> UTCTime -> Text
clockPair fmt t =
  T.pack (formatTime defaultTimeLocale fmt (utcToZonedTime mexicoZone t))
    <> " (" <> T.pack (formatTime defaultTimeLocale fmt t) <> ")"

-- | La hora de México, sin la UTC.
mexicoHour :: UTCTime -> Text
mexicoHour = T.pack . formatTime defaultTimeLocale "%H:%M" . utcToZonedTime mexicoZone

-- | Una línea de @comprobaciones.txt@: hora, palabra, qué y el detalle.
checkLine :: UTCTime -> Verdict -> Text -> Text -> Text
checkLine t v what detail =
  T.unwords [clockPair "%H:%M:%S" t, T.justifyLeft 6 ' ' (verdictWord v), T.justifyLeft 11 ' ' what, detail]

-- | Una línea de @resumen.txt@: hora al minuto, el verbo y de qué.
eventLine :: UTCTime -> Text -> Text -> Text
eventLine t verb what = T.unwords [clockPair "%H:%M" t, T.justifyLeft 8 ' ' verb, what]

-- | Lo que el vigía leyó en un minuto. Las tres cabeceras son las de 'Common.Origin'.
data VigiaReading = VigiaReading
  { vrAt      :: UTCTime
  , vrOrigin  :: Maybe Text
  , vrSource  :: Maybe Text
  , vrFetched :: Maybe Text
  , vrTable   :: Maybe LiveTable  -- ^ 'Nothing' si @\/api\/live@ no contestó.
  , vrSeconds :: Double           -- ^ Lo que tardó @\/api\/live@.
  , vrOpenF1  :: Maybe Int
  }

-- | La línea de @vigia.txt@, con la forma de la del vigía manual (hora UTC) para que
-- las dos se puedan comparar línea a línea.
vigiaLine :: VigiaReading -> Text
vigiaLine r =
  T.pack (formatTime defaultTimeLocale "%H:%M:%S" (vrAt r))
    <> " live=" <> dash (vrOrigin r) <> "/" <> dash (vrSource r)
    <> " fetched=" <> dash (vrFetched r)
    <> " sesion=" <> dash (siName <$> session)
    <> " estado=" <> dash (sessionStateLabel . srState <$> (siState =<< session))
    <> " vuelta=" <> dash (T.pack . show . lpCurrent <$> (siLaps =<< session))
    <> " filas=" <> T.pack (show (maybe 0 (length . liveRows) (vrTable r)))
    <> " t=" <> T.pack (printf "%.6f" (vrSeconds r)) <> "s"
    <> " openf1=" <> maybe "000" (T.pack . show) (vrOpenF1 r)
  where
    session = liveSession =<< vrTable r
    dash = fromMaybe "-"

-- | Lo que contestó una instancia a @\/api\/live@: las tres cabeceras de 'Common.Origin'
-- y el cuerpo tal cual, que es lo que se guarda en @vigia\/@.
data LiveReply = LiveReply
  { lrOrigin  :: Maybe Text
  , lrSource  :: Maybe Text
  , lrFetched :: Maybe Text
  , lrBody    :: BL.ByteString
  }

-- | Lo leído en un minuto: cuándo llegó @\/api\/live@, lo que tardó, lo que contestó
-- ('Nothing' si ninguna instancia) y el código de OpenF1. Un cuerpo que no se entiende
-- cuenta como contestado y sin tabla.
vigiaReading :: UTCTime -> Double -> Maybe LiveReply -> Maybe Int -> VigiaReading
vigiaReading at seconds reply code =
  VigiaReading
    { vrAt = at
    , vrOrigin = lrOrigin =<< reply
    , vrSource = lrSource =<< reply
    , vrFetched = lrFetched =<< reply
    , vrTable = liveTable =<< reply
    , vrSeconds = seconds
    , vrOpenF1 = code
    }

-- | La tabla de una respuesta; 'Nothing' si el cuerpo no se entiende.
liveTable :: LiveReply -> Maybe LiveTable
liveTable = either (const Nothing) Just . eitherDecode . lrBody

-- | El fichero de @vigia\/@ de ese minuto, con la hora UTC como el manual: @160500.json@.
vigiaJsonName :: UTCTime -> FilePath
vigiaJsonName = formatTime defaultTimeLocale "%H%M%S.json"

-- | La línea de @vigia.txt@ en palabras, para la vista (D196): las dos horas y, por
-- orden, sesión, estado, vuelta, filas, fuente, OpenF1 y lo que tardó; lo que falta,
-- «sin …» (D201). Sin instancia (@live=-\/-@), solo eso y OpenF1. Una línea que no tiene
-- la forma de 'vigiaLine' sale tal cual.
vigiaWords :: Text -> Text
vigiaWords line = fromMaybe ("vigía " <> line) $ do
  [live, _, sesion, estado, vuelta, filas, secs, openf1] <- vigiaFields rest
  clock' <- mexicoClock clock
  seconds <- case reads (T.unpack (T.dropWhileEnd (== 's') secs)) of
    [(s, "")] -> Just (s :: Double)
    _         -> Nothing
  let (origin, source) = T.breakOn "/" live
      openf1Words = "OpenF1 " <> (if openf1 == "000" then "sin respuesta" else openf1)
      body
        | live == "-/-" = ["no contesta ninguna instancia", openf1Words]
        | otherwise =
            [ orNone "sesión" sesion
            , orNone "estado" estado
            , if vuelta == "-" then "sin vuelta" else "vuelta " <> vuelta
            , filas <> if filas == "1" then " fila" else " filas"
            , orNone "fuente" (T.drop 1 source) <> (if origin == "-" then "" else " (" <> origin <> ")")
            , openf1Words
            , T.replace "." "," (T.pack (printf "%.1f" seconds)) <> " s"
            ]
  pure ("vigía " <> clock' <> ": " <> T.intercalate " · " body)
  where
    (clock, rest) = T.breakOn " live=" line
    orNone what v = if v == "-" || T.null v then "sin " <> what else v

-- | Los valores de una línea de 'vigiaLine', en su orden; 'Nothing' si no tiene esa forma.
vigiaFields :: Text -> Maybe [Text]
vigiaFields = go ["live", "fetched", "sesion", "estado", "vuelta", "filas", "t", "openf1"]
  where
    go [] r = if T.null r then Just [] else Nothing
    go (k : ks) r = do
      r1 <- T.stripPrefix (" " <> k <> "=") r
      let (v, r2) = case ks of
            []    -> (r1, "")
            n : _ -> T.breakOn (" " <> n <> "=") r1
      (v :) <$> go ks r2

-- | @HH:MM:SS@ en UTC como «HH:MM (HH:MM)», México primero.
mexicoClock :: Text -> Maybe Text
mexicoClock clock = case T.splitOn ":" clock of
  [h, m, _] | [(hh, "")] <- reads (T.unpack h), [(mm, "")] <- reads (T.unpack m), hh < 24, mm < (60 :: Int) ->
    let utc = hh * 60 + mm
        mx = (utc + 24 * 60 - 6 * 60) `mod` (24 * 60)
        hhmm x = T.pack (printf "%02d:%02d" (x `div` 60) (x `mod` 60))
     in Just (hhmm mx <> " (" <> hhmm utc <> ")")
  _ -> Nothing

-- | La línea de @resumen.txt@ de una pieza que arranca de verdad: su etiqueta, tal cual,
-- que es por donde 'expectedPending' la da por arrancada.
startLine :: UTCTime -> Text -> Text
startLine t label = eventLine t "arranca" label

-- | Por qué para el vigía.
data VigiaEnd = VigiaQuiet | VigiaCapped | VigiaCancelled
  deriving (Eq, Show)

vigiaStopLine :: UTCTime -> VigiaEnd -> Text
vigiaStopLine t end = eventLine t "para" ("vigía (" <> why <> ")")
  where
    why = case end of
      VigiaQuiet     -> "OpenF1 en 200 cinco min"
      VigiaCapped    -> "tope"
      VigiaCancelled -> "cancelado"

-- | Cada cuántos minutos del observador va una captura (cada 5, decidido en la 99).
captureEvery :: Int
captureEvery = 5

-- | Si en ese minuto del observador (el primero es el 0) toca captura.
captureDue :: Int -> Bool
captureDue n = n `mod` captureEvery == 0

-- | Si el observador para porque el vigía ya no corre: desde su segundo minuto (en el
-- primero los dos acaban de arrancar), y solo si systemd dijo que no ('Nothing' es que
-- no se pudo preguntar).
vigiaGone :: Int -> Maybe Bool -> Bool
vigiaGone n alive = n >= 1 && alive == Just False

-- | Lo que espera el observador a que el lector conteste una orden antes de darlo por
-- colgado y relanzarlo.
readerTimeoutSeconds :: Int
readerTimeoutSeconds = 30

-- | La página que abre el observador en esa instancia, sin diferido (decidido en la 99).
pageUrl :: Int -> Text
pageUrl port = "http://127.0.0.1:" <> T.pack (show port) <> "/?retraso=0"

-- | La captura de ese minuto, con la hora UTC como los @.json@: @223300.png@.
captureName :: UTCTime -> FilePath
captureName = formatTime defaultTimeLocale "%H%M%S.png"

-- | De lo que leyó el lector en un minuto, lo que usa la línea; el resto se queda en
-- el @.json@.
data PageReading = PageReading
  { prBand        :: Text
  , prState       :: Text
  , prNext        :: Text
  , prRows        :: Int
  , prTimingNotes :: [Text]
  , prLive        :: Bool
  , prLap         :: Text
  , prLapNotes    :: [Text]
  , prFrontiers   :: [Text]
  , prProblems    :: [Text]
  }
  deriving (Eq, Show)

instance FromJSON PageReading where
  parseJSON = withObject "lectura" $ \o -> do
    band <- o .: "banda" :: Parser Object
    timing <- o .: "liveTiming" :: Parser Object
    lap <- o .: "lapComparison" :: Parser Object
    PageReading
      <$> band .: "texto" <*> band .: "estado" <*> band .: "siguiente"
      <*> (length <$> (timing .: "filas" :: Parser [Value])) <*> timing .: "avisos"
      <*> lap .: "live" <*> lap .: "vuelta" <*> lap .: "avisos" <*> lap .: "fronteras"
      <*> o .: "problemas"

-- | Una respuesta del lector (@backend\/auto\/observa.ts@): si la orden salió, lo que
-- tardó, su error y, a @lee@, la lectura.
data ReaderAnswer = ReaderAnswer
  { raOk      :: Bool
  , raMs      :: Int
  , raError   :: Maybe Text
  , raReading :: Maybe PageReading
  }
  deriving (Eq, Show)

instance FromJSON ReaderAnswer where
  parseJSON = withObject "respuesta" $ \o ->
    ReaderAnswer <$> o .: "ok" <*> o .: "ms" <*> o .:? "error" <*> o .:? "lectura"

-- | Una línea del lector; 'Nothing' si no se entiende.
readerAnswer :: BS.ByteString -> Maybe ReaderAnswer
readerAnswer = either (const Nothing) Just . eitherDecodeStrict

-- | Lo que pasa en un minuto del observador, para su línea de @observador.txt@.
data ObserverEvent
  = PageOpened Int Int                    -- ^ La instancia y lo que tardó, en ms.
  | PageNotOpened Int Text                -- ^ La instancia y el error del lector.
  | NoInstance
  | PageClosed UTCTime                    -- ^ Hasta cuándo: la foto del reloj.
  | PausedWithoutPage UTCTime             -- ^ Entra en la pausa sin página abierta.
  | ReaderHung
  | PageNotRead Text
  | PageRead PageReading (Maybe FilePath)  -- ^ Con la captura del minuto, si la hubo.
  deriving (Eq, Show)

-- | La línea de @observador.txt@ (D212, D213): las dos horas y lo que pasó. La banda va
-- como «título · estado · derecha»; Lap Comparison, con su aviso si lo hay y si no con
-- la vuelta y la última frontera; de los problemas, cuántos y el primero.
observerLine :: UTCTime -> ObserverEvent -> Text
observerLine t e = "observador " <> clockPair "%H:%M" t <> ": " <> case e of
  PageOpened p ms -> "abre la página en :" <> showT p <> " (" <> seconds ms <> ")"
  PageNotOpened p err
    | "Timeout" `T.isInfixOf` err -> "no carga la página (:" <> showT p <> " sin respuesta en 15 s)"
    | otherwise -> "no carga la página (:" <> showT p <> ": " <> firstLine err <> ")"
  NoInstance -> "no carga la página (no contesta ninguna instancia)"
  PageClosed reopen -> "cierra la página (foto del reloj de la P1, hasta las " <> mexicoHour reopen <> ")"
  PausedWithoutPage reopen -> "en pausa (foto del reloj de la P1, hasta las " <> mexicoHour reopen <> ")"
  ReaderHung -> "el lector no contestó en " <> showT readerTimeoutSeconds <> " s; se relanza"
  PageNotRead err -> "no lee la página (" <> firstLine err <> ")"
  PageRead r shot ->
    T.intercalate " · " $
      [ "banda «" <> bandWords r <> "»"
      , "Live Timing " <> showT (prRows r) <> " filas" <> noteText (prTimingNotes r)
      , lapWords r
      , problemWords (prProblems r)
      ]
        <> maybe [] (\f -> ["captura " <> T.pack f]) shot
  where
    showT :: Show a => a -> Text
    showT = T.pack . show
    seconds ms = T.replace "." "," (T.pack (printf "%.1f" (fromIntegral ms / 1000 :: Double))) <> " s"
    firstLine = T.strip . T.takeWhile (/= '\n')
    noteText notes = case notes of
      n : _ -> ", aviso «" <> n <> "»"
      []    -> ""
    lapWords r =
      let live = if prLive r then "Lap Comparison Live" else "Lap Comparison sin Live"
       in case prLapNotes r of
            _ : _ -> live <> noteText (prLapNotes r)
            [] -> T.intercalate ", " (live : filter (not . T.null) [prLap r, lastOr (prFrontiers r)])
    lastOr xs = if null xs then "" else last xs
    problemWords ps = case map localPath ps of
      []    -> "sin problemas"
      [p]   -> "1 problema («" <> p <> "»)"
      p : _ -> showT (length ps) <> " problemas («" <> p <> "», …)"

-- | La banda como «título · estado · derecha»: el lector la da de un tirón y el título
-- es lo que queda al quitarle por detrás la derecha y el estado. Si no casa, tal cual.
bandWords :: PageReading -> Text
bandWords r = T.intercalate " · " (filter (not . T.null) [title, prState r, prNext r])
  where
    title = fromMaybe (prBand r) $ do
      rest <- T.stripSuffix (prNext r) (prBand r)
      T.strip <$> T.stripSuffix (prState r) (T.strip rest)

-- | Sin el origen de la instancia: «falló GET \/api\/live…» en vez de
-- «falló GET http:\/\/127.0.0.1:3001\/api\/live…».
localPath :: Text -> Text
localPath line = case T.breakOn origin line of
  (before, rest)
    | T.null rest -> line
    | otherwise -> before <> localPath (T.dropWhile isDigit (T.drop (T.length origin) rest))
  where
    origin = "http://127.0.0.1:"

-- | La línea de @resumen.txt@ al cerrar la página por la foto del reloj (D213).
pauseLine :: UTCTime -> UTCTime -> Text
pauseLine t reopen = eventLine t "cierra" ("observador (foto del reloj de la P1, hasta " <> clockPair "%H:%M" reopen <> ")")

-- | La línea de @resumen.txt@ al volver a abrir la página tras la pausa (D213).
reopenLine :: UTCTime -> Int -> Text
reopenLine t port = eventLine t "abre" ("observador en " <> instanceAt port)

-- | La línea de @resumen.txt@ cuando el lector se cuelga y se relanza (D213).
readerRelaunchLine :: UTCTime -> Text
readerRelaunchLine t =
  eventLine t "relanza" ("observador (el lector no contestó en " <> T.pack (show readerTimeoutSeconds) <> " s)")

-- | Por qué para el observador.
data ObserverEnd = ObserverVigiaGone | ObserverCapped | ObserverCancelled
  deriving (Eq, Show)

observerStopLine :: UTCTime -> ObserverEnd -> Text
observerStopLine t end = eventLine t "para" ("observador (" <> why <> ")")
  where
    why = case end of
      ObserverVigiaGone -> "paró el vigía"
      ObserverCapped    -> "tope"
      ObserverCancelled -> "cancelado"

-- | El tiempo de inactividad del feed que se le da a @dashboardF1-record@, como a mano:
-- no es la duración, y con él no para solo en una bandera roja.
recordingIdleSeconds :: Int
recordingIdleSeconds = 7200

-- | Cuántas veces se relanza una grabación que se cortó antes de su Finalised.
maxRelaunches :: Int
maxRelaunches = 5

-- | El fichero de la vez @n@ (desde 1) de la grabación de esa sesión:
-- @grabacion-p1.txt@, y al relanzar @grabacion-p1-2.txt@, @-3@…
recordingFile :: Text -> Int -> FilePath
recordingFile session n =
  "grabacion-" <> T.unpack (sessionShort session) <> (if n <= 1 then "" else "-" <> show n) <> ".txt"

-- | Donde va lo que imprime @dashboardF1-record@: uno por sesión, para todas las veces.
recordingLog :: Text -> FilePath
recordingLog session = "grabacion-" <> T.unpack (sessionShort session) <> ".log"

-- | Cómo acaba la grabación de una sesión.
data RecordingEnd
  = RecFinalised
  | RecCapped
  | RecCancelled
  | RecGaveUp     -- ^ Se cortó la última vez que se podía relanzar.
  deriving (Eq, Show)

-- | Cuánto puede llevar sin escribirse el fichero de una grabación, contado desde la hora
-- prevista de su sesión, antes de darla por cortada: en sesión el feed late cada 15 s.
recordingStallAfter :: NominalDiffTime
recordingStallAfter = 3 * 60

-- | La vez en curso de una grabación, vista en un minuto.
data RecordingRun = RecordingRun
  { rrAlive    :: Bool                      -- ^ Si @dashboardF1-record@ sigue vivo.
  , rrRuns     :: Int                       -- ^ La vez en curso (desde 1), que es también las que cuentan.
  , rrRetries  :: Int                       -- ^ Los intentos sin conectar que la precedieron.
  , rrLaunched :: UTCTime
  , rrFile     :: Maybe (Integer, UTCTime)  -- ^ El tamaño y la última escritura de su fichero.
  }
  deriving (Eq, Show)

-- | Por qué se relanza.
data RelaunchWhy
  = Cut              -- ^ Salió solo.
  | Stalled UTCTime  -- ^ Vive, y su fichero no crece desde ese instante.
  | Unconnected      -- ^ Su fichero quedó vacío: no cuenta, y la vez siguiente reusa su número.
  deriving (Eq, Show)

-- | Lo que hace la grabación en un minuto.
data RecordingStep
  = KeepRecording
  | Connected                 -- ^ Tras intentos sin conectar, la vez en curso ya escribe.
  | Relaunch Int RelaunchWhy  -- ^ Para la vez en curso si vive y lanza la vez @n@.
  | StopRecording RecordingEnd
  deriving (Eq, Show)

-- | Un minuto de la grabación de esa sesión, con su tope, lo que dice @\/api\/live@ y la
-- vez en curso. El Finalised manda sobre todo; después el tope. La vez acaba si salió
-- sola o si su fichero lleva 'recordingStallAfter' sin escribirse (contado, como pronto,
-- desde la hora prevista de la sesión). Una vez con el fichero vacío se repite en el mismo
-- número sin límite; las demás se relanzan hasta 'maxRelaunches' veces.
recordingStep :: UTCTime -> Maybe UTCTime -> Slot -> Maybe LiveTable -> RecordingRun -> RecordingStep
recordingStep now cap slot table run
  | sessionFinalised now slot table = StopRecording RecFinalised
  | maybe False (now >=) cap = StopRecording RecCapped
  | ended && empty = Relaunch (rrRuns run) Unconnected
  | ended && rrRuns run > maxRelaunches = StopRecording RecGaveUp
  | ended = Relaunch (rrRuns run + 1) (if rrAlive run then Stalled lastWrite else Cut)
  | not empty && rrRetries run > 0 = Connected
  | otherwise = KeepRecording
  where
    empty = maybe True ((== 0) . fst) (rrFile run)
    lastWrite = maybe (rrLaunched run) (max (rrLaunched run) . snd) (rrFile run)
    stalled = diffUTCTime now (max lastWrite (slotStart slot)) >= recordingStallAfter
    ended = not (rrAlive run) || stalled

-- | La línea de @resumen.txt@ de cómo acabó (D197, D200): «para grabación P1 (Finalised)»,
-- «(tope)», «(cancelada)», o «deja grabación P1 (se cortó 6 veces; no relanza más)».
recordingStopLine :: UTCTime -> Text -> Int -> RecordingEnd -> Text
recordingStopLine t session runs end = case end of
  RecFinalised -> eventLine t "para" (what <> " (Finalised)")
  RecCapped    -> eventLine t "para" (what <> " (tope)")
  RecCancelled -> eventLine t "para" (what <> " (cancelada)")
  RecGaveUp    ->
    eventLine t "deja" (what <> " (se cortó " <> T.pack (show runs) <> " veces; no relanza más)")
  where
    what = recordingName session

-- | La línea de @resumen.txt@ de un minuto de la grabación de esa sesión, si lleva:
-- «relanza grabación P1 en grabacion-p1-2.txt (se cortó)» (D197), «(no crece desde las
-- 11:52)», «(sin conectar; reintenta cada minuto sin contar)» solo en el primer intento,
-- y «conecta grabación P1 en grabacion-p1-3.txt (tras 8 intentos)».
recordingStepLine :: UTCTime -> Text -> RecordingRun -> RecordingStep -> Maybe Text
recordingStepLine t session run step = case step of
  Relaunch n Cut -> Just (relaunch n "se cortó")
  Relaunch n (Stalled at) -> Just (relaunch n ("no crece desde las " <> mexicoHour at))
  Relaunch n Unconnected
    | rrRetries run == 0 -> Just (relaunch n "sin conectar; reintenta cada minuto sin contar")
    | otherwise -> Nothing
  Connected ->
    Just (eventLine t "conecta" (recordingName session <> " en " <> file (rrRuns run) <> " (tras " <> attempts <> ")"))
  _ -> Nothing
  where
    relaunch n why = eventLine t "relanza" (recordingName session <> " en " <> file n <> " (" <> why <> ")")
    file = T.pack . recordingFile session
    attempts = T.pack (show (rrRetries run)) <> (if rrRetries run == 1 then " intento" else " intentos")

-- | Cómo se nombra la grabación en las líneas: «grabación P1».
recordingName :: Text -> Text
recordingName session = "grabación " <> sessionLabel session

-- | Lo que una pieza necesita al disparar, además de la carpeta y su etiqueta: la
-- instancia del lanzamiento, su tope, la sesión que mira (la suya; el vigía, la
-- última del día) con su hora prevista y, la grabación, la ruta de @dashboardF1-record@.
-- Las comprobaciones, además, el log de la instancia y hasta cuándo tiene que valer el
-- token ('tokenNeed'); el observador, la ruta del lector y el inicio de su pausa.
data Dispatch = Dispatch
  { diPort       :: Int
  , diCap        :: Maybe UTCTime
  , diSession    :: Maybe Text
  , diStart      :: Maybe UTCTime
  , diRecorder   :: Maybe FilePath
  , diLog        :: Maybe FilePath
  , diTokenToday :: Maybe UTCTime
  , diTokenGp    :: Maybe UTCTime
  , diReader     :: Maybe FilePath
  , diPause      :: Maybe UTCTime
  }
  deriving (Eq, Show)

-- | Con la ruta del grabador y la del lector, la instancia, las sesiones y el plan del día.
dispatchFor :: FilePath -> FilePath -> Int -> [Slot] -> [Planned] -> Planned -> Dispatch
dispatchFor recorder reader port slots plan p =
  (bareDispatch port)
    { diCap = plCap p
    , diSession = session
    , diStart = startOf =<< session
    , diRecorder = recorderFor (plPiece p)
    , diReader = case plPiece p of
        Observer _ -> Just reader
        _          -> Nothing
    , diPause = case plPiece p of
        Observer pause -> pause
        _              -> Nothing
    }
  where
    session = case plPiece p of
      Recording s -> Just s
      Checks s    -> s
      Vigia       -> listToMaybe (reverse [s | Recording s <- map plPiece plan])
      Observer _  -> Nothing
    startOf s = lookup s [(slotName x, slotStart x) | x <- slots]
    recorderFor piece = case piece of
      Recording _ -> Just recorder
      _           -> Nothing

-- | A la orden de una tanda de comprobaciones, el log que se dio con @--log@ y lo que
-- tiene que cubrir el token ('tokenNeed'); las demás piezas, igual.
withChecks :: Maybe FilePath -> Maybe (UTCTime, Maybe UTCTime) -> Planned -> Dispatch -> Dispatch
withChecks logFile need p d = case plPiece p of
  Checks _ -> d {diLog = logFile, diTokenToday = fst <$> need, diTokenGp = snd =<< need}
  _        -> d

-- | La sesión que mira la pieza, con su hora; 'Nothing' si a la orden le falta alguna.
watchedSlot :: Dispatch -> Maybe Slot
watchedSlot d = Slot <$> diSession d <*> diStart d

-- | Los argumentos de @dispara@ tras la carpeta y la etiqueta; 'parseDispara' los lee.
dispatchArgs :: Dispatch -> [Text]
dispatchArgs d =
  ["--puerto", T.pack (show (diPort d))]
    <> maybe [] (\t -> ["--tope", isoText t]) (diCap d)
    <> maybe [] (\s -> ["--sesion", s]) (diSession d)
    <> maybe [] (\t -> ["--inicio", isoText t]) (diStart d)
    <> maybe [] (\r -> ["--grabador", T.pack r]) (diRecorder d)
    <> maybe [] (\l -> ["--log", T.pack l]) (diLog d)
    <> maybe [] (\t -> ["--fin-hoy", isoText t]) (diTokenToday d)
    <> maybe [] (\t -> ["--fin-gp", isoText t]) (diTokenGp d)
    <> maybe [] (\r -> ["--lector", T.pack r]) (diReader d)
    <> maybe [] (\t -> ["--pausa", isoText t]) (diPause d)
  where
    isoText = T.pack . formatTime defaultTimeLocale isoUtc

-- | La orden de esa instancia sin nada más.
bareDispatch :: Int -> Dispatch
bareDispatch port = Dispatch
  { diPort = port
  , diCap = Nothing
  , diSession = Nothing
  , diStart = Nothing
  , diRecorder = Nothing
  , diLog = Nothing
  , diTokenToday = Nothing
  , diTokenGp = Nothing
  , diReader = Nothing
  , diPause = Nothing
  }

parseDispara :: [Text] -> Either Text Dispatch
parseDispara = go (bareDispatch 0) False
  where
    go d True [] = Right d
    go _ False [] = Left "dispara necesita --puerto"
    go d _ ("--puerto" : n : rest)
      | [(port, "")] <- reads (T.unpack n) = go d {diPort = port} True rest
    go d hasPort ("--tope" : t : rest)
      | Just cap <- parseTimeM False defaultTimeLocale isoUtc (T.unpack t) = go d {diCap = Just cap} hasPort rest
    go d hasPort ("--sesion" : s : rest) = go d {diSession = Just s} hasPort rest
    go d hasPort ("--inicio" : t : rest)
      | Just start <- parseTimeM False defaultTimeLocale isoUtc (T.unpack t) = go d {diStart = Just start} hasPort rest
    go d hasPort ("--log" : l : rest) = go d {diLog = Just (T.unpack l)} hasPort rest
    go d hasPort ("--fin-hoy" : t : rest)
      | Just end <- parseTimeM False defaultTimeLocale isoUtc (T.unpack t) = go d {diTokenToday = Just end} hasPort rest
    go d hasPort ("--fin-gp" : t : rest)
      | Just end <- parseTimeM False defaultTimeLocale isoUtc (T.unpack t) = go d {diTokenGp = Just end} hasPort rest
    go d hasPort ("--grabador" : r : rest) = go d {diRecorder = Just (T.unpack r)} hasPort rest
    go d hasPort ("--lector" : r : rest) = go d {diReader = Just (T.unpack r)} hasPort rest
    go d hasPort ("--pausa" : t : rest)
      | Just start <- parseTimeM False defaultTimeLocale isoUtc (T.unpack t) = go d {diPause = Just start} hasPort rest
    go _ _ (word : _) = Left ("dispara: no entiendo «" <> word <> "»")

isoUtc :: String
isoUtc = "%Y-%m-%dT%H:%M:%SZ"

-- | A quién se pregunta cada minuto, por orden: la instancia del lanzamiento y
-- después las demás.
askOrder :: [Int] -> Int -> [Int]
askOrder ports home = home : filter (/= home) ports

-- | La línea de @resumen.txt@ cuando cambia quién contesta a esa pieza ('Nothing' si
-- es la misma): «cambia vigía a clon en :3001», o «pierde vigía: no contesta ninguna
-- instancia» cuando no contesta nadie.
instanceChange :: UTCTime -> Text -> Maybe Int -> Maybe Int -> Maybe Text
instanceChange t who before after
  | before == after = Nothing
  | otherwise = Just $ case after of
      Just p  -> eventLine t "cambia" (who <> " a " <> instanceAt p)
      Nothing -> eventLine t "pierde" (who <> ": no contesta ninguna instancia")

-- | La carpeta del día, dentro de @~\/MOPER@.
dayFolder :: Text -> Day -> FilePath
dayFolder label day = "dashboardF1-auto-" <> T.unpack label <> "-" <> showGregorian day

-- | Las sesiones por su nombre del feed y su nombre corto (unidades y ficheros).
sessionNames :: [(Text, Text)]
sessionNames =
  [ ("Practice 1", "p1")
  , ("Practice 2", "p2")
  , ("Practice 3", "p3")
  , ("Qualifying", "q")
  , ("Sprint Qualifying", "sq")
  , ("Sprint", "sprint")
  , ("Race", "carrera")
  ]

-- | El nombre corto; una sesión que no está en la lista, el suyo en minúsculas y con guiones.
sessionShort :: Text -> Text
sessionShort name =
  fromMaybe (T.intercalate "-" (T.words (T.toLower name))) (lookup name sessionNames)

-- | Cómo se nombra en pantalla: «P1», «Q», «SQ», «Sprint», «carrera».
sessionLabel :: Text -> Text
sessionLabel name = case sessionShort name of
  "sprint" -> "Sprint"
  short
    | short `elem` ["p1", "p2", "p3", "q", "sq"] -> T.toUpper short
    | otherwise -> short

-- | El nombre de la pieza en pantalla, en @resumen.txt@ y como descripción de su unidad,
-- que es por donde la vista casa lo de la carpeta con lo de systemd.
pieceLabel :: Piece -> Text
pieceLabel p = case p of
  Checks Nothing  -> "comprobaciones de arranque"
  Checks (Just s) -> "comprobaciones antes de la " <> sessionLabel s
  Vigia           -> "vigía"
  Observer _      -> "observador"
  Recording s     -> "grabación " <> sessionLabel s <> ", sin cuenta"

-- | La unidad de systemd de una pieza: la carpeta y la pieza (D190).
unitName :: FilePath -> Piece -> Text
unitName folder p = T.pack folder <> "-" <> slug
  where
    slug = case p of
      Checks Nothing  -> "comprobaciones-inicio"
      Checks (Just s) -> "comprobaciones-" <> sessionShort s
      Vigia           -> "vigia"
      Observer _      -> "observador"
      Recording s     -> "grabacion-" <> sessionShort s

-- | La carpeta en que se lanza: la del día o, si ya existe, la primera libre de @-2@, @-3@…
nextFolder :: FilePath -> [FilePath] -> FilePath
nextFolder base existing =
  case filter (`notElem` existing) (base : [base <> "-" <> show n | n <- [2 :: Int ..]]) of
    free : _ -> free
    []       -> base

-- | El día de una carpeta de 'dayFolder' (con o sin @-2@).
folderDay :: FilePath -> Maybe Day
folderDay folder = do
  rest <- T.stripPrefix "dashboardF1-auto-" (T.pack folder)
  let date = T.take 10 (T.drop 1 (T.dropWhile (/= '-') rest))
  parseTimeM False defaultTimeLocale "%Y-%m-%d" (T.unpack date)

-- | Lo que pide quien lanza el día: el día, las horas a mano, si es un ensayo y el log de
-- la instancia.
data Launch = Launch
  { laDay    :: Maybe Text
  , laHoras  :: Maybe Text
  , laEnsayo :: Bool
  , laLog    :: Maybe FilePath
  }
  deriving (Eq, Show)

-- | Los argumentos de @dashboardF1-auto [día] [--horas …] [--ensayo] [--log …]@, en
-- cualquier orden.
parseLaunch :: [Text] -> Either Text Launch
parseLaunch = go (Launch Nothing Nothing False Nothing)
  where
    go l [] = Right l
    go l ("--ensayo" : rest) = go l {laEnsayo = True} rest
    go _ ["--horas"] = Left "--horas necesita las horas: p. ej. --horas p1=11:30,p2=15:00"
    go l ("--horas" : spec : rest) = go l {laHoras = Just spec} rest
    go _ ["--log"] = Left "--log necesita el fichero: p. ej. --log ~/MOPER/dashboardF1-openf1-viernes-2026-10-23.txt"
    go l ("--log" : file : rest) = go l {laLog = Just (T.unpack file)} rest
    go l (word : rest)
      | not ("--" `T.isPrefixOf` word) && isNothing (laDay l) = go l {laDay = Just word} rest
    go _ (word : _) = Left ("no entiendo «" <> word <> "»")

-- | Las horas a mano, @p1=11:50,p2=12:05@: hora de México, ese día. 'Left' lleva el
-- mensaje para quien lo lanzó.
parseHoras :: Day -> Text -> Either Text [Slot]
parseHoras day spec
  | T.null (T.strip spec) = Left "--horas va vacío: p. ej. --horas p1=11:30,p2=15:00"
  | otherwise = do
      slots <- traverse one (T.splitOn "," spec)
      let names = map slotName slots
      if length names /= length (nub names)
        then Left "--horas repite una sesión"
        else Right (sortOn slotStart slots)
  where
    one item = case T.splitOn "=" (T.strip item) of
      [short, hhmm] -> Slot <$> longName (T.toLower (T.strip short)) <*> at (T.strip hhmm)
      _ -> Left ("no entiendo «" <> item <> "»: se escribe sesión=HH:MM, p. ej. p1=11:30")
    longName short =
      maybe
        (Left ("no conozco la sesión «" <> short <> "»: " <> T.unwords (map snd sessionNames)))
        Right
        (lookup short [(s, n) | (n, s) <- sessionNames])
    at hhmm =
      maybe
        (Left ("no entiendo la hora «" <> hhmm <> "»: HH:MM, en hora de México"))
        (Right . localTimeToUTC mexicoZone . LocalTime day)
        (parseTimeM False defaultTimeLocale "%H:%M" (T.unpack hhmm))

-- | Las sesiones de la temporada de Jolpica (@current\/races.json@) con el nombre del
-- feed, para cuando el calendario de la instancia falla. Una sesión que la carrera no
-- trae (la P2 de un fin de semana con sprint) no sale.
jolpicaSlots :: BL.ByteString -> Either String [Slot]
jolpicaSlots body = eitherDecode body >>= parseEither season
  where
    season = withObject "Jolpica" $ \o -> do
      mr <- o .: "MRData"
      table <- mr .: "RaceTable"
      races <- table .: "Races"
      concat <$> mapM race (races :: [Value])
    race = withObject "carrera" $ \r -> do
      main <- slotAt "Race" r
      sessions <-
        mapM (\(key, name) -> traverse (withObject "sesión" (slotAt name)) =<< (r .:? key)) jolpicaSessions
      pure (main : catMaybes sessions)
    slotAt name o = do
      date <- o .: "date"
      time <- o .: "time"
      maybe
        (fail ("hora de Jolpica ilegible: " <> date <> " " <> time))
        (pure . Slot name)
        (parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (date <> "T" <> time))
    jolpicaSessions =
      [ ("FirstPractice", "Practice 1")
      , ("SecondPractice", "Practice 2")
      , ("ThirdPractice", "Practice 3")
      , ("Qualifying", "Qualifying")
      , ("SprintQualifying", "Sprint Qualifying")
      , ("Sprint", "Sprint")
      ]

-- | Lo que contestó una instancia a @\/api\/calendar@.
data CalendarAnswer
  = Calendar [CalendarEntry]
  | CalendarMissing          -- ^ 404 o la página: una instancia con código anterior a la ruta.
  | CalendarUnreadable Text
  deriving (Eq, Show)

-- | El código, el @Content-Type@ y el cuerpo. Una página HTML es la instancia que no
-- conoce la ruta y sirve @index.html@: lo mismo que el 404.
readCalendar :: Int -> Maybe Text -> BL.ByteString -> CalendarAnswer
readCalendar 200 ctype body
  | isHtml ctype = CalendarMissing
  | otherwise = either (CalendarUnreadable . T.pack) Calendar (eitherDecode body)
readCalendar 404 _ _ = CalendarMissing
readCalendar code _ _ = CalendarUnreadable ("HTTP " <> T.pack (show code))

-- | Por qué no hay calendario, para la línea de FALLA; 'Nothing' si lo hay, aunque ese
-- día no traiga sesiones.
calendarFailure :: CalendarAnswer -> Maybe Text
calendarFailure answer = case answer of
  Calendar []          -> Just "lista vacía"
  Calendar _           -> Nothing
  CalendarMissing      -> Just "esta instancia no sirve el calendario (código anterior)"
  CalendarUnreadable e -> Just ("no se entiende la respuesta: " <> e)

-- | El camino por su puerto, como en el plan del GP.
instanceName :: Int -> Text
instanceName 3000 = "master"
instanceName 3001 = "clon"
instanceName p    = "la de :" <> T.pack (show p)

-- | El camino con su puerto: «master en :3000».
instanceAt :: Int -> Text
instanceAt p = instanceName p <> " en :" <> T.pack (show p)

-- | La cabecera de la tabla (D189): el día, el gran premio si se sabe y las horas.
dayHeader :: Day -> Maybe Text -> Text
dayHeader day gp =
  T.intercalate " · " ([dateText] <> maybe [] pure gp <> ["horas de México (UTC)"])
  where
    (_, month, dom) = toGregorian day
    dateText =
      weekdayDisplay (dayOfWeek day) <> " " <> T.pack (show dom) <> " de "
        <> fromMaybe "" (lookup month (zip [1 ..] months))
    months =
      [ "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto"
      , "septiembre", "octubre", "noviembre", "diciembre" ]

weekdayDisplay :: DayOfWeek -> Text
weekdayDisplay d = case d of
  Monday    -> "Lunes"
  Tuesday   -> "Martes"
  Wednesday -> "Miércoles"
  Thursday  -> "Jueves"
  Friday    -> "Viernes"
  Saturday  -> "Sábado"
  Sunday    -> "Domingo"

-- | La tabla del día antes del OK (D189). Con horas que no son del calendario de la
-- instancia ('Just' con su origen, «a mano» o «Jolpica»), una columna más con la hora
-- de la sesión de cada fila.
dayTable :: UTCTime -> Maybe (Text, [Slot]) -> [Planned] -> [Text]
dayTable now other plan =
  cols "Qué" ("Sesión (" <> maybe "" fst other <> ")") "Empieza" "Para (lo primero que llegue)"
    : map row plan
  where
    typed = snd <$> other
    cols a s b c =
      "  " <> T.justifyLeft 34 ' ' a <> maybe "" (const (T.justifyLeft 17 ' ' s)) typed
        <> T.justifyLeft 17 ' ' b <> c
    row p = cols (pieceLabel (plPiece p)) (session p) (startText now p) (stops p)
    session p = case plPiece p of
      Recording s     -> typedAt s
      Checks (Just s) -> typedAt s
      _               -> "—"
    typedAt s =
      maybe "—" (clockPair "%H:%M" . slotStart) (find ((== s) . slotName) (fromMaybe [] typed))
    stops p = case plPiece p of
      Checks _    -> "—"
      Vigia       -> "OpenF1 en 200 cinco min seguidos tras la " <> lastLabel <> capText p
      Observer w  -> "cuando para el vigía" <> maybe "" (pauseText . pauseFrom) w <> capText p
      Recording s -> "estado=Finalised de la " <> sessionLabel s <> capText p
    capText = maybe "" ((" · tope " <>) . clockPair "%H:%M") . plCap
    pauseText (from, to) =
      " · pausa " <> mexicoHour from <> "–" <> mexicoHour to
        <> " (" <> utcClock from <> "–" <> utcClock to <> ")"
    utcClock = T.pack . formatTime defaultTimeLocale "%H:%M"
    lastLabel = case reverse [s | Recording s <- map plPiece plan] of
      s : _ -> sessionLabel s
      []    -> "última sesión"

-- | Las sesiones de un día en una línea: «P1 11:30, P2 15:00».
slotsSummary :: [Slot] -> Text
slotsSummary = T.intercalate ", " . map one
  where
    one s =
      sessionLabel (slotName s) <> " "
        <> T.pack (formatTime defaultTimeLocale "%H:%M" (utcToZonedTime mexicoZone (slotStart s)))

-- | Las sesiones escritas como las lee 'parseHoras': «p1=11:30,p2=15:00».
horasFlag :: [Slot] -> Text
horasFlag = T.intercalate "," . map one
  where
    one s =
      sessionShort (slotName s) <> "="
        <> T.pack (formatTime defaultTimeLocale "%H:%M" (utcToZonedTime mexicoZone (slotStart s)))

-- | La hora de un temporizador de systemd, en UTC.
onCalendar :: UTCTime -> String
onCalendar = formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC"

-- | La línea de @resumen.txt@ de una pieza programada en ese instante.
programLine :: UTCTime -> Planned -> Text
programLine now p = eventLine now "programa" (pieceLabel (plPiece p) <> " · " <> startText now p)

-- | Cuándo arranca una pieza vista en ese instante: «ahora» o su hora.
startText :: UTCTime -> Planned -> Text
startText now p = if plStart p <= now then "ahora" else clockPair "%H:%M" (plStart p)

-- | Las líneas de @resumen.txt@ de un OK que llega después de la tabla: la tabla hecha en
-- un instante y lo que se programa en el del OK. Una cabecera y una línea por pieza que
-- cambia de hora o deja de programarse; sin cambios, ninguna.
lateOkLines :: UTCTime -> [Planned] -> UTCTime -> [Planned] -> [Text]
lateOkLines shown seen okAt planned = case mapMaybe change seen of
  []      -> []
  changes -> map (eventLine okAt "cambia") (("el OK llegó tarde; la tabla era de las " <> mexicoHour shown) : changes)
  where
    change p = case find ((== plPiece p) . plPiece) planned of
      Just q
        | startText shown p == startText okAt q -> Nothing
        | otherwise -> Just (was p <> " → " <> startText okAt q)
      Nothing -> Just (was p <> " → no se programa (" <> whyGone p <> ")")
    was p = pieceLabel (plPiece p) <> " · " <> startText shown p
    whyGone p = case plPiece p of
      Checks (Just s)
        | any ((== Recording s) . plPiece) planned -> "la cubren las de arranque"
        | otherwise -> capped (plCap =<< find ((== Recording s) . plPiece) seen)
      _ -> capped (plCap p)
    capped = maybe "pasó su tope" (("pasó su tope, " <>) . clockPair "%H:%M")

cancelLine :: UTCTime -> Text
cancelLine t = eventLine t "cancela" "todo lo pendiente"

-- | Una unidad de @systemctl --user list-units -o json@.
data UnitRow = UnitRow
  { urUnit        :: Text
  , urActive      :: Text
  , urSub         :: Text
  , urDescription :: Text
  }
  deriving (Eq, Show)

instance FromJSON UnitRow where
  parseJSON = withObject "unidad" $ \o ->
    UnitRow <$> o .: "unit" <*> o .: "active" <*> o .: "sub" <*> o .: "description"

-- | Un temporizador de @systemctl --user list-timers -o json@: @next@ en microsegundos,
-- 'Nothing' cuando ya disparó y su pieza sigue corriendo (systemd lo da a @null@).
data TimerRow = TimerRow
  { trUnit :: Text
  , trNext :: Maybe Integer
  }
  deriving (Eq, Show)

instance FromJSON TimerRow where
  parseJSON = withObject "temporizador" $ \o -> TimerRow <$> o .: "unit" <*> o .:? "next"

-- | Qué dice systemd de cada pieza, por su descripción: pendiente (con su hora),
-- corriendo o falló. Lo que ya acabó bien no aparece: systemd lo olvida.
unitStates :: [UnitRow] -> [TimerRow] -> [(Text, Text)]
unitStates units timers = mapMaybe state units
  where
    state u
      | ".timer" `T.isSuffixOf` urUnit u && urSub u == "waiting" =
          Just (urDescription u, "pendiente" <> maybe "" ((" · " <>) . at) (lookup (urUnit u) nexts))
      | ".service" `T.isSuffixOf` urUnit u && urActive u == "active" = Just (urDescription u, "corriendo")
      | ".service" `T.isSuffixOf` urUnit u && urActive u == "failed" = Just (urDescription u, "falló")
      | otherwise = Nothing
    nexts = [(trUnit t, n) | t <- timers, Just n <- [trNext t]]
    at micros = clockPair "%H:%M" (posixSecondsToUTCTime (fromInteger micros / 1000000))

-- | El verbo y el qué de una línea de 'eventLine'.
eventParts :: Text -> Maybe (Text, Text)
eventParts line
  | T.length line > 23 = Just (T.strip (T.take 8 (T.drop 14 line)), T.strip (T.drop 23 line))
  | otherwise = Nothing

-- | Lo que @resumen.txt@ da por pendiente: lo programado que no ha arrancado ni se canceló,
-- también lo de «ahora» hasta que su temporizador dispare.
expectedPending :: [Text] -> [Text]
expectedPending = foldl step [] . mapMaybe eventParts
  where
    step acc (verb, what) = case verb of
      "programa" -> acc <> [fst (T.breakOn " · " what)]
      "arranca"  -> filter (/= what) acc
      "cancela"  -> []
      _          -> acc

-- | Los avisos cuando la carpeta y systemd no cuadran sobre lo pendiente.
reconcile :: [Text] -> [(Text, Text)] -> [Text]
reconcile expected states =
  map (aviso "programado y no está en systemd: ") (expected \\ pending)
    <> map (aviso "en systemd y no en la carpeta: ") (pending \\ expected)
  where
    pending = [label | (label, st) <- states, "pendiente" `T.isPrefixOf` st]
    aviso why label = verdictWord Aviso <> "  " <> why <> label

-- | La primera línea de @cancela@ (D193): «Se paran (viernes 23):».
cancelHeader :: Maybe Day -> Text
cancelHeader day = "Se paran" <> maybe "" dayPart day <> ":"
  where
    dayPart d =
      let (_, _, dom) = toGregorian d
       in " (" <> T.toLower (weekdayDisplay (dayOfWeek d)) <> " " <> T.pack (show dom) <> ")"

-- | La cabecera de la vista (D191): «Viernes 23 · ~/MOPER/\<carpeta\>/».
viewHeader :: FilePath -> Text
viewHeader folder = maybe "" dayPart (folderDay folder) <> "~/MOPER/" <> T.pack folder <> "/"
  where
    dayPart d =
      let (_, _, dom) = toGregorian d
       in weekdayDisplay (dayOfWeek d) <> " " <> T.pack (show dom) <> " · "

-- | La vista (D191): la cabecera, los sucesos, lo que sigue en systemd, los avisos, la
-- última línea del vigía, en palabras ('vigiaWords'), y la del observador, tal cual (D213).
viewLines :: Text -> [Text] -> [(Text, Text)] -> [Text] -> Maybe Text -> Maybe Text -> [Text]
viewLines header events states avisos vigia observer =
  [header, ""]
    <> events
    <> (if null states then [] else "" : "En systemd:" : map stateRow states)
    <> (if null avisos then [] else "" : avisos)
    <> [ ""
       , maybe "vigía: todavía sin líneas" vigiaWords vigia
       , fromMaybe "observador: todavía sin líneas" observer
       , "Ctrl+C sale; lo programado sigue"
       ]
  where
    stateRow (label, st) = "  " <> T.justifyLeft 34 ' ' label <> st
