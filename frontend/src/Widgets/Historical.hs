{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}

-- | Widgets de Estadísticas Históricas — __dos__ widgets independientes
-- ('driverStatsWidget' y 'constructorStatsWidget'), uno por clasificación.
--
-- Los dos renderizan 'HistoricalStat' del dominio compartido ('Common.Types') y
-- los dos consumen @GET \/api\/historical@ en runtime vía 'Client.fetchJsonWith' +
-- 'Common.Route.historicalPath' (relativo, misma-origen: el backend sirve el bundle
-- y la API en el mismo puerto, con datos reales de Jolpica). Cada uno modela los
-- tres estados del fetch ('Loading' \/ 'Failed' \/ 'Loaded'); sin datos dummy
-- locales.
--
-- __Dos widgets y no dos tablas en uno__ desde 2026-08-26. Hasta entonces una sola
-- función pintaba las dos tablas dentro del mismo @div.widget@: se distinguían
-- —eso lo arregló 2026-08-24— pero compartían encabezado y sitio en la rejilla, así
-- que no se podían colocar por separado. Ahora cada clasificación es un
-- 'Common.Types.WidgetType' propio y el 'Common.Types.Layout' las coloca aparte.
--
-- __El coste es que hay dos fetch del mismo endpoint__, y los dos widgets montan a la vez.
-- Cuando el backend no tiene nada guardado que servir ('Handler.Historical.Helper.keptToday'),
-- los junta en una sola bajada a Jolpica, los 2 GET en serie de
-- @Handler.Historical.Context.fetchStats@ (@App.envHistoricalFlights@). Decidido el 2026-08-26.
--
-- La lista que llega es __heterogénea__ (pilotos y constructores), así que cada
-- widget la filtra por 'StatEntity' y se queda con la suya: la marca sigue siendo lo
-- único que permite el reparto, porque @fetchStats@ concatena las dos clasificaciones
-- en una respuesta (2026-07-29). Tener dos widgets __no__ retira
-- esa necesidad.
--
-- __Sin toggle de etiqueta__ desde 2026-08-26: la tabla de pilotos pinta la clave y
-- el nombre completo __siempre__, en dos columnas. El @LabelMode@ de 2026-07-28
-- conmutaba entre tres proyecciones de la identidad estructurada cuando lo que se
-- quiere ver son dos de ellas a la vez, y un control que esconde una de las dos no
-- informa de nada.
--
-- __Los dos widgets no comparten esqueleto a propósito.__ Factorizar la tarjeta y la
-- tabla pediría pasar la función de fila como parámetro, y eso es un tipo de rango
-- superior porque la fila se pinta dentro del 'dyn_', bajo un @DomBuilder@ distinto
-- del de la tarjeta. Este módulo se escribe __ciego__ y no se compila hasta su
-- @nix build .#frontend@, y el precio de equivocarse en la generalización
-- es un fallo que solo aparece bajo GHCJS. Diez líneas repetidas salen más baratas.
module Widgets.Historical where

import           Client                    (fetchJsonWith, stillFor)
import           Common.Pilots             (highlightEdge, highlightFill)
import           Common.Route              (historicalPathFor)
import           Common.Session            (SessionKey, noStandingsNotice,
                                            sessionQuery)
import           Common.Shown              (historicalRetrySeconds)
import           Common.Types              (HistoricalStat (..),
                                            StatEntity (..))
import           Data.Text                 (Text)
import           Reflex.Dom
import           Widgets.Card              (CardExtras (..))
import           Widgets.Historical.Helper (onlyEntity, pointsLabel,
                                            positionLabel, winsLabel)

-- | Estado del fetch de @\/api\/historical@. 'Failed' (no 'Error') para no chocar
-- con nombres de @base@\/@Prelude@.
-- Compartido por los dos widgets del módulo.
data HState
  = Loading
  | Failed
  | Loaded [HistoricalStat]

-- | Clasificación de __pilotos__: @Pos | Clave | Piloto | Puntos | Victorias@.
--
-- Las dos proyecciones de la identidad —el acrónimo y el nombre completo— van en
-- __columnas distintas__ y no en una sola conmutable: es lo que la identidad
-- estructurada del 2026-07-28 permite, y el motivo de que
-- 'hsCode' y 'hsGivenName'\/'hsFamilyName' viajen por separado en vez de una
-- etiqueta ya compuesta.
--
-- Lleva lo que quien la monta le pone dentro ('Widgets.Card.CardExtras'): junto al título,
-- bajo la cabecera (lo que devuelve es lo que devuelve la tarjeta) y las filas que destaca.
driverStatsWidget :: MonadWidget t m => Dynamic t (Maybe SessionKey) -> CardExtras t m a -> m a
driverStatsWidget session extras = divClass "widget widget--driver-stats" $ do
  divClass "widget__head" $ do
    el "h2" $ text "Pilotos"
    cardBeside extras
  out <- cardUnder extras
  marked <- holdUniqDyn (cardHighlight extras)
  state <- historicalState session
  dyn_ (renderState <$> marked <*> state)
  pure out
  where
    renderState :: DomBuilder t m => [Text] -> HState -> m ()
    renderState _ Loading = loadingStatus
    renderState _ Failed  = errorStatus
    renderState marked (Loaded stats) = case onlyEntity DriverStat stats of
      []   -> emptyStatus
      rows -> elClass "table" "historical historical--drivers" $ do
        el "thead" $ el "tr" $
          mapM_ (el "th" . text) ["Pos", "Clave", "Piloto", "Puntos", "Victorias"]
        el "tbody" $ mapM_ (row marked) rows

    row :: DomBuilder t m => [Text] -> HistoricalStat -> m ()
    row marked s = elAttr "tr" (lit highlightFill) $
      mapM_ (\(i, v) -> elAttr "td" (if i == (0 :: Int) then lit highlightEdge else mempty) (text v)) $ zip [0 ..]
        [ positionLabel s
        , hsCode s
        , hsGivenName s <> " " <> hsFamilyName s
        , pointsLabel s
        , winsLabel s
        ]
      where
        lit f
          | hsCode s `elem` marked = "style" =: f (hsCode s)
          | otherwise              = mempty

-- | Clasificación de __constructores__: @Pos | Constructor | Puntos | Victorias@.
--
-- Sin clave ni nombre: Jolpica no publica acrónimo ni nombre\/apellido para un
-- equipo, y la convención del DTO deja 'hsCode' con el @constructorId@
-- (@"red_bull"@), que es un identificador interno y no se muestra. La etiqueta es
-- 'hsFamilyName', el nombre legible.
constructorStatsWidget :: MonadWidget t m => Dynamic t (Maybe SessionKey) -> m ()
constructorStatsWidget session = divClass "widget widget--constructor-stats" $ do
  divClass "widget__head" $ el "h2" $ text "Constructores"
  state <- historicalState session
  dyn_ $ ffor state renderState
  where
    renderState :: DomBuilder t m => HState -> m ()
    renderState Loading = loadingStatus
    renderState Failed  = errorStatus
    renderState (Loaded stats) = case onlyEntity ConstructorStat stats of
      []   -> emptyStatus
      rows -> elClass "table" "historical historical--constructors" $ do
        el "thead" $ el "tr" $
          mapM_ (el "th" . text) ["Pos", "Constructor", "Puntos", "Victorias"]
        el "tbody" $ mapM_ row rows

    row :: DomBuilder t m => HistoricalStat -> m ()
    row s = el "tr" $ mapM_ (el "td" . text)
      [ positionLabel s
      , hsFamilyName s
      , pointsLabel s
      , winsLabel s
      ]

-- | El estado de @\/api\/historical@ de la sesión de la página: se pide al montarse y con
-- cada cambio de sesión, que vuelve a 'Loading'; la respuesta de una sesión que ya no es
-- la elegida se tira. Tras un fallo se vuelve a pedir a los 'historicalRetrySeconds',
-- mientras siga elegida la misma sesión, y el error se queda hasta que llega algo.
historicalState :: MonadWidget t m => Dynamic t (Maybe SessionKey) -> m (Dynamic t HState)
historicalState session = mdo
  pb       <- getPostBuild
  again    <- delay (fromIntegral historicalRetrySeconds) (fmapMaybe failedFor answered)
  let asked = leftmost
        [ updated session
        , tag (current session) pb
        , stillFor (current session) ((\k -> (k, k)) <$> again)
        ]
  answered <- fetchJsonWith ((\k -> (k, historicalPathFor (sessionQuery k))) <$> asked)
  let resp = stillFor (current session) answered
  holdDyn Loading (leftmost [Loading <$ updated session, maybe Failed Loaded <$> resp])
  where
    failedFor (k, answer) = maybe (Just k) (const Nothing) answer

-- | Los dos estados de no-dato del fetch, idénticos en los dos widgets. Son las
-- únicas piezas de DOM que se comparten: no toman fila, así que no arrastran el
-- problema de rango que el Haddock del módulo explica.
loadingStatus :: DomBuilder t m => m ()
loadingStatus = elClass "p" "status status--loading" $ text "Cargando…"

-- | Ver 'loadingStatus'.
errorStatus :: DomBuilder t m => m ()
errorStatus =
  elClass "p" "status status--error" $ text "Error al cargar /api/historical"

-- | La clasificación sin filas. Ver 'loadingStatus'.
emptyStatus :: DomBuilder t m => m ()
emptyStatus = elClass "p" "status status--empty" $ text noStandingsNotice
