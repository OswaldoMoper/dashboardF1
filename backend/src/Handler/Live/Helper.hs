-- | Área Live timing — lógica pura.
--
-- Modela solo los campos de OpenF1 que se consumen y los traduce a
-- 'LiveTimingRow'. Las respuestas @/position@, @/intervals@ y @/laps@ son
-- series temporales (muchas filas por piloto); aquí se reducen a la última
-- entrada por piloto y se ensambla la tabla ordenada por posición. Sin
-- efectos: todo es determinista y testeable.
module Handler.Live.Helper
  ( -- * Tipos crudos OpenF1
    Of1Driver (..)
  , Of1Position (..)
  , Of1Interval (..)
  , Of1Lap (..)
    -- * Transformaciones puras
  , assembleRows
  , latestByDriver
  , formatLap
  ) where

import           Common.Types     (LiveTimingRow (..))
import           Data.Aeson       (FromJSON (..), Value (..), withObject, (.:),
                                   (.:?))
import           Data.Aeson.Types (Parser)
import           Data.Function    (on)
import           Data.List        (find, groupBy, maximumBy, sortOn)
import           Data.Maybe       (fromMaybe, mapMaybe)
import           Data.Ord         (comparing)
import           Data.Text        (Text)
import qualified Data.Text        as T
import           Text.Printf      (printf)

-- | @/drivers@: identidad y equipo del piloto.
data Of1Driver = Of1Driver
  { odNumber  :: Int
  , odAcronym :: Text
  , odTeam    :: Text
  }
  deriving (Eq, Show)

instance FromJSON Of1Driver where
  parseJSON = withObject "Of1Driver" $ \o ->
    Of1Driver
      <$> o .: "driver_number"
      <*> o .: "name_acronym"
      <*> o .: "team_name"

-- | @/position@: posición del piloto en un instante (@date@).
data Of1Position = Of1Position
  { opNumber   :: Int
  , opPosition :: Int
  , opDate     :: Text  -- ^ ISO8601; orden lexicográfico = orden temporal.
  }
  deriving (Eq, Show)

instance FromJSON Of1Position where
  parseJSON = withObject "Of1Position" $ \o ->
    Of1Position
      <$> o .: "driver_number"
      <*> o .: "position"
      <*> o .: "date"

-- | @/intervals@: gap al líder e intervalo al de delante en un instante.
-- Ambos campos pueden ser número, cadena (p. ej. @"+1 LAP"@) o @null@; se
-- normalizan a 'Text' de presentación en el decode.
data Of1Interval = Of1Interval
  { oiNumber   :: Int
  , oiGap      :: Text
  , oiInterval :: Text
  , oiDate     :: Text
  }
  deriving (Eq, Show)

instance FromJSON Of1Interval where
  parseJSON = withObject "Of1Interval" $ \o ->
    Of1Interval
      <$> o .: "driver_number"
      <*> (o .: "gap_to_leader" >>= gapText)
      <*> (o .: "interval" >>= gapText)
      <*> o .: "date"

-- | Normaliza un valor de gap/intervalo (número | cadena | null) a 'Text'.
gapText :: Value -> Parser Text
gapText Null       = pure "-"
gapText (String s) = pure s
gapText (Number n) = pure (T.pack (printf "%+.3f" (realToFrac n :: Double)))
gapText _          = pure "-"

-- | @/laps@: duración de una vuelta concreta (@null@ en out/in laps).
data Of1Lap = Of1Lap
  { olNumber   :: Int
  , olLapNum   :: Int
  , olDuration :: Maybe Double  -- ^ Segundos; 'Nothing' si no cronometrada.
  }
  deriving (Eq, Show)

instance FromJSON Of1Lap where
  parseJSON = withObject "Of1Lap" $ \o ->
    Of1Lap
      <$> o .: "driver_number"
      <*> o .: "lap_number"
      <*> o .:? "lap_duration"

-- | Reduce una serie temporal a la última entrada por piloto: agrupa por
-- @driver_number@ y se queda con el máximo según la clave de orden dada.
latestByDriver :: Ord o => (a -> Int) -> (a -> o) -> [a] -> [a]
latestByDriver drv ordf xs =
  [ maximumBy (comparing ordf) grp
  | grp <- groupBy ((==) `on` drv) (sortOn drv xs)
  ]

-- | Formatea segundos de vuelta a @"M:SS.mmm"@ (p. ej. @89.345 → "1:29.345"@).
formatLap :: Double -> Text
formatLap secs =
  let m = floor (secs / 60) :: Int
      s = secs - fromIntegral (m * 60)
   in T.pack (printf "%d:%06.3f" m s)

-- | Ensambla la tabla de live timing uniendo por @driver_number@ y ordenando
-- por posición. Un piloto sin posición conocida se omite. El líder muestra
-- @"LEADER"@ como gap y @"-"@ como intervalo.
assembleRows
  :: [Of1Driver]
  -> [Of1Position]
  -> [Of1Interval]
  -> [Of1Lap]
  -> [LiveTimingRow]
assembleRows drivers positions intervals laps =
  sortOn ltPosition (mapMaybe row drivers)
  where
    posByDrv = latestByDriver opNumber opDate positions
    intByDrv = latestByDriver oiNumber oiDate intervals
    lapByDrv =
      latestByDriver olNumber olLapNum $
        filter (maybe False (> 0) . olDuration) laps

    row d = do
      p <- find ((== odNumber d) . opNumber) posByDrv
      let mi  = find ((== odNumber d) . oiNumber) intByDrv
          ml  = find ((== odNumber d) . olNumber) lapByDrv
          pos = opPosition p
          gap
            | pos == 1  = "LEADER"
            | otherwise = maybe "-" oiGap mi
          intv
            | pos == 1  = "-"
            | otherwise = maybe "-" oiInterval mi
          lastLap = maybe "-" (formatLap . fromMaybe 0 . olDuration) ml
      pure
        LiveTimingRow
          { ltPosition = pos
          , ltDriver   = odAcronym d
          , ltTeam     = odTeam d
          , ltGap      = gap
          , ltInterval = intv
          , ltLastLap  = lastLap
          }
