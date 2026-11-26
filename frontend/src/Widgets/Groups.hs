{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}

-- | La fila de grupos de una tarjeta, bajo su cabecera y solo en «Editar layout»
-- (2026-11-20 (j), (o); 2026-11-21 (f), (i)): una etiqueta por grupo, cuyo nombre abre el
-- formulario para editarlo (con «Borrar el grupo» dentro) y cuya ✕ saca esta tarjeta, y
-- «+ Grupo» (los grupos del layout con casillas, y «Nuevo grupo…»). Sacar y borrar preguntan en
-- la propia fila, que ocupa entera mientras pregunta.
--
-- La fila no cambia nada: devuelve cada cambio como un 'GroupEdit', y quien la monta lo
-- aplica ('Common.Group.applyGroupEdit'). La lista y el formulario van fijos sobre
-- la ventana, junto a su botón, porque la tarjeta recorta lo que se sale de ella.
module Widgets.Groups
  ( GroupContext (..)
  , cardExtras
  , groupRow
  , groupDots
  , rowTitle
  , pill
  ) where

import           Client                    (fetchJson)
import           Common.Group              (GroupDraft (..), GroupEdit (..),
                                            GroupSession (..),
                                            SeasonOption (..), SeasonPick (..),
                                            SessionChoice (..), addedSessions,
                                            autoName,
                                            cardCountText, cardGroups,
                                            cardsInGroup, choicesHint,
                                            chosenName, draftReady,
                                            gpShortName, groupDraft,
                                            highlightedDrivers, isAutoName,
                                            otherDrivers,
                                            readGroupSession,
                                            seasonHint,
                                            seasonOptions, sessionChoices,
                                            sessionTag)
import           Common.Comparison         (GroupPick (..))
import           Common.Pilots             (Inks (..), inksOr, pilotTeams,
                                            unknownInk)
import           Common.Route              (driversPathFor, seasonPath)
import           Common.Session            (CircuitRound, SeasonRace (..),
                                            SeasonSession (..),
                                            SessionKey (..), latestStartedKey,
                                            renderSessionKey, sessionCodeText,
                                            sessionQuery)
import           Common.Types              (CardGroup (..), DriverEntry (..),
                                            GroupId,
                                            HistoricalStat (..), Layout (..),
                                            LayoutId (..), SessionInfo,
                                            StatEntity (..), WidgetConfig (..),
                                            WidgetId, WidgetType (..))
import           Control.Applicative       ((<|>))
import           Control.Monad             (forM_)
import           Control.Monad.IO.Class    (liftIO)
import           Data.List                 (find)
import           Data.Maybe                (fromMaybe, isJust, listToMaybe)
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Data.Time.Clock           (getCurrentTime)
import           Data.Time.Clock.POSIX     (utcTimeToPOSIXSeconds)
import qualified GHCJS.DOM                 as DOM (currentWindowUnchecked)
import qualified GHCJS.DOM.DOMRectReadOnly as DOM (getBottom, getLeft, getTop)
import qualified GHCJS.DOM.Element         as DOM (getBoundingClientRect)
import qualified GHCJS.DOM.Types           as DOM (Element (..), IsElement)
import qualified GHCJS.DOM.Window          as Window (getInnerHeight,
                                                      getInnerWidth)
import           Language.Javascript.JSaddle (JSM, liftJSM)
import           Reflex.Dom
import           Widgets.Card              (CardExtras (..))
import           Widgets.Historical        (HState (..), historicalState)

-- | Lo que la fila de una tarjeta lee de la página.
data GroupContext t = GroupContext
  { gcEditing :: Dynamic t Bool
  , gcGroups  :: Dynamic t [CardGroup]
    -- ^ Los grupos del layout.
  , gcCards   :: Dynamic t [WidgetConfig]
    -- ^ Las tarjetas del layout, con sus grupos.
  , gcSession :: Dynamic t (Maybe SessionKey)
    -- ^ La sesión elegida; 'Nothing' es «Ahora».
  , gcLive    :: Dynamic t (Maybe SessionInfo)
    -- ^ La sesión de la que habla el directo, para saber cuál se ve con «Ahora».
  , gcViewed  :: Dynamic t (Maybe SessionKey)
    -- ^ La sesión que se ve, también con «Ahora»; 'Nothing' si no se sabe.
  , gcRounds  :: Dynamic t [CircuitRound]
    -- ^ Los grandes premios de otros años en el circuito que se ve ('Common.Session.sameCircuit').
  }

-- | El nombre con el que la fila nombra a la tarjeta, o 'Nothing' si no lleva fila
-- (Constructores, 2026-11-21 (h)).
rowTitle :: WidgetType -> Maybe Text
rowTitle = \case
  LiveTiming       -> Just "Live Timing"
  LapComparison    -> Just "Lap Comparison"
  TyreStrategy     -> Just "Tyre Strategy"
  HistoricalStats  -> Just "Pilotos"
  ConstructorStats -> Nothing
  Custom           -> Nothing

-- | Dónde está el botón que abrió algo, y cuánto mide la ventana, en px.
data Place = Place
  { placeLeft   :: Double
  , placeTop    :: Double
  , placeBottom :: Double
  , placeWidth  :: Int
  , placeHeight :: Int
  }
  deriving (Eq, Show)

-- | Qué tiene abierto la fila.
data RowUi
  = Idle
  | Picking Place
  | Asking Ask
  | Editing (Maybe GroupId) Place
    -- ^ El formulario: 'Nothing' para uno nuevo.
  deriving (Eq, Show)

data Ask = AskLeave GroupId | AskDelete GroupId
  deriving (Eq, Show)

-- | Lo que sale de pintar la fila: abrir o cerrar algo, o un cambio en los grupos.
data RowOut = SetUi RowUi | Apply GroupEdit

-- | La fila de la tarjeta @wid@, que se llama @title@. Devuelve cada cambio que se pide.
groupRow :: MonadWidget t m => Text -> WidgetId -> GroupContext t -> m (Event t GroupEdit)
groupRow title wid ctx = mdo
  mine <- holdUniqDyn (myGroups wid ctx)
  allG <- holdUniqDyn (listed <$> gcGroups ctx <*> gcCards ctx)
  year <- holdUniqDyn (fmap skYear <$> gcViewed ctx)
  ui   <- foldDyn step Idle $ leftmost
            [ SetUi Idle <$ ffilter not (updated (gcEditing ctx))
            , outs
            ]
  outs <- elDynAttr "div" (rowAttrs <$> gcEditing ctx) $
            switchHold never =<< dyn (rowView title ctx <$> year <*> mine <*> allG <*> ui)
  pure (fmapMaybe applied outs)
  where
    listed gs ws =
      [ (g, cardsInGroup (groupId g) ws, maybe False ((groupId g `elem`) . widgetGroups) (find ((== wid) . widgetId) ws))
      | g <- gs ]
    step (SetUi u) _           = u
    step (Apply _) (Picking p) = Picking p
    step (Apply _) _           = Idle
    applied (Apply e) = Just e
    applied _         = Nothing
    rowAttrs on = "class" =: "group-row" <> (if on then mempty else "hidden" =: "")

-- | Los grupos de la tarjeta @wid@, en su orden ('Common.Group.cardGroups').
myGroups :: Reflex t => WidgetId -> GroupContext t -> Dynamic t [CardGroup]
myGroups wid ctx = mine <$> gcGroups ctx <*> gcCards ctx
  where
    mine gs ws = maybe [] (cardGroups (Layout (LayoutId "") ws gs)) (find ((== wid) . widgetId) ws)

-- | Lo que los grupos le ponen a la tarjeta @wid@, que se llama @title@: sus puntos junto al
-- título ('groupDots'), su fila bajo la cabecera ('groupRow'), los pilotos que destacan
-- (2026-11-20 (h), (v)) y las sesiones que suman (2026-11-20 (i)).
cardExtras :: MonadWidget t m => Text -> WidgetId -> GroupContext t -> CardExtras t m (Event t GroupEdit)
cardExtras title wid ctx = CardExtras
  { cardBeside    = groupDots wid ctx
  , cardUnder     = groupRow title wid ctx
  , cardHighlight = highlightedDrivers <$> myGroups wid ctx
  , cardSessions  = (\v rs gs -> (v, addedSessions v rs gs)) <$> gcViewed ctx <*> gcRounds ctx <*> myGroups wid ctx
  , cardPicks     = (\v rs gs -> [GroupPick (groupDrivers g) (listToMaybe (addedSessions v rs [g])) | g <- gs])
                      <$> gcViewed ctx <*> gcRounds ctx <*> myGroups wid ctx
  }

-- | Fuera de «Editar layout», los grupos de la tarjeta junto a su título (2026-11-20 (k),
-- 2026-11-21 (j)): un punto por piloto, partido en sus dos tintas, juntos los de cada grupo
-- y con un hueco entre grupos; un grupo sin pilotos, su etiqueta de sesión. Sus nombres, al
-- pasar el ratón. Sin grupos, nada.
groupDots :: MonadWidget t m => WidgetId -> GroupContext t -> m ()
groupDots wid ctx = do
  mine <- holdUniqDyn (myGroups wid ctx)
  year <- holdUniqDyn (fmap skYear <$> gcViewed ctx)
  dyn_ (dots <$> gcEditing ctx <*> mine <*> year)
  where
    dots editing gs year
      | editing || null gs = blank
      | otherwise =
          elAttr "span" ("class" =: "group-dots" <> "title" =: ("Grupos: " <> T.intercalate " · " (map groupName gs))) $
            mapM_ (elClass "span" "group-dots__group" . marks year) gs
    marks year g = case (groupDrivers g, readGroupSession =<< groupSession g) of
      ([], Just s) -> elClass "span" "group-session-tag" $ text (sessionTag year s)
      (ds, _)      -> mapM_ dot ds
    dot c = elClass "span" "group-dot" $ do
      let Inks team helmet = inksOr unknownInk c
      elAttr "span" ("style" =: ("background:" <> team)) blank
      elAttr "span" ("style" =: ("background:" <> helmet)) blank

-- | La fila según lo que tiene abierto. @mine@ son los grupos de la tarjeta y @allG@ los del
-- layout, con cuántas tarjetas tiene cada uno y si esta está en él.
rowView :: MonadWidget t m
        => Text -> GroupContext t -> Maybe Int -> [CardGroup] -> [(CardGroup, Int, Bool)] -> RowUi -> m (Event t RowOut)
rowView title ctx year mine allG ui = case ui of
  Asking (AskLeave g) -> ask (\x -> "¿Sacar «" <> title <> "» de «" <> groupName x <> "»?") "Sacar" False g (LeaveGroup g)
  Asking (AskDelete g) -> ask (\x -> "¿Borrar «" <> groupName x <> "»? " <> capitalOut (countOf g) <> ".")
                              "Borrar" True g (DeleteGroup g)
  _ -> do
    chips <- mapM chip mine
    add   <- addButton
    pop   <- case ui of
      Picking p         -> picker p
      Editing mg p      -> groupForm title ctx (groupOf =<< mg) p
      _                 -> pure never
    pure (leftmost (chips <> [add, pop]))
  where
    groupOf g = (\(x, _, _) -> x) <$> find (\(x, _, _) -> groupId x == g) allG
    countOf g = maybe 0 (\(_, n, _) -> n) (find (\(x, _, _) -> groupId x == g) allG)
    outOf n | n == 1    = "sale de esta tarjeta"
            | otherwise = "sale de las " <> cardCountText n
    capitalOut n = "S" <> T.drop 1 (outOf n)

    ask question yes danger g edit = case groupOf g of
      Nothing -> pure (SetUi Idle <$ never)
      Just x  -> elClass "span" "group-ask" $ do
        elClass "span" "group-ask__text" $ text (question x)
        (y, _) <- elClass' "button" (if danger then "group-btn group-btn--danger" else "group-btn group-btn--yes") $ text yes
        (n, _) <- elClass' "button" "group-btn" $ text "No"
        pure (leftmost [Apply edit <$ domEvent Click y, SetUi Idle <$ domEvent Click n])

    chip g = elClass "span" "group-chip" $ do
      (o, _) <- elClass' "button" "group-chip__open" $ do
        groupMarks year g
        text (groupName g)
      (x, _) <- elAttr' "button" ("class" =: "group-chip__out" <> "title" =: ("Sacar de «" <> groupName g <> "»")) $
                  text "✕"
      at <- performEvent (liftJSM (measure (_element_raw o)) <$ domEvent Click o)
      pure (leftmost [SetUi . Editing (Just (groupId g)) <$> at, SetUi (Asking (AskLeave (groupId g))) <$ domEvent Click x])

    addButton = do
      (b, _) <- elClass' "button" "group-add" $ text "+ Grupo"
      at <- performEvent (liftJSM (measure (_element_raw b)) <$ domEvent Click b)
      pure ((\p -> SetUi (if null allG then Editing Nothing p else Picking p)) <$> at)

    picker p = do
      close <- backdrop
      picks <- elAttr "div" ("class" =: "group-pop group-menu" <> "style" =: placeStyle 280 p) $ do
        elClass "p" "group-menu__caption" $ text ("Meter «" <> title <> "» en un grupo")
        rows <- mapM pickRow allG
        divClass "group-menu__sep" blank
        new <- item "group-menu__item" (text "+ Nuevo grupo…")
        pure (rows <> [SetUi (Editing Nothing p) <$ new])
      pure (leftmost ((SetUi Idle <$ close) : picks))

    pickRow (g, n, inside) = do
      (b, _) <- elClass' "button" "group-menu__item" $ do
        elClass "span" "group-menu__box" $ text (if inside then "☑" else "☐")
        groupMarks year g
        text (groupName g)
        elClass "span" "group-menu__note" $ text (cardCountText n)
      pure ((if inside then SetUi (Asking (AskLeave (groupId g))) else Apply (JoinGroup (groupId g))) <$ domEvent Click b)

    item cls body = do
      (b, _) <- elClass' "button" cls body
      pure (domEvent Click b)

-- | Lo que marca a un grupo delante de su nombre: una pastilla por piloto con su pareja, o,
-- si no destaca a ninguno, la etiqueta de su sesión (2026-11-20 (o)).
groupMarks :: DomBuilder t m => Maybe Int -> CardGroup -> m ()
groupMarks year g = case (groupDrivers g, readGroupSession =<< groupSession g) of
  ([], Just s) -> elClass "span" "group-session-tag" $ text (sessionTag year s)
  (ds, _)      -> mapM_ pill ds

-- | La pastilla de un piloto: la tinta de su equipo y la de su casco; quien no está en la
-- tabla, en gris (2026-11-21 (f)).
pill :: DomBuilder t m => Text -> m ()
pill c = elClass "span" "group-pill" $ do
  let Inks team helmet = inksOr unknownInk c
  elAttr "span" ("style" =: ("background:" <> team)) blank
  elAttr "span" ("style" =: ("background:" <> helmet)) blank

-- | Una capa transparente bajo lo que se abrió: pulsarla lo cierra.
backdrop :: DomBuilder t m => m (Event t ())
backdrop = do
  (e, _) <- elClass' "div" "group-backdrop" blank
  pure (domEvent Click e)

-- | El formulario de un grupo (2026-11-21 (f), (g)): los 22 por equipo, la sesión que suma
-- entre las del GP que se ve, y el nombre, que se pone solo hasta que se escribe uno. «Crear»
-- (o «Guardar») está apagado mientras no fija ningún piloto ni sesión. Al editar un grupo,
-- arranca de lo que fija; su nombre se rehace con lo que se elija solo si era el automático
-- ('Common.Group.isAutoName'), y lleva «Borrar el grupo», que pregunta en la fila.
groupForm :: MonadWidget t m => Text -> GroupContext t -> Maybe CardGroup -> Place -> m (Event t RowOut)
groupForm title ctx existing p = do
  elClass "div" "group-backdrop group-backdrop--form" blank
  elAttr "div" ("class" =: "group-pop group-form" <> "style" =: placeStyle 340 p) $ mdo
    pb      <- getPostBuild
    asked   <- fetchJson (seasonPath <$ pb)
    season  <- holdDyn [] (fromMaybe [] <$> asked)
    start   <- liftIO getCurrentTime
    hist    <- historicalState (gcSession ctx)
    let nowSec   = floor (utcTimeToPOSIXSeconds start) :: Int
        viewed   = (\chosen ss live -> chosen <|> latestStartedKey nowSec ss live) <$> gcSession ctx <*> season <*> gcLive ctx
        surnames = (\case
                      Loaded st -> [(hsCode s, hsFamilyName s) | s <- st, hsEntity s == DriverStat]
                      _         -> []) <$> hist
        surname  = (\ns c -> fromMaybe c (lookup c ns)) <$> surnames
        gpName   = (\ss k -> maybe (renderSessionKey k) (gpShortName . raceName) (find (hasKey k) ss)) <$> season
        year     = (\v ss -> maybe (firstYear ss) skYear v) <$> viewed <*> season
        circuit  = (\gp v -> maybe "" gp v) <$> gpName <*> viewed
        initial  = maybe (GroupDraft "" [] Nothing) groupDraft existing
    el "h4" $ text $ case existing of
      Nothing -> "Nuevo grupo con «" <> title <> "»"
      Just g  -> "Editar «" <> groupName g <> "»"
    elClass "span" "group-form__label" $ text "Pilotos que destaca"
    toggles <- mapM (team drivers) pilotTeams
    gridAsk <- fetchJson (driversPathFor . sessionQuery <$> tag (current (gcSession ctx)) pb)
    grid    <- holdDyn [] (codesOf <$> gridAsk)
    others  <- holdUniqDyn (otherDrivers (draftDrivers initial) <$> grid)
    extra   <- switchHold never =<< dyn (othersRow drivers <$> others)
    drivers <- foldDyn toggleDriver (draftDrivers initial) (leftmost (extra : concat toggles))
    elClass "span" "group-form__label" $ text "Sesión que suma"
    choices <- holdUniqDyn (sessionChoices nowSec <$> season <*> viewed)
    picked  <- divClass "group-form__sessions" $ do
      none <- codeButton (constDyn True) ((== Nothing) <$> session) (text "Ninguna")
      rest <- switchHold never =<< dyn (codeButtons code other <$> choices)
      pure (leftmost [Nothing <$ none, rest])
    code    <- holdDyn (codeOf (draftSession initial)) picked
    elClass "span" "group-form__label" $ text "Temporada"
    options <- holdUniqDyn (seasonOptions <$> circuit <*> year <*> gcRounds ctx)
    other   <- holdDyn (pickOf (draftSession initial)) =<< switchHold never =<< dyn (seasonSelect other <$> options)
    session <- holdDyn (draftSession initial) (updated (combine <$> code <*> other))
    elClass "div" "group-form__hint" $
      dynText (hint <$> viewed <*> choices <*> circuit <*> year <*> gcRounds ctx <*> code <*> other)
    elClass "span" "group-form__label" $ text "Nombre"
    let auto  = autoName <$> year <*> surname <*> gpName <*> drivers <*> session
        ready = (\ds s -> draftReady (GroupDraft "" ds s)) <$> drivers <*> session
        shown = (\r a -> if r then a else "") <$> ready <*> auto
        firstAuto = autoName <$> year <*> surname <*> gpName <*> pure (draftDrivers initial) <*> pure (draftSession initial)
        follows = maybe (pure True) (\g -> isAutoName <$> firstAuto <*> pure (groupName g)) existing
        free    = (&&) <$> follows <*> (not <$> typed)
    name <- inputElement $ def
      & inputElementConfig_initialValue .~ maybe "" groupName existing
      & inputElementConfig_setValue .~ leftmost [gate (current free) (updated shown), tag (current shown) (ffilter id (updated free))]
      & initialAttributes .~ ("class" =: "group-form__name" <> "type" =: "text")
    typed   <- holdDyn False (True <$ _inputElement_input name)
    elClass "div" "group-form__hint" $ text "Se pone solo con lo que elijas; puedes cambiarlo."
    (cancel, save, del) <- divClass "group-form__buttons" $ do
      d <- case existing of
        Nothing -> pure never
        Just g  -> do
          (b, _) <- elClass' "button" "group-btn group-btn--danger group-form__delete" $ text "Borrar el grupo"
          pure (SetUi (Asking (AskDelete (groupId g))) <$ domEvent Click b)
      (c, _) <- elClass' "button" "group-btn" $ text "Cancelar"
      (s, _) <- elDynAttr' "button" (saveAttrs <$> ready) $ text (maybe "Crear grupo" (const "Guardar") existing)
      pure (domEvent Click c, domEvent Click s, d)
    let draft = GroupDraft <$> (chosenName <$> auto <*> value name) <*> drivers <*> session
        edit d = maybe (NewGroup d) (\g -> ChangeGroup (groupId g) d) existing
    pure $ leftmost
      [ SetUi Idle <$ cancel
      , del
      , Apply . edit <$> gate (draftReady <$> current draft) (tag (current draft) save)
      ]
  where
    hasKey k r = any ((== k) . ssnKey) (raceSessions r)
    codesOf :: Maybe [DriverEntry] -> [Text]
    codesOf = maybe [] (map deCode)
    -- La fila «Otros», al final y solo si la sesión los trae (2026-11-21 (f)).
    othersRow drivers cs
      | null cs   = pure never
      | otherwise = leftmost <$> team drivers ("Otros", cs)
    firstYear ss = case concatMap raceSessions ss of
      s : _ -> skYear (ssnKey s)
      []    -> 0
    toggleDriver c ds
      | c `elem` ds = filter (/= c) ds
      | otherwise   = ds <> [c]
    saveAttrs r = "class" =: "group-btn group-btn--primary" <> (if r then mempty else "disabled" =: "")

    team drivers (name, codes) = divClass "group-form__team" $ do
      elClass "span" "group-form__team-name" $ text name
      mapM (\c -> do
               (b, _) <- elDynAttr' "button" (tagAttrs c <$> drivers) $ pill c >> text c
               pure (c <$ domEvent Click b)) codes
    tagAttrs c ds = "class" =: ("group-tag" <> (if c `elem` ds then " group-tag--on" else "")) <> "type" =: "button"

    -- Con otra temporada, todas se eligen: la que se ve y las que aún no se corren, de otro año
    -- sí se corrieron.
    codeButtons code other cs = do
      es <- mapM (\c -> (Just (choiceCode c) <$) <$>
                   codeButton ((\o -> choiceOpen c || isJust o) <$> other) ((== Just (choiceCode c)) <$> code)
                     (text (sessionCodeText (choiceCode c)))) cs
      pure (leftmost es)
    codeOf = \case
      Just (RelativeSession c) -> Just c
      Just (OtherSeason _ _ c) -> Just c
      _                        -> Nothing
    pickOf = \case
      Just (OtherSeason p k _) -> Just (p, k)
      _                        -> Nothing
    combine c o = case (c, o) of
      (Nothing, _)           -> Nothing
      (Just x, Nothing)      -> Just (RelativeSession x)
      (Just x, Just (pk, k)) -> Just (OtherSeason pk k x)
    hint v cs gp y rs c o = case (c, o) of
      (Just _, Just pk) -> seasonHint gp y rs pk
      _                 -> choicesHint v cs

    -- El desplegable de la temporada (2026-11-21 (x)), nativo; arranca en lo elegido y devuelve
    -- lo que elige el usuario.
    seasonSelect other opts = do
      start <- sample (current other)
      -- Las opciones reciben su @value@ después de montarse: escrito antes, no casa con
      -- ninguna y el desplegable queda vacío.
      mounted <- delay 0 =<< getPostBuild
      let cfg = def
            & selectElementConfig_initialValue .~ pickKey start
            & selectElementConfig_setValue .~ (pickKey start <$ mounted)
            & selectElementConfig_elementConfig . elementConfig_initialAttributes
                .~ ("class" =: "car-selector__select group-form__season")
      (sel, _) <- selectElement cfg $ forM_ opts $ \o ->
        elAttr "option" ("value" =: pickKey (soPick o) <> (if soOpen o then mempty else "disabled" =: "disabled")) $
          text (soLabel o)
      pure (fmapMaybe (\k -> lookup k [(pickKey (soPick o), soPick o) | o <- opts]) (_selectElement_change sel))
    pickKey = \case
      Nothing                 -> "esta"
      Just (YearsBack k, gp) -> "antes-" <> T.pack (show k) <> nth gp
      Just (InYear y, gp)    -> "año-" <> T.pack (show y) <> nth gp
    nth gp = if gp > 1 then "-" <> T.pack (show gp) else ""

    codeButton open on body = do
      (b, _) <- elDynAttr' "button" (codeAttrs <$> open <*> on) body
      pure (gate (current open) (domEvent Click b))
    codeAttrs open on =
      "class" =: ("group-code" <> (if on then " group-code--on" else ""))
        <> "type" =: "button"
        <> (if open then mempty else "disabled" =: "")

-- | Mide dónde está el botón @e@ y cuánto mide la ventana.
measure :: DOM.IsElement e => e -> JSM Place
measure e = do
  r  <- DOM.getBoundingClientRect e
  l  <- DOM.getLeft r
  t  <- DOM.getTop r
  b  <- DOM.getBottom r
  w  <- DOM.currentWindowUnchecked
  iw <- Window.getInnerWidth w
  ih <- Window.getInnerHeight w
  pure (Place l t b iw ih)

-- | Fijo junto a su botón: debajo si el botón está en la mitad de arriba de la ventana y
-- encima si no, con lo que no quepa en scroll; y sin salirse por la derecha (@width@ es el
-- ancho de lo que se abre).
placeStyle :: Int -> Place -> Text
placeStyle width (Place l t b iw ih) =
  "left:" <> px (max 8 (min (round l) (iw - width - 8))) <> ";" <> vertical
  where
    vertical
      | t < fromIntegral ih / 2 = "top:" <> px (round b + 6) <> ";max-height:" <> px (ih - round b - 22)
      | otherwise               = "bottom:" <> px (ih - round t + 6) <> ";max-height:" <> px (round t - 22)
    px :: Int -> Text
    px n = T.pack (show n) <> "px"
