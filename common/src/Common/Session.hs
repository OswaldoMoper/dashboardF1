-- | La clave de una sesión, @AÑO-RONDA-SESIÓN@ (@2026-20-R@): la que lleva la dirección
-- de la página en @?sesion=@ y la que entiende el microservicio FastF1.
--
-- __Se lee con cualquier mayúscula y se escribe siempre de una sola forma__ (código en
-- mayúsculas, ronda sin ceros delante): el microservicio guarda cada sesión bajo la
-- clave tal como le llega, y dos formas de la misma la cargarían dos veces.
module Common.Session
  ( SessionCode (..)
  , sessionCodeText
  , readSessionCode
  , SessionKey (..)
  , renderSessionKey
  , readSessionKey
  , sessionFromUrl
  , sessionQuery
  , notRunYet
  , notRunShown
  , notRunNotice
  , notFoundNotice
  , noStandingsNotice
    -- * La temporada
  , SeasonRace (..)
  , SeasonSession (..)
  , sessionStarted
    -- * Otras temporadas
  , CircuitRound (..)
  , firstCircuitYear
  , otherLayouts
  , sameCircuit
    -- * El directo
  , feedName
  , latestStartedKey
  , rollingKey
    -- * El selector
  , SessionPick (..)
  , selectorRaces
  , selectorLabel
  , queryWith
  ) where

import           Common.Route       (queryParamSet, urlParam)
import           Common.Types       (SessionInfo (..), StateReading (..),
                                     sessionRolling)
import           Control.Monad      (mfilter)
import           Data.Aeson         (FromJSON (..), ToJSON (..), withText)
import           Data.Char          (isDigit)
import           Data.List          (find, maximumBy, sortOn)
import           Data.List.NonEmpty (nonEmpty)
import           Data.Ord           (comparing)
import           Data.Text          (Text)
import qualified Data.Text          as T
import           GHC.Generics       (Generic)

-- | Las sesiones de un fin de semana. Sin la del formato de sprint de 2023 (@SS@).
data SessionCode
  = Practice1
  | Practice2
  | Practice3
  | SprintQualifying
  | Sprint
  | Qualifying
  | Race
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | El código de FastF1: @FP1@, @FP2@, @FP3@, @SQ@, @S@, @Q@, @R@.
sessionCodeText :: SessionCode -> Text
sessionCodeText = \case
  Practice1        -> "FP1"
  Practice2        -> "FP2"
  Practice3        -> "FP3"
  SprintQualifying -> "SQ"
  Sprint           -> "S"
  Qualifying       -> "Q"
  Race             -> "R"

-- | El código sin mirar mayúsculas; 'Nothing' si no es uno de los siete.
readSessionCode :: Text -> Maybe SessionCode
readSessionCode t = lookup (T.toUpper t) [(sessionCodeText c, c) | c <- [minBound .. maxBound]]

data SessionKey = SessionKey
  { skYear  :: Int
  , skRound :: Int
  , skCode  :: SessionCode
  }
  deriving stock (Eq, Ord, Show)

-- | @2026-20-R@. Sin ceros delante de la ronda.
renderSessionKey :: SessionKey -> Text
renderSessionKey (SessionKey year rnd code) =
  T.intercalate "-" [T.pack (show year), T.pack (show rnd), sessionCodeText code]

-- | Año de cuatro cifras desde 1950, ronda de una o dos cifras desde la 1 y código.
-- 'Nothing' con cualquier otra cosa, @latest@ y los espacios incluidos.
readSessionKey :: Text -> Maybe SessionKey
readSessionKey t = case T.splitOn "-" t of
  [y, r, c] ->
    SessionKey <$> (atLeast 1950 =<< digits 4 y) <*> (atLeast 1 =<< digits 2 r) <*> readSessionCode c
  _ -> Nothing
  where
    digits :: Int -> Text -> Maybe Int
    digits most s
      | not (T.null s) && T.length s <= most && T.all isDigit s = Just (read (T.unpack s))
      | otherwise = Nothing
    atLeast low n = if n >= low then Just n else Nothing

-- | La sesión de @?sesion=@ en la dirección de la página; 'Nothing' sin el parámetro o
-- con uno que no es una clave.
sessionFromUrl :: Text -> Maybe SessionKey
sessionFromUrl url = readSessionKey =<< urlParam "sesion" url

-- | La sesión como valor de @?session=@ de la API; 'Nothing' es «sin elegir».
sessionQuery :: Maybe SessionKey -> Maybe Text
sessionQuery = fmap renderSessionKey

-- | Si lo que llega es de una sesión elegida (@chosen@) que aún no se ha corrido: sin
-- filas. Sin sesión elegida nunca lo es.
notRunYet :: Bool -> [a] -> Bool
notRunYet chosen rows = chosen && null rows

-- | 'notRunYet' de lo último que llegó bien; mientras no ha llegado nada, no.
notRunShown :: Bool -> Maybe [a] -> Bool
notRunShown chosen = maybe False (notRunYet chosen)

-- | El aviso de una tabla o unos stints sin filas (notRunYet).
notRunNotice :: Text
notRunNotice = "Sesión aún sin correr"

-- | El aviso de una sesión elegida que no existe: su petición dio @404@ y nada llegó bien.
notFoundNotice :: Text
notFoundNotice = "Sesión no encontrada"

-- | El aviso de una clasificación sin filas.
noStandingsNotice :: Text
noStandingsNotice = "Sin clasificación todavía"

-- | Viaja como la clave escrita, @"2026-20-R"@.
instance ToJSON SessionKey where
  toJSON = toJSON . renderSessionKey

instance FromJSON SessionKey where
  parseJSON = withText "clave de sesión" $ \t ->
    maybe (fail ("clave de sesión ilegible: " <> T.unpack t)) pure (readSessionKey t)

-- | Un gran premio de la temporada con sus sesiones, en orden de hora.
data SeasonRace = SeasonRace
  { raceRound    :: Int
  , raceName     :: Text
  , raceSessions :: [SeasonSession]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SeasonRace
instance FromJSON SeasonRace

data SeasonSession = SeasonSession
  { ssnKey   :: SessionKey
  , ssnStart :: Int
    -- ^ La hora de inicio prevista, en segundos desde 1970 (UTC).
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SeasonSession
instance FromJSON SeasonSession

-- | Un gran premio de otra temporada en el mismo circuito y con la misma disposición
-- (2026-11-21 (t)), con su nombre (vacío si no se sabe; 2026-11-21 (ab)).
data CircuitRound = CircuitRound
  { crYear  :: Int
  , crRound :: Int
  , crName  :: Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON CircuitRound
instance FromJSON CircuitRound

-- | El primer año en el que se buscan grandes premios del mismo circuito.
firstCircuitYear :: Int
firstCircuitYear = 2018

-- | Los grandes premios, por año y ronda, que usaron un trazado distinto del de siempre de su
-- circuito: solo trazados distintos, no los retoques de curvas (2026-11-21 (v)). Sakhir 2020,
-- el exterior de Bahrein.
otherLayouts :: [(Int, Int)]
otherLayouts = [(2020, 16)]

-- | De los circuitos de cada año, @years@ (por ronda, el @circuitId@ de Jolpica, que no cambia
-- con los años, y el nombre del gran premio), los grandes premios de otros años en el mismo circuito y con la misma
-- disposición que el de @(year, round)@: del año más nuevo al más viejo y, en un año, por
-- ronda. Vacío si ese no está en @years@.
sameCircuit :: (Int, Int) -> [(Int, [(Int, Text, Text)])] -> [CircuitRound]
sameCircuit (y, r) years = case [c | (r', c, _) <- concat (lookup y years), r' == r] of
  []    -> []
  c : _ ->
    sortOn (\cr -> (negate (crYear cr), crRound cr))
      [ CircuitRound y' r' n
      | (y', rs) <- years, y' /= y, (r', c', n) <- rs, c' == c
      , ((y', r') `elem` otherLayouts) == ((y, r) `elem` otherLayouts) ]

-- | Si la sesión ya empezó a esa hora (segundos desde 1970, UTC), inicio incluido.
sessionStarted :: Int -> SeasonSession -> Bool
sessionStarted now s = ssnStart s <= now

-- | El nombre de la sesión en el feed y en OpenF1.
feedName :: SessionCode -> Text
feedName Practice1        = "Practice 1"
feedName Practice2        = "Practice 2"
feedName Practice3        = "Practice 3"
feedName SprintQualifying = "Sprint Qualifying"
feedName Sprint           = "Sprint"
feedName Qualifying       = "Qualifying"
feedName Race             = "Race"

-- | La sesión de la temporada de la que habla la tabla del directo (2026-11-17 (i)): la
-- última del calendario que ya empezó a esa hora (segundos desde 1970, UTC), solo si su
-- tipo es el de la tabla. 'Nothing' sin calendario, sin sesión en la tabla o si no casan.
latestStartedKey :: Int -> [SeasonRace] -> Maybe SessionInfo -> Maybe SessionKey
latestStartedKey now races info = do
  started <- nonEmpty (filter (sessionStarted now) (concatMap raceSessions races))
  named <- info
  mfilter (\k -> feedName (skCode k) == siName named)
    (Just (ssnKey (maximumBy (comparing ssnStart) started)))

-- | La sesión de la temporada que rueda en el directo ('Common.Types.sessionRolling'), por
-- 'latestStartedKey'. 'Nothing' si el directo no rueda o no casa con el calendario.
rollingKey :: Int -> [SeasonRace] -> Maybe SessionInfo -> Maybe SessionKey
rollingKey now races info =
  latestStartedKey now races (mfilter (sessionRolling . fmap srState . siState) info)

-- | Un botón de la lista del selector: la sesión, si ya empezó (si no, no se puede
-- elegir), si es la elegida y si es la que rueda en el directo.
data SessionPick = SessionPick
  { spKey     :: SessionKey
  , spStarted :: Bool
  , spChosen  :: Bool
  , spLive    :: Bool
  }
  deriving stock (Eq, Show)

-- | Los grandes premios de la lista del selector a esa hora, el más reciente arriba: todos
-- hasta el primero con alguna sesión sin empezar (el en curso o el próximo), incluido; los
-- de después no salen (2026-11-17 (o)). @live@ es la que rueda ('rollingKey').
selectorRaces :: Int -> Maybe SessionKey -> Maybe SessionKey -> [SeasonRace] -> [(SeasonRace, [SessionPick])]
selectorRaces now chosen live races = reverse (map picks (done <> take 1 rest))
  where
    (done, rest) = break (not . all (sessionStarted now) . raceSessions) (sortOn raceRound races)
    picks r = (r, map pick (raceSessions r))
    pick s =
      SessionPick
        { spKey     = ssnKey s
        , spStarted = sessionStarted now s
        , spChosen  = Just (ssnKey s) == chosen
        , spLive    = Just (ssnKey s) == live
        }

-- | Lo que dice el botón del selector: el título de lo que se enseña; mientras no lo hay,
-- la sesión elegida con el nombre de su gran premio en la temporada; si la temporada no la
-- nombra (aún no ha llegado, o la sesión no existe), su clave, @2026-20-R@ (2026-11-18 (f)); y
-- sin sesión elegida, @«Elegir sesión»@.
selectorLabel :: Text -> Maybe SessionKey -> [SeasonRace] -> Text
selectorLabel title chosen races
  | not (T.null title) = title
  | Just k <- chosen, Just r <- find (has k) races = raceName r <> " · " <> sessionCodeText (skCode k)
  | Just k <- chosen = renderSessionKey k
  | otherwise = "Elegir sesión"
  where
    has k r = any ((== k) . ssnKey) (raceSessions r)

-- | La query de la dirección (@?retraso=0&sesion=2026-20-R@) con @sesion@ puesta a esa
-- sesión, o quitada con 'Nothing'; lo demás se queda en su orden. Sin nada, @""@.
queryWith :: Maybe SessionKey -> Text -> Text
queryWith chosen = queryParamSet "sesion" (renderSessionKey <$> chosen)
