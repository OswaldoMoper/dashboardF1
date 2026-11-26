-- | El calendario de una temporada de Jolpica (@\/{año}\/races.json@), leído en un solo
-- sitio para los dos que lo usan: la lista de sesiones de la página ('Handler.Season') y
-- las horas del automatismo ('Auto.Helper.jolpicaSlots').
module Handler.Season.Helper
  ( JolpicaRace (..)
  , readJolpica
  , seasonRaces
  , seasonHasStarted
  , FastF1Event (..)
  , FastF1Circuit (..)
  , withFastF1Names
  , seasonYear
  ) where

import           Common.Session        (SeasonRace (..), SeasonSession (..),
                                        SessionCode (..), SessionKey (..))
import           Data.Aeson            (FromJSON (..), Key, Value, eitherDecode,
                                        withObject, (.!=), (.:), (.:?))
import           Data.Aeson.Types      (Parser, parseEither)
import qualified Data.ByteString.Lazy  as BL
import           Data.List             (sortOn)
import           Data.Maybe            (catMaybes)
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Data.Time.Clock       (UTCTime)
import           Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import           Data.Time.Format      (defaultTimeLocale, parseTimeM)
import           Text.Read             (readMaybe)

-- | Un gran premio tal como lo publica Jolpica: la carrera primero y después las demás
-- sesiones que traiga, en el orden de 'jolpicaSessions'.
data JolpicaRace = JolpicaRace
  { jrYear     :: Int
  , jrRound    :: Int
  , jrName     :: Text
  , jrSessions :: [(SessionCode, UTCTime)]
  }
  deriving (Eq, Show)

-- | 'Left' con lo que no se entendió: una respuesta que no es una temporada, o una carrera
-- o una sesión sin su hora, invalidan la temporada entera.
readJolpica :: BL.ByteString -> Either String [JolpicaRace]
readJolpica body = eitherDecode body >>= parseEither season
  where
    season = withObject "Jolpica" $ \o -> do
      mr <- o .: "MRData"
      table <- mr .: "RaceTable"
      races <- table .: "Races"
      mapM race (races :: [Value])
    race = withObject "carrera" $ \r -> do
      year <- number =<< r .: "season"
      rnd <- number =<< r .: "round"
      name <- r .: "raceName"
      main <- startAt r
      others <-
        mapM (\(key, code) -> traverse (withObject "sesión" (fmap ((,) code) . startAt)) =<< (r .:? key)) jolpicaSessions
      pure (JolpicaRace year rnd name ((Race, main) : catMaybes others))
    startAt o = do
      date <- o .: "date"
      time <- o .: "time"
      maybe
        (fail ("hora de Jolpica ilegible: " <> date <> " " <> time))
        pure
        (parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (date <> "T" <> time))
    number :: Text -> Parser Int
    number t = maybe (fail ("número de Jolpica ilegible: " <> T.unpack t)) pure (readMaybe (T.unpack t))

-- | Las claves de Jolpica de las sesiones que no son la carrera. La del formato de sprint
-- de 2023 (@SprintShootout@) no sale.
jolpicaSessions :: [(Key, SessionCode)]
jolpicaSessions =
  [ ("FirstPractice", Practice1)
  , ("SecondPractice", Practice2)
  , ("ThirdPractice", Practice3)
  , ("Qualifying", Qualifying)
  , ("SprintQualifying", SprintQualifying)
  , ("Sprint", Sprint)
  ]

-- | La temporada para la página: cada gran premio con sus sesiones en orden de hora.
seasonRaces :: [JolpicaRace] -> [SeasonRace]
seasonRaces = map one
  where
    one r =
      SeasonRace
        { raceRound    = jrRound r
        , raceName     = jrName r
        , raceSessions =
            [ SeasonSession (SessionKey (jrYear r) (jrRound r) code) (floor (utcTimeToPOSIXSeconds t))
            | (code, t) <- sortOn snd (jrSessions r)
            ]
        }

-- | Un gran premio del calendario de FastF1 (@\/fastf1\/schedule\/{año}@ del microservicio).
data FastF1Event = FastF1Event
  { feRound :: Int
  , feName  :: Text
  }
  deriving (Eq, Show)

instance FromJSON FastF1Event where
  parseJSON = withObject "FastF1Event" $ \o -> FastF1Event <$> o .: "round" <*> o .: "name"

-- | El circuito de un gran premio (@\/fastf1\/circuits\/{año}@ del microservicio): su ronda,
-- el @circuitId@ de Jolpica y el nombre del gran premio (vacío si no lo trae).
data FastF1Circuit = FastF1Circuit
  { fcRound   :: Int
  , fcCircuit :: Text
  , fcName    :: Text
  }
  deriving (Eq, Show)

instance FromJSON FastF1Circuit where
  parseJSON = withObject "FastF1Circuit" $ \o -> FastF1Circuit <$> o .: "round" <*> o .: "circuit" <*> o .:? "name" .!= ""

-- | Cada gran premio con el nombre que le da FastF1, por su ronda (2026-11-17 (h)); el que
-- FastF1 no trae se queda con el de Jolpica.
withFastF1Names :: [FastF1Event] -> [SeasonRace] -> [SeasonRace]
withFastF1Names events = map rename
  where
    rename r = maybe r (\n -> r {raceName = n}) (lookup (raceRound r) names)
    names = [(feRound e, feName e) | e <- events, not (T.null (feName e))]

-- | El año de una temporada, el de la clave de su primera sesión; 'Nothing' sin ninguna.
seasonYear :: [SeasonRace] -> Maybe Int
seasonYear races =
  case concatMap raceSessions races of
    s : _ -> Just (skYear (ssnKey s))
    []    -> Nothing

-- | Si alguna sesión de la temporada empezó ya a esa hora, inicio incluido. Mientras no,
-- la página enseña la temporada anterior.
seasonHasStarted :: UTCTime -> [JolpicaRace] -> Bool
seasonHasStarted now = any (any ((<= now) . snd) . jrSessions)
