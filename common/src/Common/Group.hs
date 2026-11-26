-- | Lo que los grupos de una tarjeta le dan (2026-11-20 (g)): un grupo fija parámetros y
-- lo comparten todas las tarjetas que están en él, estén donde estén. Lo que destacan y las
-- sesiones que suman se juntan de todos los grupos de la tarjeta; en Lap Comparison, los
-- pilotos destacados entran como curvas, sin quitar nunca los de la tarjeta.
--
-- Puro. Los pilotos van por siglas, como "Common.Pilots".
module Common.Group
  ( cardGroups
  , highlightedDrivers
  , GroupSession (..)
  , SeasonPick (..)
  , readGroupSession
  , renderGroupSession
  , addedSessions
  , bestPerSession
  , fromTag
  , autoName
  , uniqueName
  , comparisonLimit
  , ComparisonPick (..)
  , comparisonPick
    -- * Editar los grupos
  , GroupDraft (..)
  , draftReady
  , groupDraft
  , chosenName
  , GroupEdit (..)
  , applyGroupEdit
  , freshGroupId
  , cardsInGroup
  , cardCountText
  , SessionChoice (..)
  , sessionChoices
  , choicesHint
  , sessionTag
  , SeasonOption (..)
  , seasonOptions
  , seasonHint
  , gpShortName
  , gpLabel
  , otherDrivers
  , isAutoName
  ) where

import           Common.Pilots       (pilotInks)
import           Common.Session      (CircuitRound (..), SeasonRace (..),
                                      SeasonSession (..), SessionCode (..),
                                      SessionKey (..), firstCircuitYear,
                                      readSessionCode, readSessionKey,
                                      renderSessionKey, sessionCodeText,
                                      sessionStarted)
import           Common.Types        (CardGroup (..), GroupId (..),
                                      Layout (..), LiveTimingRow (..),
                                      WidgetConfig (..), WidgetId, lapSeconds)
import           Control.Applicative ((<|>))
import           Control.Monad       (mfilter)
import           Data.Char           (isDigit)
import           Data.List           (find, nub, sortOn)
import           Data.Maybe          (isJust, isNothing, listToMaybe, mapMaybe)
import           Data.Text           (Text)
import qualified Data.Text           as T

-- | Los grupos de la tarjeta en el orden de 'widgetGroups'. Un id que no es de ningún
-- grupo del layout no cuenta, y uno repetido cuenta una vez.
cardGroups :: Layout -> WidgetConfig -> [CardGroup]
cardGroups l w = mapMaybe (\g -> find ((== g) . groupId) (layoutGroups l)) (nub (widgetGroups w))

-- | Los pilotos que destacan los grupos: se suman, en el orden de los grupos y sin
-- repetir (2026-11-20 (h)).
highlightedDrivers :: [CardGroup] -> [Text]
highlightedDrivers = nub . concatMap groupDrivers

-- | La sesión que suma un grupo (2026-11-21 (f)).
data GroupSession
  = RelativeSession SessionCode
    -- ^ Esa sesión del GP que se ve: «Contra P1» suma la FP1 de cada fin de semana.
  | OtherSeason SeasonPick Int SessionCode
    -- ^ Esa sesión del mismo circuito que se ve, de otra temporada (2026-11-21 (t)), del gran
    -- premio que hace ese número en ese año en el circuito: 1, el primero o el único ((ab)).
  | FixedSession SessionKey
    -- ^ Esa sesión concreta; la guardaba «Otro GP…», que ya no está.
  deriving stock (Eq, Show)

-- | De qué temporada es la sesión de un grupo con 'OtherSeason'.
data SeasonPick
  = YearsBack Int
    -- ^ Tantos años antes que la que se ve.
  | InYear Int
    -- ^ Ese año.
  deriving stock (Eq, Show)

-- | Lee 'groupSession': un código solo (@FP1@) es relativo; con @@-N@ (@Q@-1@), N años antes;
-- con @@AAAA@ (@Q@2025@), ese año, y detrás @#2@ (@Q@2021#2@), el segundo gran premio de ese año
-- en el circuito (sin él, el primero); una clave (@2026-21-FP1@), fija. 'Nothing' con
-- cualquier otra cosa.
readGroupSession :: Text -> Maybe GroupSession
readGroupSession t = FixedSession <$> readSessionKey t <|> RelativeSession <$> readSessionCode t <|> other
  where
    other = case T.splitOn "@" t of
      [c, p] -> case T.splitOn "#" p of
        [y]    -> OtherSeason <$> pick y <*> pure 1 <*> readSessionCode c
        [y, k] -> OtherSeason <$> pick y <*> (mfilter (> 1) (number k)) <*> readSessionCode c
        _      -> Nothing
      _      -> Nothing
    pick p = case T.uncons p of
      Just ('-', n) | Just k <- number n, k > 0 -> Just (YearsBack k)
      _ | Just y <- number p, T.length p == 4         -> Just (InYear y)
      _                                               -> Nothing
    number d = if not (T.null d) && T.all isDigit d then Just (read (T.unpack d)) else Nothing

-- | Lo que se guarda en 'groupSession'; 'readGroupSession' lo lee de vuelta.
renderGroupSession :: GroupSession -> Text
renderGroupSession = \case
  RelativeSession c             -> sessionCodeText c
  OtherSeason (YearsBack n) k c -> sessionCodeText c <> "@-" <> T.pack (show n) <> nth k
  OtherSeason (InYear y) k c    -> sessionCodeText c <> "@" <> T.pack (show y) <> nth k
  FixedSession k                -> renderSessionKey k
  where
    nth k = if k > 1 then "#" <> T.pack (show k) else ""

-- | Las sesiones que suman los grupos a la que se ve, en su orden y sin repetir
-- (2026-11-20 (i)). Una relativa toma el año y la ronda de la que se ve; una de otra temporada,
-- el gran premio de ese año en el mismo circuito, de @rounds@ ('Common.Session.sameCircuit'), el
-- que dice su número por ronda (con uno solo ese año, el único; 2026-11-21 (ab)), y si ese año no
-- se corrió, no cuenta. Sin sesión vista, solo
-- cuentan las fijas. La que se ve no se devuelve: ya está en juego. Una 'groupSession' ilegible
-- no cuenta.
addedSessions :: Maybe SessionKey -> [CircuitRound] -> [CardGroup] -> [SessionKey]
addedSessions viewed rounds = filter ((/= viewed) . Just) . nub . mapMaybe sessionOf
  where
    sessionOf g = resolve =<< readGroupSession =<< groupSession g
    resolve = \case
      FixedSession k    -> Just k
      RelativeSession c -> (\v -> v { skCode = c }) <$> viewed
      OtherSeason p k c -> do
        v <- viewed
        let year = seasonYear (skYear v) p
            ofYear = filter ((== year) . crYear) (sortOn crRound rounds)
        if year == skYear v
          then Just v { skCode = c }
          else (\cr -> SessionKey year (crRound cr) c)
                 <$> (listToMaybe (drop (k - 1) ofYear) <|> listToMaybe ofYear)

-- | El año de una temporada elegida, visto desde @year@.
seasonYear :: Int -> SeasonPick -> Int
seasonYear year = \case
  YearsBack n -> year - n
  InYear y    -> y

-- | «1 año antes», «3 años antes».
yearsBefore :: Int -> Text
yearsBefore 1 = "1 año antes"
yearsBefore n = T.pack (show n) <> " años antes"

-- | La Best Lap de la fila @r@ en cada sesión que suman sus grupos, @added@, en su orden
-- (2026-11-21 (z)): la cifra del piloto y si es la más rápida de toda esa sesión ((aa); un
-- empate marca a todos). 'Nothing' donde la sesión no trae al piloto, buscado por siglas, o
-- su vuelta no se lee. La de la sesión que se ve no va: es la de la fila.
bestPerSession :: [(SessionKey, [LiveTimingRow])] -> LiveTimingRow -> [(SessionKey, Maybe (Text, Bool))]
bestPerSession added r = [(k, figure rows) | (k, rows) <- added]
  where
    figure rows = do
      o <- find ((== ltDriver r) . ltDriver) rows
      t <- lapSeconds (ltBestLap o)
      pure (ltBestLap o, Just t == fastest rows)
    fastest rows = case mapMaybe (lapSeconds . ltBestLap) rows of
      [] -> Nothing
      ts -> Just (minimum ts)

-- | La etiqueta de la sesión de la que sale una cifra (2026-11-20 (n)), vista desde
-- @viewed@: su código como en el nombre de un grupo («P1», «Q»), y su año si es de otro.
fromTag :: SessionKey -> SessionKey -> Text
fromTag viewed k =
  shortCode (skCode k) <> (if skYear k == skYear viewed then "" else " " <> T.pack (show (skYear k)))

-- | El nombre que se pone solo al crear un grupo (2026-11-20 (ae), 2026-11-21 (g)): uno o dos
-- pilotos por apellido («Leclerc», «Leclerc y Norris»), tres o más por siglas («LEC, NOR y
-- PIA»); con sesión, «[pilotos] contra [sesión]» o «Contra [sesión]», y una fija lleva «de [GP]»
-- y, si no es de @season@, el año. @surname@ da el apellido de unas siglas y @gpName@ el nombre
-- del GP de una sesión. Sin pilotos ni sesión, «Grupo».
autoName :: Int -> (Text -> Text) -> (SessionKey -> Text) -> [Text] -> Maybe GroupSession -> Text
autoName season surname gpName drivers session = case (pilots, sessionPart <$> session) of
  ("", Nothing) -> "Grupo"
  (p, Nothing)  -> p
  ("", Just s)  -> "Contra " <> s
  (p, Just s)   -> p <> " contra " <> s
  where
    pilots = case drivers of
      []     -> ""
      [a]    -> surname a
      [a, b] -> surname a <> " y " <> surname b
      ds     -> listed ds
    listed ds = T.intercalate ", " (init ds) <> " y " <> last ds
    sessionPart = \case
      RelativeSession c             -> shortCode c
      OtherSeason (YearsBack n) _ c -> shortCode c <> ", " <> yearsBefore n
      OtherSeason (InYear y) _ c    -> shortCode c <> " " <> T.pack (show y)
      FixedSession k    ->
        shortCode (skCode k) <> " de " <> gpName k
          <> (if skYear k == season then "" else " " <> T.pack (show (skYear k)))

-- | El código de una sesión en el nombre de un grupo: los libres, P1 a P3; las demás, como la
-- banda (2026-11-21 (g)).
shortCode :: SessionCode -> Text
shortCode = \case
  Practice1 -> "P1"
  Practice2 -> "P2"
  Practice3 -> "P3"
  c         -> sessionCodeText c

-- | @name@, o con el primer número desde el 2 que no está en @taken@ («Leclerc 2»,
-- 2026-11-20 (ae)).
uniqueName :: [Text] -> Text -> Text
uniqueName taken name =
  case [n | n <- name : [name <> " " <> T.pack (show i) | i <- [2 :: Int ..]], n `notElem` taken] of
    n : _ -> n
    []    -> name

-- | Cuántas curvas caben en una Lap Comparison (2026-10-02 (b)).
comparisonLimit :: Int
comparisonLimit = 5

-- | Las curvas de una Lap Comparison con sus grupos.
data ComparisonPick = ComparisonPick
  { pickShown   :: [Text]
    -- ^ Las de la tarjeta, en su orden (la primera es la referencia), y después las
    -- de los grupos que caben.
  , pickGrouped :: [Text]
    -- ^ Las que entran por un grupo: las que se marcan «del grupo».
  , pickLeftOut :: [Text]
    -- ^ Las de los grupos que no caben, para avisarlo.
  }
  deriving stock (Eq, Show)

-- | Lo elegido en la tarjeta, @own@, con lo que destacan sus grupos. Un piloto de un grupo
-- que ya está en la tarjeta no añade nada (2026-11-20 (u)); los de la tarjeta no se caen
-- nunca, y los de los grupos llenan lo que quede hasta 'comparisonLimit' en el orden de los
-- grupos (2026-11-20 (p)).
comparisonPick :: [Text] -> [CardGroup] -> ComparisonPick
comparisonPick own gs = ComparisonPick (own ++ fits) fits out
  where
    extras      = filter (`notElem` own) (highlightedDrivers gs)
    (fits, out) = splitAt (max 0 (comparisonLimit - length own)) extras

-- | Lo que se elige en el formulario de un grupo («Nuevo grupo…» o editarlo).
data GroupDraft = GroupDraft
  { draftName    :: Text
  , draftDrivers :: [Text]
    -- ^ Siglas, en el orden en que se eligieron.
  , draftSession :: Maybe GroupSession
  }
  deriving stock (Eq, Show)

-- | Si el formulario deja crear o guardar: con algún piloto o con una sesión.
draftReady :: GroupDraft -> Bool
draftReady d = not (null (draftDrivers d)) || isJust (draftSession d)

-- | El formulario de editar un grupo arranca de lo que el grupo fija. Una 'groupSession'
-- ilegible arranca en «Ninguna».
groupDraft :: CardGroup -> GroupDraft
groupDraft g = GroupDraft (groupName g) (groupDrivers g) (readGroupSession =<< groupSession g)

-- | El nombre que se guarda: el escrito, sin espacios a los lados, o @auto@ si se dejó vacío.
chosenName :: Text -> Text -> Text
chosenName auto typed
  | T.null (T.strip typed) = auto
  | otherwise              = T.strip typed

-- | Un cambio en los grupos, pedido desde la fila de una tarjeta.
data GroupEdit
  = JoinGroup GroupId
    -- ^ La tarjeta entra en el grupo, al final de los suyos.
  | LeaveGroup GroupId
    -- ^ La tarjeta sale del grupo; el grupo se queda, aunque se quede vacío.
  | NewGroup GroupDraft
    -- ^ Un grupo nuevo, con la tarjeta dentro.
  | ChangeGroup GroupId GroupDraft
    -- ^ Lo que fija el grupo, en su sitio y con sus tarjetas.
  | DeleteGroup GroupId
    -- ^ El grupo sale de la lista y de todas las tarjetas.
  deriving stock (Eq, Show)

-- | Los grupos y las tarjetas de un layout tras un cambio pedido desde la tarjeta @wid@.
-- Uno nuevo lleva el primer id libre ('freshGroupId') y va al final de la lista; el nombre
-- de uno nuevo o editado no repite el de otro grupo ('uniqueName'). Un cambio sobre un
-- grupo que no está en la lista, o con un 'GroupDraft' que no fija nada ('draftReady'), no
-- cambia nada.
applyGroupEdit :: WidgetId -> GroupEdit -> ([CardGroup], [WidgetConfig]) -> ([CardGroup], [WidgetConfig])
applyGroupEdit wid edit (gs, ws) = case edit of
  JoinGroup g | known g    -> (gs, onCard (\m -> if g `elem` m then m else m ++ [g]))
  LeaveGroup g | known g   -> (gs, onCard (filter (/= g)))
  NewGroup d | draftReady d ->
    let g = fill d (map groupName gs) (CardGroup (freshGroupId gs) "" [] Nothing)
    in (gs ++ [g], onCard (++ [groupId g]))
  ChangeGroup g d | known g, draftReady d ->
    (map (\x -> if groupId x == g then fill d [groupName o | o <- gs, groupId o /= g] x else x) gs, ws)
  DeleteGroup g | known g  ->
    (filter ((/= g) . groupId) gs, map (\w -> w { widgetGroups = filter (/= g) (widgetGroups w) }) ws)
  _ -> (gs, ws)
  where
    known g  = any ((== g) . groupId) gs
    onCard f = map (\w -> if widgetId w == wid then w { widgetGroups = f (widgetGroups w) } else w) ws
    fill d taken g = g
      { groupName    = uniqueName taken (draftName d)
      , groupDrivers = draftDrivers d
      , groupSession = renderGroupSession <$> draftSession d
      }

-- | El primer @gN@, desde @g1@, que no es el id de ningún grupo.
freshGroupId :: [CardGroup] -> GroupId
freshGroupId gs =
  case [i | n <- [1 :: Int ..], let i = GroupId ("g" <> T.pack (show n)), i `notElem` map groupId gs] of
    i : _ -> i
    []    -> GroupId "g"

-- | En cuántas tarjetas está el grupo.
cardsInGroup :: GroupId -> [WidgetConfig] -> Int
cardsInGroup g = length . filter ((g `elem`) . widgetGroups)

-- | «1 tarjeta», «3 tarjetas».
cardCountText :: Int -> Text
cardCountText 1 = "1 tarjeta"
cardCountText n = T.pack (show n) <> " tarjetas"

-- | Un botón de «Sesión que suma».
data SessionChoice = SessionChoice
  { choiceCode :: SessionCode
  , choiceOpen :: Bool
    -- ^ Si se puede elegir: ya empezó y no es la que se ve.
  }
  deriving stock (Eq, Show)

-- | Los botones de «Sesión que suma» (2026-11-21 (f)): las sesiones del GP de la que se ve,
-- @viewed@, en el orden de la temporada; se eligen las que a @now@ (segundos desde 1970,
-- UTC) ya empezaron, salvo la que se ve. Sin sesión vista, o si la temporada no tiene su GP,
-- ninguno.
sessionChoices :: Int -> [SeasonRace] -> Maybe SessionKey -> [SessionChoice]
sessionChoices now races viewed = case viewed of
  Nothing -> []
  Just v  -> case find (any (sameGp v . ssnKey) . raceSessions) races of
    Nothing -> []
    Just r  -> [SessionChoice (skCode (ssnKey s)) (sessionStarted now s && ssnKey s /= v) | s <- raceSessions r]
  where
    sameGp v k = skYear k == skYear v && skRound k == skRound v

-- | La pista bajo los botones de «Sesión que suma»: de qué GP son, cuál es la que se ve y
-- cuáles no se han corrido aún. Sin botones, que no hay sesiones que sumar.
choicesHint :: Maybe SessionKey -> [SessionChoice] -> Text
choicesHint _ [] = "Sin el calendario del GP que se ve no hay sesiones que sumar."
choicesHint viewed cs = "Las de este GP." <> case parts of
  []    -> ""
  p : r -> " " <> capital p <> T.concat (map ("; " <>) r) <> "."
  where
    seen    = [c | Just v <- [viewed], c <- map choiceCode cs, c == skCode v]
    notRun  = [c | SessionChoice c False <- cs, c `notElem` seen]
    the c   = "la " <> sessionCodeText c
    parts   = ["la " <> sessionCodeText c <> " es la que ya se ve" | c <- seen]
           <> case notRun of
                []  -> []
                [c] -> [the c <> " aún no se ha corrido"]
                _   -> [T.intercalate ", " (map the (init notRun)) <> " y " <> the (last notRun) <> " aún no se han corrido"]
    capital t = T.toUpper (T.take 1 t) <> T.drop 1 t

-- | La etiqueta de sesión de un grupo que no destaca a ningún piloto (2026-11-20 (o)): el
-- código como en el nombre («P1», «Q»). «N años antes» lleva el año al que llega desde el año
-- que se ve («Q 2025»); sin sesión vista, «Q −1».
sessionTag :: Maybe Int -> GroupSession -> Text
sessionTag viewedYear = \case
  RelativeSession c             -> shortCode c
  OtherSeason (YearsBack n) _ c -> shortCode c <> maybe (" −" <> T.pack (show n)) (\y -> " " <> T.pack (show (y - n))) viewedYear
  OtherSeason (InYear y) _ c    -> shortCode c <> " " <> T.pack (show y)
  FixedSession k                -> shortCode (skCode k)

-- | Una opción del desplegable de la temporada (2026-11-21 (x)).
data SeasonOption = SeasonOption
  { soPick  :: Maybe (SeasonPick, Int)
    -- ^ 'Nothing', la que se ve; si no, la temporada y qué gran premio de ese año en el
    -- circuito (1, el primero o el único).
  , soLabel :: Text
  , soOpen  :: Bool
  }
  deriving stock (Eq, Show)

-- | El desplegable de la temporada, viendo el circuito @circuit@ (su nombre corto) del año
-- @year@, con los grandes premios de otros años en él, @rounds@: «Esta temporada», de 1 a 5
-- años antes, y cada año de antes, hasta 'Common.Session.firstCircuitYear', con su circuito.
-- Un año en el que no se corrió lo dice y no se elige; «N años antes» se elige siempre, porque
-- vale también para los demás circuitos, y dice si aquí no se corrió. Un año con dos grandes
-- premios en el circuito da una entrada por cada uno, con su nombre (2026-11-21 (ab)).
seasonOptions :: Text -> Int -> [CircuitRound] -> [SeasonOption]
seasonOptions circuit year rounds =
  SeasonOption Nothing "Esta temporada" True
    : concat [ entries (YearsBack n) (year - n) (yearsBefore n) (yearsBefore n <> unless (year - n) " · aquí no se corrió") True
             | n <- [1 .. 5] ]
    <> concat [ entries (InYear y) y (T.pack (show y)) (circuit <> " " <> T.pack (show y) <> unless y " · no se corrió") (ran y)
              | y <- [year - 1, year - 2 .. firstCircuitYear] ]
  where
    ran y = any ((== y) . crYear) rounds
    unless y t = if ran y then "" else t
    entries p y lead one open = case gpsOf rounds y of
      gps@(_ : _ : _) -> [SeasonOption (Just (p, i)) (lead <> " · " <> gpLabel i cr) True | (i, cr) <- zip [1 ..] gps]
      _               -> [SeasonOption (Just (p, 1)) one open]

-- | Los grandes premios de @rounds@ del año @y@, por ronda.
gpsOf :: [CircuitRound] -> Int -> [CircuitRound]
gpsOf rounds y = filter ((== y) . crYear) (sortOn crRound rounds)

-- | El nombre de un gran premio que hace el número @i@ en su año; sin nombre, «el 1.º».
gpLabel :: Int -> CircuitRound -> Text
gpLabel i cr = if T.null (crName cr) then "el " <> T.pack (show i) <> ".º" else crName cr

-- | La pista bajo el desplegable con otra temporada elegida, @pick@ (y qué gran premio de ese
-- año), viendo el circuito @circuit@ del año @year@: de qué año es aquí, y que con otro
-- circuito vale el de ese circuito. Con dos ese año, el nombre del elegido.
seasonHint :: Text -> Int -> [CircuitRound] -> (SeasonPick, Int) -> Text
seasonHint circuit year rounds (p, k)
  | any ((== target) . crYear) rounds =
      "De este circuito, " <> here <> ". Viendo otro circuito, la de ese circuito " <> elsewhere <> "."
  | otherwise =
      circuit <> " " <> showT target <> ": no se corrió. Mientras se vea " <> circuit
        <> ", el grupo no suma nada; viendo otro circuito, la de ese circuito " <> elsewhere <> " sí se corrió."
  where
    target = seasonYear year p
    here = case gpsOf rounds target of
      gps@(_ : _ : _) | cr : _ <- drop (k - 1) gps -> gpLabel k cr <> " " <> showT target
      _                                            -> circuit <> " " <> showT target
    elsewhere = case p of
      YearsBack n -> yearsBefore n
      InYear y    -> "en " <> showT y
    showT = T.pack . show

-- | El nombre del GP sin «Grand Prix» («Las Vegas»), como lo lleva el nombre de un grupo fijo.
gpShortName :: Text -> Text
gpShortName n = maybe n T.strip (T.stripSuffix "Grand Prix" n)

-- | Los pilotos de la fila «Otros» del formulario (2026-11-21 (f)): los de la sesión,
-- @session@, que no están entre los 22 de "Common.Pilots", en su orden, y después los que el
-- grupo ya fija, @fixed@, que tampoco están; sin repetir. Un coche sin siglas (su número) no
-- cuenta.
otherDrivers :: [Text] -> [Text] -> [Text]
otherDrivers fixed session = nub (filter outside session <> filter outside fixed)
  where
    outside c = not (T.null c) && not (T.all isDigit c) && isNothing (pilotInks c)

-- | Si @name@ es el nombre automático @auto@, tal cual o con el número que le pone
-- 'uniqueName' («Leclerc 2»): entonces, al editar el grupo, el nombre se rehace con lo que fija.
isAutoName :: Text -> Text -> Bool
isAutoName auto name = name == auto || maybe False numbered (T.stripPrefix (auto <> " ") name)
  where
    numbered n = not (T.null n) && T.all isDigit n
