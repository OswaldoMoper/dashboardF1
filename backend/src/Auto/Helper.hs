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
  ) where

import           Common.Types        (LapProgress (..), LiveTable (..),
                                      SessionInfo (..), SessionState (..),
                                      StateReading (..), sessionStateLabel)
import           Config              (startupMark)
import           Data.List           (sortOn)
import           Data.Maybe          (fromMaybe)
import           Data.Text           (Text)
import qualified Data.Text           as T
import           Data.Time.Calendar  (Day, DayOfWeek (..), addDays, dayOfWeek,
                                      showGregorian)
import           Data.Time.Clock     (NominalDiffTime, UTCTime, addUTCTime)
import           Data.Time.Format    (defaultTimeLocale, formatTime)
import           Data.Time.LocalTime (TimeZone, localDay, minutesToTimeZone,
                                      utcToLocalTime, utcToZonedTime)
import           Handler.Live.Helper (CalendarEntry (..))
import           Text.Printf         (printf)

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
  = Checks            -- ^ Una tanda de comprobaciones de arranque.
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
        Planned Checks now Nothing
          : Planned Vigia now (Just (capOf (last live)))
          : concatMap perSlot live
  where
    live = filter ((> now) . capOf) (sortOn slotStart slots)
    capOf s = addUTCTime cap (slotStart s)
    perSlot s =
      let lead = addUTCTime (negate recordingLead) (slotStart s)
       in Planned (Recording (slotName s)) (max now lead) (Just (capOf s))
            : [Planned Checks lead Nothing | lead > now]

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
