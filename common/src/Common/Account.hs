-- | Lo que Lap Comparison dice de la cuenta de F1TV y de lo que enseña: la línea del
-- pie y el aviso encima de la gráfica.
--
-- La zona del navegador entra por argumento, en los minutos que da
-- @getTimezoneOffset@ (UTC menos la hora local), porque @common@ no depende de @time@ y
-- el @time@ del backend JavaScript de GHC no sabe leerla.
module Common.Account
  ( Stamp (..)
  , localStamp
  , Foot (..)
  , accountFoot
  , Notice (..)
  , accountNotice
  , loginCommand
  , restartCommand
  ) where

import           Common.Origin (Origin (..), originNotice)
import           Common.Types  (F1TVAccount (..))
import           Control.Monad (guard)
import           Data.Char     (isDigit)
import           Data.Text     (Text)
import qualified Data.Text     as T

-- | Un instante en la hora local: el día de la semana abreviado, el día del mes y la
-- hora.
data Stamp = Stamp
  { stWeekday :: Text
  , stDay     :: Int
  , stClock   :: Text
  }
  deriving stock (Eq, Show)

-- | El instante de un texto @AAAA-MM-DDTHH:MM:SSZ@ (la forma que emite el backend),
-- en la zona dada. Otra forma da 'Nothing'.
localStamp :: Int -> Text -> Maybe Stamp
localStamp offset raw = do
  guard (T.length s == 20 && and [T.index s i == c | (i, c) <- separators])
  [y, mo, d, h, mi] <- traverse number [(0, 4), (5, 2), (8, 2), (11, 2), (14, 2)]
  guard (mo >= 1 && mo <= 12 && d >= 1 && d <= 31 && h < 24 && mi < 60)
  let (days, inDay) = ((daysFromCivil y mo d * 24 + h) * 60 + mi - offset) `divMod` 1440
  pure Stamp
    { stWeekday = weekdayName ((days + 4) `mod` 7)
    , stDay     = civilDay days
    , stClock   = twoDigits (inDay `div` 60) <> ":" <> twoDigits (inDay `mod` 60)
    }
  where
    s = T.strip raw
    separators = [(4, '-'), (7, '-'), (10, 'T'), (13, ':'), (16, ':'), (19, 'Z')]
    number (i, n) =
      let t = T.take n (T.drop i s)
       in if T.all isDigit t then Just (read (T.unpack t)) else Nothing
    twoDigits n = T.justifyRight 2 '0' (T.pack (show n))

-- | Días desde el 1970-01-01 de una fecha del calendario gregoriano.
daysFromCivil :: Int -> Int -> Int -> Int
daysFromCivil y m d = era * 146097 + doe - 719468
  where
    y'  = if m <= 2 then y - 1 else y
    era = y' `div` 400
    yoe = y' - era * 400
    mp  = (m + 9) `mod` 12
    doy = (153 * mp + 2) `div` 5 + d - 1
    doe = yoe * 365 + yoe `div` 4 - yoe `div` 100 + doy

-- | El día del mes de un número de días desde el 1970-01-01.
civilDay :: Int -> Int
civilDay z = doy - (153 * mp + 2) `div` 5 + 1
  where
    z'  = z + 719468
    era = z' `div` 146097
    doe = z' - era * 146097
    yoe = (doe - doe `div` 1460 + doe `div` 36524 - doe `div` 146096) `div` 365
    doy = doe - (365 * yoe + yoe `div` 4 - yoe `div` 100)
    mp  = (5 * doy + 2) `div` 153

-- | Del 0 (domingo) al 6 (sábado).
weekdayName :: Int -> Text
weekdayName = \case
  0 -> "dom"
  1 -> "lun"
  2 -> "mar"
  3 -> "mié"
  4 -> "jue"
  5 -> "vie"
  _ -> "sáb"

-- | La línea del pie: discreta si la cuenta vale, en ámbar si no.
data Foot
  = FootQuiet Text
  | FootWarn Text
  deriving stock (Eq, Show)

-- | La línea del pie con la zona, si la tarjeta pinta el directo y lo que se sabe de la
-- cuenta. Si la cuenta vale, siempre; si no vale, solo en el directo, porque fuera de él
-- lo dice 'accountNotice'. Sin saber de la cuenta, 'Nothing'.
accountFoot :: Int -> Bool -> Maybe F1TVAccount -> Maybe Foot
accountFoot offset _ (Just (F1TVValid t)) = Just (FootQuiet ("F1TV: vale hasta" <> spaced (footStamp offset t)))
accountFoot offset True (Just account)    = FootWarn . ("F1TV: " <>) <$> shortState offset account
accountFoot _ _ _                         = Nothing

shortState :: Int -> F1TVAccount -> Maybe Text
shortState offset = \case
  F1TVExpired t  -> Just ("caducó" <> spaced (footStamp offset t))
  F1TVMissing    -> Just "no hay cuenta"
  F1TVUnreadable -> Just "no se entiende el fichero de la cuenta"
  F1TVValid _    -> Nothing

footStamp :: Int -> Text -> Maybe Text
footStamp offset t = (\st -> stWeekday st <> " " <> T.pack (show (stDay st)) <> ", " <> stClock st) <$> localStamp offset t

spaced :: Maybe Text -> Text
spaced = maybe "" (" " <>)

-- | El aviso encima de la gráfica, y si lleva el comando para iniciar sesión.
data Notice = Notice
  { noticeText  :: Text
  , noticeLogin :: Bool
  }
  deriving stock (Eq, Show)

-- | El aviso con la zona, si la tarjeta pinta el directo, lo que se sabe de la cuenta y
-- la procedencia de la comparación (peldaño e instante en que se trajo). En el directo,
-- ninguno: la gráfica es del feed. Con la cuenta que no vale, su estado y lo que se
-- enseña, con el comando; si vale o no se sabe, el de 'originNotice', sin él.
accountNotice :: Int -> Bool -> Maybe F1TVAccount -> Maybe Origin -> Maybe Text -> Maybe Notice
accountNotice _ True _ _ _ = Nothing
accountNotice offset False account origin fetchedAt =
  case accountSentence offset =<< account of
    Just sentence -> Just (Notice (sentence <> shownTail) True)
    Nothing       -> (`Notice` False) <$> (origin >>= \o -> originNotice o clock)
  where
    clock = stClock <$> (localStamp offset =<< fetchedAt)
    shownTail = case origin of
      Just Sample -> ": las sesiones acabadas salen de ejemplo."
      Just Cached -> kept
      Just Recent -> kept
      _           -> "."
    kept = ": es lo guardado" <> maybe "" (" de las " <>) clock <> "."

accountSentence :: Int -> F1TVAccount -> Maybe Text
accountSentence offset = \case
  F1TVExpired t  -> Just ("La cuenta de F1TV caducó" <> maybe "" when (localStamp offset t))
  F1TVMissing    -> Just "No hay cuenta de F1TV"
  F1TVUnreadable -> Just "No se entiende el fichero de la cuenta de F1TV"
  F1TVValid _    -> Nothing
  where
    when st = " el " <> stWeekday st <> " " <> T.pack (show (stDay st)) <> " a las " <> stClock st

-- | El comando que inicia sesión en la cuenta, el que copia el botón del aviso.
loginCommand :: Text
loginCommand = "dashboardF1-f1tv"

-- | El que hay que reiniciar después: el microservicio guarda en memoria la sesión que
-- cargó vacía.
restartCommand :: Text
restartCommand = "dashboardF1-dev"
