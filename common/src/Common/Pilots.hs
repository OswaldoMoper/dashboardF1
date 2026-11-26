-- | Las dos tintas de cada piloto de 2026: la de su equipo y la de su casco (2026-10-08 (d),
-- 2026-11-20 (y)). Las 22 parejas están medidas entre sí, no solo entre compañeros: cambiar una
-- fila obliga a rehacer esa medida entera.
--
-- La tinta del equipo está fija aquí y no se lee del feed; la única que no es la del equipo es la
-- de ANT, en plata.
module Common.Pilots
  ( Inks (..)
  , pilotInks
  , pilotTable
  , pilotTeams
  , inksOr
  , unknownInk
  , highlightFill
  , highlightEdge
  ) where

import           Data.Maybe (fromMaybe)
import           Data.Text  (Text)
import qualified Data.Text  as T
import           Numeric    (readHex)

-- | La pareja de un piloto, en hex de seis cifras en minúsculas.
data Inks = Inks
  { inkTeam   :: Text
  , inkHelmet :: Text
  }
  deriving stock (Eq, Show)

-- | Por las siglas del piloto (p. ej. @"LEC"@). 'Nothing' para quien no está en la tabla.
pilotInks :: Text -> Maybe Inks
pilotInks code = lookup code pilotTable

-- | La pareja del piloto o, si no está en la tabla, una sola tinta, @fallback@, en las dos.
inksOr :: Text -> Text -> Inks
inksOr fallback code = fromMaybe (Inks fallback fallback) (pilotInks code)

-- | Los equipos por su nombre, con sus dos pilotos, en el orden de 'pilotTable'.
pilotTeams :: [(Text, [Text])]
pilotTeams =
  [ ("Alpine", ["GAS", "COL"])
  , ("Aston Martin", ["ALO", "STR"])
  , ("Audi", ["HUL", "BOR"])
  , ("Cadillac", ["PER", "BOT"])
  , ("Ferrari", ["LEC", "HAM"])
  , ("Haas", ["BEA", "CAM"])
  , ("McLaren", ["NOR", "PIA"])
  , ("Mercedes", ["ANT", "RUS"])
  , ("Racing Bulls", ["LAW", "LIN"])
  , ("Red Bull", ["VER", "HAD"])
  , ("Williams", ["ALB", "SAI"])
  ]

-- | Los 22, por equipo.
pilotTable :: [(Text, Inks)]
pilotTable =
  [ ("GAS", Inks alpine "#ef4135")
  , ("COL", Inks alpine "#ffffff")
  , ("ALO", Inks astonMartin "#ffd400")
  , ("STR", Inks astonMartin "#d0d3d8")
  , ("HUL", Inks audi "#c8c8c8")
  , ("BOR", Inks audi "#3ccf6e")
  , ("PER", Inks cadillac "#e0283a")
  , ("BOT", Inks cadillac "#6ea8ff")
  , ("LEC", Inks ferrari "#ffffff")
  , ("HAM", Inks ferrari "#f6c700")
  , ("BEA", Inks haas "#2164d1")
  , ("CAM", Inks haas "#2ecc71")
  , ("NOR", Inks mclaren "#ccff00")
  , ("PIA", Inks mclaren "#e4002b")
  , ("ANT", Inks "#c0c4c8" "#ffffff")
  , ("RUS", Inks mercedes "#b8d3f9")
  , ("LAW", Inks racingBulls "#ff69b4")
  , ("LIN", Inks racingBulls "#39ff14")
  , ("VER", Inks redBull "#ff9a3c")
  , ("HAD", Inks redBull "#c39bff")
  , ("ALB", Inks williams "#e6e8eb")
  , ("SAI", Inks williams "#cb2132")
  ]
  where
    alpine      = "#00a1e8"
    astonMartin = "#229971"
    audi        = "#f50537"
    cadillac    = "#909090"
    ferrari     = "#ed1131"
    haas        = "#9c9fa2"
    mclaren     = "#f47600"
    mercedes    = "#00d7b6"
    racingBulls = "#6c98ff"
    redBull     = "#4781d7"
    williams    = "#1868db"

-- | La tinta de quien no está en la tabla (un reserva): gris.
unknownInk :: Text
unknownInk = "#7d828c"

-- | El fondo de la fila de un piloto destacado (2026-11-20 (v)): la tinta de su equipo al 10 %,
-- como declaración CSS.
highlightFill :: Text -> Text
highlightFill code = "background-color:" <> withAlpha (inkTeam (inksOr unknownInk code))

-- | El borde izquierdo de la fila de un piloto destacado (2026-11-20 (v)): 3 px de la tinta del
-- equipo y, a su derecha, 3 px de la del casco, por dentro, como declaración CSS.
highlightEdge :: Text -> Text
highlightEdge code = "box-shadow:inset 3px 0 0 " <> team <> ",inset 6px 0 0 " <> helmet
  where
    Inks team helmet = inksOr unknownInk code

-- | @#rrggbb@ al 10 %; una tinta que no se lee, transparente.
withAlpha :: Text -> Text
withAlpha hex = case mapM byte [1, 3, 5] of
  Just [r, g, b] | T.length hex == 7 -> "rgba(" <> T.intercalate "," (map (T.pack . show) [r, g, b]) <> ",0.1)"
  _                                  -> "transparent"
  where
    byte i = case readHex (T.unpack (T.take 2 (T.drop i hex))) of
      [(n, "")] -> Just (n :: Int)
      _         -> Nothing
