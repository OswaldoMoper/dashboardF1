-- | El automatismo del GP — lógica pura.
--
-- Las reglas con las que @dashboardF1-auto@ programa un día de GP y juzga lo que ve:
-- qué sesiones hay ese día, cuándo arranca y cuándo para cada pieza, y qué dice cada
-- línea de los ficheros de la carpeta del día. Sin efectos.
module Auto.Helper
  ( -- * Las horas
    mexicoZone
  , mexicoDay
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
    -- * Cuándo para cada pieza
  , pastCap
  , sessionFinalised
  , VigiaWatch (..)
  , openf1QuietMinutes
  , vigiaStep
  , vigiaDone
    -- * Lo que se juzga
  , Verdict (..)
  , verdictWord
  , openf1Verdict
  , LogCount (..)
  , sinceLastStart
  , countLog
  , logCheck
    -- * Las líneas de los ficheros
  , checkLine
  , eventLine
  , VigiaReading (..)
  , vigiaLine
  , dayFolder
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
  , CalendarAnswer (..)
  , readCalendar
  , calendarFailure
  , instanceName
    -- * Lo que enseña el comando
  , dayHeader
  , dayTable
  , slotsSummary
  , onCalendar
  , programLine
  , firedLine
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

import           Common.Types          (LapProgress (..), LiveTable (..),
                                        SessionInfo (..), SessionState (..),
                                        StateReading (..), sessionStateLabel)
import           Config                (startupMark)
import           Data.Aeson            (FromJSON (..), eitherDecode, withObject,
                                        (.:))
import qualified Data.ByteString.Lazy  as BL
import           Data.List             (find, nub, sortOn, (\\))
import           Data.Maybe            (fromMaybe, isNothing, mapMaybe)
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Data.Time.Calendar    (Day, DayOfWeek (..), addDays, dayOfWeek,
                                        showGregorian, toGregorian)
import           Data.Time.Clock       (NominalDiffTime, UTCTime, addUTCTime)
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           Data.Time.Format      (defaultTimeLocale, formatTime,
                                        parseTimeM)
import           Data.Time.LocalTime   (LocalTime (..), TimeZone, localDay,
                                        localTimeToUTC, minutesToTimeZone,
                                        utcToLocalTime, utcToZonedTime)
import           Handler.Live.Helper   (CalendarEntry (..))
import           Text.Printf           (printf)

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
-- Comprobaciones y vigía al lanzar; por sesión, a T−45, la grabación y otra tanda de
-- comprobaciones. __Lo que ya debía haber arrancado arranca al lanzar__, y entonces
-- su tanda de T−45 sobra (la de lanzar la cubre). Una sesión cuyo tope ya pasó no
-- se programa. Sin sesiones, nada: ni el vigía.
dayPlan :: NominalDiffTime -> UTCTime -> [Slot] -> [Planned]
dayPlan cap now slots =
  case live of
    [] -> []
    _ ->
      sortOn plStart $
        Planned (Checks Nothing) now Nothing
          : Planned Vigia now (Just (capOf (last live)))
          : concatMap perSlot live
  where
    live = filter ((> now) . capOf) (sortOn slotStart slots)
    capOf s = addUTCTime cap (slotStart s)
    perSlot s =
      let lead = addUTCTime (negate recordingLead) (slotStart s)
       in Planned (Recording (slotName s)) (max now lead) (Just (capOf s))
            : [Planned (Checks (Just (slotName s))) lead Nothing | lead > now]

pastCap :: UTCTime -> Planned -> Bool
pastCap now = maybe False (now >=) . plCap

-- | Si @\/api\/live@ da esa sesión por finalizada. Cuenta igual el estado oído que el
-- deducido del calendario, como el @estado=@ del vigía manual.
sessionFinalised :: Text -> Maybe LiveTable -> Bool
sessionFinalised name table =
  case liveSession =<< table of
    Just si -> siName si == name && fmap srState (siState si) == Just SessionFinalised
    Nothing -> False

-- | Lo que el vigía lleva visto para saber cuándo parar.
data VigiaWatch
  = Watching       -- ^ La última sesión del día aún no ha acabado.
  | QuietFor Int   -- ^ Ya acabó, y OpenF1 lleva esos minutos seguidos en 200.
  deriving (Eq, Show)

openf1QuietMinutes :: Int
openf1QuietMinutes = 5

-- | Un minuto más del vigía: la última sesión del día, la respuesta de @\/api\/live@
-- y el código de OpenF1 ('Nothing' si no contestó). Los minutos en 200 cuentan
-- __después__ del de @Finalised@, y uno que no sea 200 los vuelve a cero.
vigiaStep :: Text -> Maybe LiveTable -> Maybe Int -> VigiaWatch -> VigiaWatch
vigiaStep lastName table _ Watching
  | sessionFinalised lastName table = QuietFor 0
  | otherwise                       = Watching
vigiaStep _ _ code (QuietFor n)
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

-- | La hora de México y, entre paréntesis, la UTC.
clockPair :: String -> UTCTime -> Text
clockPair fmt t =
  T.pack (formatTime defaultTimeLocale fmt (utcToZonedTime mexicoZone t))
    <> " (" <> T.pack (formatTime defaultTimeLocale fmt t) <> ")"

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
  Recording s     -> "grabación " <> sessionLabel s <> ", sin cuenta"

-- | La unidad de systemd de una pieza: la carpeta y la pieza (D190).
unitName :: FilePath -> Piece -> Text
unitName folder p = T.pack folder <> "-" <> slug
  where
    slug = case p of
      Checks Nothing  -> "comprobaciones-inicio"
      Checks (Just s) -> "comprobaciones-" <> sessionShort s
      Vigia           -> "vigia"
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

-- | Lo que pide quien lanza el día: el día, las horas a mano y si es un ensayo.
data Launch = Launch
  { laDay    :: Maybe Text
  , laHoras  :: Maybe Text
  , laEnsayo :: Bool
  }
  deriving (Eq, Show)

-- | Los argumentos de @dashboardF1-auto [día] [--horas …] [--ensayo]@, en cualquier orden.
parseLaunch :: [Text] -> Either Text Launch
parseLaunch = go (Launch Nothing Nothing False)
  where
    go l [] = Right l
    go l ("--ensayo" : rest) = go l {laEnsayo = True} rest
    go _ ["--horas"] = Left "--horas necesita las horas: p. ej. --horas p1=11:30,p2=15:00"
    go l ("--horas" : spec : rest) = go l {laHoras = Just spec} rest
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

-- | Lo que contestó una instancia a @\/api\/calendar@.
data CalendarAnswer
  = Calendar [CalendarEntry]
  | CalendarMissing          -- ^ 404: una instancia con código anterior a la ruta.
  | CalendarUnreadable Text
  deriving (Eq, Show)

readCalendar :: Int -> BL.ByteString -> CalendarAnswer
readCalendar 200 body = either (CalendarUnreadable . T.pack) Calendar (eitherDecode body)
readCalendar 404 _ = CalendarMissing
readCalendar code _ = CalendarUnreadable ("HTTP " <> T.pack (show code))

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

-- | La tabla del día antes del OK (D189). Con las horas a mano ('Just'), una columna
-- más con la hora tecleada de la sesión de cada fila.
dayTable :: UTCTime -> Maybe [Slot] -> [Planned] -> [Text]
dayTable now typed plan =
  cols "Qué" "Sesión (a mano)" "Empieza" "Para (lo primero que llegue)" : map row plan
  where
    cols a s b c =
      "  " <> T.justifyLeft 34 ' ' a <> maybe "" (const (T.justifyLeft 17 ' ' s)) typed
        <> T.justifyLeft 17 ' ' b <> c
    row p = cols (pieceLabel (plPiece p)) (session p) (start p) (stops p)
    session p = case plPiece p of
      Recording s     -> typedAt s
      Checks (Just s) -> typedAt s
      _               -> "—"
    typedAt s =
      maybe "—" (clockPair "%H:%M" . slotStart) (find ((== s) . slotName) (fromMaybe [] typed))
    start p
      | plStart p <= now = "ahora"
      | otherwise = clockPair "%H:%M" (plStart p)
    stops p = case plPiece p of
      Checks _    -> "—"
      Vigia       -> "OpenF1 en 200 cinco min seguidos tras la " <> lastLabel <> capText p
      Recording s -> "estado=Finalised de la " <> sessionLabel s <> capText p
    capText = maybe "" ((" · tope " <>) . clockPair "%H:%M") . plCap
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

-- | La hora de un temporizador de systemd, en UTC.
onCalendar :: UTCTime -> String
onCalendar = formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC"

-- | La línea de @resumen.txt@ de una pieza programada en ese instante.
programLine :: UTCTime -> Planned -> Text
programLine now p = eventLine now "programa" (pieceLabel (plPiece p) <> " · " <> start)
  where
    start = if plStart p <= now then "ahora" else clockPair "%H:%M" (plStart p)

firedSuffix :: Text
firedSuffix = " (sin hacer todavía)"

-- | La constancia de una pieza que disparó y que aún no hace nada.
firedLine :: UTCTime -> Text -> Text
firedLine t label = eventLine t "arranca" (label <> firedSuffix)

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

-- | Un temporizador de @systemctl --user list-timers -o json@: @next@ en microsegundos.
data TimerRow = TimerRow
  { trUnit :: Text
  , trNext :: Integer
  }
  deriving (Eq, Show)

instance FromJSON TimerRow where
  parseJSON = withObject "temporizador" $ \o -> TimerRow <$> o .: "unit" <*> o .: "next"

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
    nexts = [(trUnit t, trNext t) | t <- timers]
    at micros = clockPair "%H:%M" (posixSecondsToUTCTime (fromInteger micros / 1000000))

-- | El verbo y el qué de una línea de 'eventLine'.
eventParts :: Text -> Maybe (Text, Text)
eventParts line
  | T.length line > 23 = Just (T.strip (T.take 8 (T.drop 14 line)), T.strip (T.drop 23 line))
  | otherwise = Nothing

-- | Lo que @resumen.txt@ da por pendiente: lo programado que no ha arrancado ni se canceló.
expectedPending :: [Text] -> [Text]
expectedPending = foldl step [] . mapMaybe eventParts
  where
    step acc (verb, what) = case verb of
      "programa" | not (isStartNow what) -> acc <> [fst (T.breakOn " · " what)]
      "arranca" -> filter (/= fromMaybe what (T.stripSuffix firedSuffix what)) acc
      "cancela" -> []
      _ -> acc
    isStartNow = (" · ahora" `T.isSuffixOf`)

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

-- | La vista (D191): la cabecera, los sucesos, lo que sigue en systemd, los avisos y
-- la última línea del vigía.
viewLines :: Text -> [Text] -> [(Text, Text)] -> [Text] -> Maybe Text -> [Text]
viewLines header events states avisos vigia =
  [header, ""]
    <> events
    <> (if null states then [] else "" : "En systemd:" : map stateRow states)
    <> (if null avisos then [] else "" : avisos)
    <> ["", maybe "vigía: todavía sin líneas" ("vigía " <>) vigia, "Ctrl+C sale; lo programado sigue"]
  where
    stateRow (label, st) = "  " <> T.justifyLeft 34 ' ' label <> st
