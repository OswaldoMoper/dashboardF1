-- | Lo que la e2e sirve como @\/api\/*@, construido con los tipos de la API.
--
-- Pilotos, números de coche y equipos son los de la parrilla de 2026; tiempos,
-- puntos, posiciones y stints son inventados. Sin azar: el mismo programa escribe
-- siempre los mismos bytes.
module E2eDatos
  ( Driver (..)
  , grid
  , feedP3
  , liveRace
  , historical
  , comparison
  , drivers
  , harJson
  ) where

import           Common.Types
import           Data.Aeson           (Value, encode, object, toJSON, (.=))
import qualified Data.ByteString.Lazy as BL
import           Data.Maybe           (mapMaybe)
import           Data.Text            (Text)
import qualified Data.Text            as T
import qualified Data.Text.Encoding   as TE

-- | Un piloto de la parrilla.
data Driver = Driver
  { drNumber :: Text
  , drCode   :: Text
  , drTeam   :: Text
  , drGiven  :: Text
  , drFamily :: Text
  }

-- | La parrilla, en el orden en que la da @\/api\/drivers@.
grid :: [Driver]
grid =
  [ Driver "3"  "VER" "Red Bull Racing" "Max"          "Verstappen"
  , Driver "16" "LEC" "Ferrari"         "Charles"      "Leclerc"
  , Driver "12" "ANT" "Mercedes"        "Andrea Kimi"  "Antonelli"
  , Driver "1"  "NOR" "McLaren"         "Lando"        "Norris"
  , Driver "81" "PIA" "McLaren"         "Oscar"        "Piastri"
  , Driver "44" "HAM" "Ferrari"         "Lewis"        "Hamilton"
  , Driver "30" "LAW" "Racing Bulls"    "Liam"         "Lawson"
  , Driver "27" "HUL" "Audi"            "Nico"         "Hülkenberg"
  , Driver "63" "RUS" "Mercedes"        "George"       "Russell"
  , Driver "6"  "HAD" "Red Bull Racing" "Isack"        "Hadjar"
  , Driver "10" "GAS" "Alpine"          "Pierre"       "Gasly"
  , Driver "87" "BEA" "Haas F1 Team"    "Oliver"       "Bearman"
  , Driver "31" "OCO" "Haas F1 Team"    "Esteban"      "Ocon"
  , Driver "55" "SAI" "Williams"        "Carlos"       "Sainz"
  , Driver "41" "LIN" "Racing Bulls"    "Arvid"        "Lindblad"
  , Driver "14" "ALO" "Aston Martin"    "Fernando"     "Alonso"
  , Driver "11" "PER" "Cadillac"        "Sergio"       "Pérez"
  , Driver "23" "ALB" "Williams"        "Alexander"    "Albon"
  , Driver "77" "BOT" "Cadillac"        "Valtteri"     "Bottas"
  , Driver "18" "STR" "Aston Martin"    "Lance"        "Stroll"
  , Driver "43" "COL" "Alpine"          "Franco"       "Colapinto"
  , Driver "5"  "BOR" "Audi"            "Gabriel"      "Bortoleto"
  ]

-- | Los pilotos de esos acrónimos, en ese orden; un acrónimo que no está se salta.
inOrder :: [Text] -> [Driver]
inOrder = mapMaybe (\c -> lookup c [(drCode d, d) | d <- grid])

-- | El resultado de la P3: Leclerc tercero y Bottas último.
p3Order :: [Text]
p3Order =
  [ "NOR", "PIA", "LEC", "VER", "RUS", "HAM", "ANT", "ALO", "HAD", "GAS", "SAI"
  , "ALB", "LAW", "LIN", "HUL", "BOR", "OCO", "BEA", "STR", "COL", "PER", "BOT" ]

raceOrder :: [Text]
raceOrder =
  [ "PIA", "NOR", "VER", "LEC", "ANT", "RUS", "HAM", "SAI", "ALO", "GAS", "HAD"
  , "LAW", "ALB", "BEA", "OCO", "LIN", "HUL", "STR", "BOR", "COL", "PER", "BOT" ]

standingsOrder :: [Text]
standingsOrder =
  [ "NOR", "PIA", "VER", "RUS", "LEC", "HAM", "ANT", "ALB", "HAD", "SAI", "LAW"
  , "ALO", "GAS", "OCO", "HUL", "BEA", "LIN", "STR", "BOR", "COL", "PER", "BOT" ]

-- | Milisegundos como tiempo de vuelta (@1:33.151@).
lapText :: Int -> Text
lapText ms = T.pack (show m) <> ":" <> pad 2 s <> "." <> pad 3 r
  where
    (m, rest) = ms `divMod` 60000
    (s, r)    = rest `divMod` 1000

-- | Milisegundos como sector (@25.541@).
sectorText :: Int -> Text
sectorText ms = T.pack (show s) <> "." <> pad 3 r
  where (s, r) = ms `divMod` 1000

pad :: Int -> Int -> Text
pad n = T.justifyRight n '0' . T.pack . show

-- | Una vuelta de @total@ ms partida en tres sectores, el último con lo que sobre.
sectors :: Int -> Int -> Int -> [Text]
sectors total a b = map sectorText [a, b, total - a - b]

-- | Un juego: compuesto, edad al montarlo, si es nuevo, y sus salidas (primera y
-- última vuelta de cada una).
data TyreSet = TyreSet Text Int Bool [(Int, Int)]

-- | Los stints de un piloto, como los da el feed: la edad de cada salida es la del
-- juego al volver a pista, y las que siguen a la primera van como mismo juego, no nuevo.
stintsOf :: Driver -> [TyreSet] -> [TyreStint]
stintsOf d = concatMap one
  where
    one (TyreSet compound age new outings) =
      zipWith3 stint [0 :: Int ..] outings (scanl (+) age (map laps outings))
      where
        stint i (from, to) wear = TyreStint
          { tsDriver   = drCode d
          , tsCar      = drNumber d
          , tsCompound = compound
          , tsStartLap = from
          , tsEndLap   = to
          , tsLaps     = to - from + 1
          , tsAge      = wear
          , tsNew      = Just (new && i == 0)
          , tsSameSet  = Just (i > 0)
          }
    laps (from, to) = to - from + 1

-- | Las cinco estrategias que se reparten por posición en la P3.
strategies :: [[TyreSet]]
strategies =
  [ [TyreSet "MEDIUM" 0 True [(1, 4), (5, 8), (9, 11)], TyreSet "HARD" 0 True [(12, 15), (16, 23)]]
  , [TyreSet "SOFT" 0 True [(1, 6)], TyreSet "SOFT" 2 False [(7, 12), (13, 17)]]
  , [TyreSet "HARD" 0 True [(1, 12), (13, 21)]]
  , [TyreSet "SOFT" 0 True [(1, 4), (5, 8)], TyreSet "MEDIUM" 0 True [(9, 14)]]
  , [TyreSet "MEDIUM" 1 False [(1, 9)], TyreSet "SOFT" 0 True [(10, 12), (13, 16), (17, 19)]]
  ]

-- | La estrategia de la posición @p@ (desde 1): Leclerc, tercero, lleva la primera.
strategyAt :: Int -> [TyreSet]
strategyAt p = strategies !! ((p + 2) `mod` length strategies)

row :: Int -> Driver -> LiveTimingRow
row p d = LiveTimingRow
  { ltPosition        = p
  , ltCar             = drNumber d
  , ltDriver          = drCode d
  , ltTeam            = drTeam d
  , ltGap             = "-"
  , ltInterval        = "-"
  , ltLastLap         = "-"
  , ltStatus          = Running
  , ltBestLap         = "-"
  , ltPartBestLap     = ""
  , ltPartBests       = []
  , ltKnockedOut      = False
  , ltCutoff          = False
  , ltLastSectors     = []
  , ltBestSectors     = []
  , ltPartBestSectors = []
  }

session :: Text -> Text -> SessionState -> StateBasis -> SessionInfo
session kind name state basis = SessionInfo
  { siType       = kind
  , siName       = name
  , siMeeting    = "Las Vegas Grand Prix"
  , siCircuit    = Just "Las Vegas"
  , siState      = Just (StateReading state basis)
  , siLaps       = Nothing
  , siClock      = Nothing
  , siPart       = Nothing
  , siTrack      = Nothing
  , siCountdown  = Nothing
  , siStart      = Nothing
  , siEntries    = []
  , siCutOffTime = Nothing
  }

-- | La foto de @\/api\/live@ al acabar la P3, servida como del feed: 22 coches, cada uno
-- con su estrategia.
feedP3 :: LiveTable
feedP3 = LiveTable
  { liveSession = Just (session "Practice" "Practice 3" SessionFinalised Heard)
                    { siClock = Just (SessionClock 0 False) }
  , liveRows    = zipWith p3Row [1 ..] (inOrder p3Order)
  , liveStints  = concat (zipWith (\p d -> stintsOf d (strategyAt p)) [1 ..] (inOrder p3Order))
  , liveNext    = NextAfter "Qualifying" 7200
  }
  where
    p3Row p d =
      let best = 93000 + 151 * (p - 1)
          lastLap = best + 1800 + 97 * p
      in (row p d)
           { ltGap         = if p == 1 then "LEADER" else "-"
           , ltLastLap     = lapText lastLap
           , ltBestLap     = lapText best
           , ltBestSectors = sectors best (25500 + 41 * (p - 1)) (37500 + 63 * (p - 1))
           , ltLastSectors = sectors lastLap (26100 + 41 * p) (38200 + 63 * p)
           }

-- | La carrera ya acabada, como la sirve OpenF1: sin stints ni sectores, y tres
-- abandonos al final.
liveRace :: LiveTable
liveRace = LiveTable
  { liveSession = Just (session "Race" "Race" SessionFinalised Derived)
  , liveRows    = zipWith raceRow [1 ..] (inOrder raceOrder)
  , liveStints  = []
  , liveNext    = NextAfter "Qatar Grand Prix" 604800
  }
  where
    raceRow p d =
      let best = 95100 + 113 * (p - 1)
          gap | p == 1    = "LEADER"
              | p <= 15   = "+" <> sectorText (4321 * (p - 1))
              | otherwise = "+1 LAP"
      in (row p d)
           { ltGap      = gap
           , ltInterval = if p == 1 then "-" else "+" <> sectorText (4321 + 17 * p)
           , ltLastLap  = lapText (best + 1200 + 31 * p)
           , ltBestLap  = lapText best
           , ltStatus   = if p >= 20 then Dnf else Running
           }

-- | La clasificación del campeonato: pilotos y constructores.
historical :: [HistoricalStat]
historical = zipWith driverStat [1 ..] (inOrder standingsOrder) ++ zipWith teamStat [1 ..] teams
  where
    driverStat p d = HistoricalStat
      { hsEntity     = DriverStat
      , hsCode       = drCode d
      , hsGivenName  = drGiven d
      , hsFamilyName = drFamily d
      , hsPoints     = fromIntegral (max 0 (318 - 14 * (p - 1)))
      , hsWins       = Just (fromIntegral (max 0 (7 - p)))
      , hsPosition   = Just p
      }
    teamStat p (code, name) = HistoricalStat
      { hsEntity     = ConstructorStat
      , hsCode       = code
      , hsGivenName  = ""
      , hsFamilyName = name
      , hsPoints     = fromIntegral (max 0 (561 - 52 * (p - 1)))
      , hsWins       = Just (fromIntegral (max 0 (9 - 2 * p)))
      , hsPosition   = Just p
      }
    teams =
      [ ("mclaren", "McLaren"), ("red_bull", "Red Bull"), ("mercedes", "Mercedes")
      , ("ferrari", "Ferrari"), ("williams", "Williams"), ("rb", "RB F1 Team")
      , ("aston_martin", "Aston Martin"), ("alpine", "Alpine F1 Team"), ("haas", "Haas F1 Team")
      , ("audi", "Audi"), ("cadillac", "Cadillac F1 Team") ]

-- | La comparación de fábrica, Leclerc contra Norris, sin trazas.
comparison :: LapComparison
comparison = MkLapComparison
  { lcEntries   = [ entry "16" "LEC" 94876 28101 39912, entry "1" "NOR" 95214 28230 40105 ]
  , lcSamples   = 0
  , lcNotice    = ""
  , lcTelemetry = Nothing
  }
  where
    entry car code lap s1 s2 = MkComparisonEntry
      { ceCar       = car
      , ceDriver    = code
      , ceLap       = lapText lap
      , cePart      = Nothing
      , ceSectors   = Just (ms s1, ms s2, ms (lap - s1 - s2))
      , ceFrontiers = Nothing
      , ceTrace     = []
      }
    ms v = fromIntegral v / 1000

drivers :: [DriverEntry]
drivers = [MkDriverEntry {deNumber = drNumber d, deCode = drCode d, deTeam = drTeam d} | d <- grid]

-- | El HAR que la e2e reproduce: una respuesta por ruta que la página pide al cargar.
-- El directo lleva la procedencia de OpenF1 en sus cabeceras, como lo sirve el backend.
harJson :: Value
harJson = object
  [ "log" .= object
      [ "version" .= ("1.2" :: Text)
      , "creator" .= object ["name" .= ("dashboardF1-e2e-datos" :: Text), "version" .= ("1" :: Text)]
      , "entries" .=
          [ entry "historical" [] (toJSON historical)
          , entry "comparison" [] (toJSON comparison)
          , entry "drivers" [] (toJSON drivers)
          , entry "live"
              [ ("X-Data-Fetched-At", "2026-11-07T00:00:00Z")
              , ("X-Data-Origin", "recent")
              , ("X-Data-Source", "openf1")
              ]
              (toJSON liveRace)
          ]
      ]
  ]
  where
    json = "application/json;charset=utf-8" :: Text
    none = [] :: [Value]
    header (name, value) = object ["name" .= (name :: Text), "value" .= (value :: Text)]
    entry :: Text -> [(Text, Text)] -> Value -> Value
    entry path headers body = object
      [ "startedDateTime" .= ("2026-11-07T00:00:00.000Z" :: Text)
      , "time" .= (0 :: Int)
      , "request" .= object
          [ "method" .= ("GET" :: Text)
          , "url" .= ("http://localhost:3000/api/" <> path)
          , "httpVersion" .= ("HTTP/1.1" :: Text)
          , "cookies" .= none
          , "headers" .= none
          , "queryString" .= none
          , "headersSize" .= (-1 :: Int)
          , "bodySize" .= (-1 :: Int)
          ]
      , "response" .= object
          [ "status" .= (200 :: Int)
          , "statusText" .= ("OK" :: Text)
          , "httpVersion" .= ("HTTP/1.1" :: Text)
          , "cookies" .= none
          , "headers" .= map header (("Content-Type", json) : headers)
          , "content" .= object
              [ "size" .= (-1 :: Int)
              , "mimeType" .= json
              , "text" .= TE.decodeUtf8 (BL.toStrict (encode body))
              ]
          , "headersSize" .= (-1 :: Int)
          , "bodySize" .= (-1 :: Int)
          , "redirectURL" .= ("" :: Text)
          ]
      , "cache" .= object []
      , "timings" .= object ["send" .= (-1 :: Int), "wait" .= (-1 :: Int), "receive" .= (0 :: Int)]
      ]
