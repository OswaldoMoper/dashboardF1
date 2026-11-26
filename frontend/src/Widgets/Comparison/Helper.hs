-- | Lo puro de 'Widgets.Comparison': qué se enseña y qué aviso lleva según lo que
-- devuelve cada petición, y las reglas de la tarjeta con el directo.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo, y un import de Reflex aquí lo deja sin compilar.
module Widgets.Comparison.Helper
  ( CState (..)
  , step
  , shownComparison
  , Refresh (..)
  , refreshOf
    -- * La tarjeta con el directo
  , liveInput
  , notRunOf
  , liveFor
  , gridFor
  , liveEntriesFor
  , markedRule
  , shownState
  , shownGap
  , dueGap
  , noLapNote
    -- * La parrilla de los selectores
  , indexedGrid
  , carAt
  , positionOf
  , positionFor
  , carOf
  , driverLabel
    -- * El lienzo
  , View (..)
  , rowHeightNow
  , canvasDrawn
  , seriesOf
  , rowSeries
    -- * Las vueltas de otras sesiones
  , groupLaps
  , Item (..)
  , shownItemsOf
  , rowItems
  , edgeNotes
  , leftOutLabel
  ) where

import           Common.Account        (retryDue)
import           Common.Chart          (axisRange, chartHeight, frontierCells)
import           Common.Comparison     (Added (..), Axis, Baseline,
                                        ChartType (..), Curve (..),
                                        LapChoice (..), LiveCard (..),
                                        LiveEntry (..), Pair (..),
                                        WithGroups (..), addedCars, axisValues,
                                        chartTypeTraces, frontSeries,
                                        lapChoicesOffered, lapFor,
                                        liveComparison, liveDrivers,
                                        liveNoLapFor, missingReference,
                                        noLapFor, pairWith)
import           Common.ComparisonCard (ChartMode, rowHeight)
import           Common.Group          (fromTag)
import           Common.Origin         (Origin (..), Source, Sourced (..))
import           Common.Session        (SessionKey, notRunShown,
                                        renderSessionKey)
import           Common.Shown          (Fetched (..), Poll (..))
import           Common.Traces         (Channel, TraceRows (..), traceChannels,
                                        tracesHeight)
import           Common.Types          (ComparisonEntry (..), DriverEntry (..),
                                        LapComparison (..), LiveTable (..),
                                        LiveTimingRow, SessionInfo,
                                        TelemetryGap (..))
import           Control.Monad         (guard)
import           Data.List             (find)
import           Data.Map              (Map)
import qualified Data.Map              as Map
import           Data.Maybe            (isNothing, listToMaybe)
import           Data.Text             (Text)
import qualified Data.Text             as T

-- | Estado del fetch de @\/api\/comparison@. 'Failed' (no 'Error') para no
-- chocar con nombres de @base@\/@Prelude@, mismo criterio que los otros widgets.
data CState
  = Loading
  | Failed
  | NotFound
    -- ^ La sesión pedida no existe: un @404@ y nada que conservar.
  | Loaded LapComparison
  deriving (Eq, Show)

-- | Cómo avanza el estado con cada respuesta. __Es la pieza que impide el
-- parpadeo__, y por eso el widget usa @foldDyn@ y no el @holdDyn@ de los otros
-- cuatro: el estado depende del anterior.
--
-- Con @holdDyn (maybe Failed Loaded)@ cada clic habría llevado el widget a
-- 'Failed' o directamente a repintar desde cero, borrando el gráfico que se
-- estaba mirando justo cuando se pide el siguiente. Aquí el estado __solo
-- avanza__: una recarga fallida conserva lo mostrado, y 'Failed' queda para el
-- único caso en que no hay nada que conservar — que no llegara nunca nada. Un @404@
-- es un fallo más, salvo sin nada que conservar: entonces es 'NotFound'.
--
-- 'CState' no gana un constructor de \"recargando\": el estado de la
-- __petición__ vive aparte, en 'Refresh', justamente para que no se mezcle con
-- el de los __datos__. Meterlos en el mismo tipo obligaría a que cada
-- combinación fuera un constructor.
step :: Fetched LapComparison -> CState -> CState
step (Got c)    _          = Loaded c
step _          (Loaded c) = Loaded c
step Absent     _          = NotFound
step NotFetched _          = Failed

-- | La comparación que el gráfico está pintando, si hay alguna. Es lo que
-- 'Widgets.Comparison.carSelector' necesita para marcar el par activo, y sale del
-- __estado__ y no de la respuesta a propósito ('Widgets.Comparison.comparisonWidget'):
-- tras una recarga fallida 'step' conserva el gráfico anterior, y los selectores
-- tienen que seguir señalando ése y no quedarse en blanco.
shownComparison :: CState -> Maybe LapComparison
shownComparison (Loaded c) = Just c
shownComparison _          = Nothing

-- | Qué le pasó a la última petición, al margen de los datos que se muestran.
--
-- Existe por una consecuencia directa de 'step': al conservar lo anterior ante
-- una recarga fallida, el fallo __no se vería en ninguna parte__. 'LastFailed'
-- es lo que impide que el widget enseñe datos viejos como si fueran los que se
-- acaban de pedir.
data Refresh
  = Idle        -- ^ Nada en vuelo y lo último que llegó, llegó bien.
  | InFlight
  | LastFailed  -- ^ La recarga falló; se conserva lo anterior.
  deriving (Eq, Show)

-- | La respuesta traducida a estado de petición: un @404@ es un fallo más.
refreshOf :: Fetched LapComparison -> Refresh
refreshOf (Got _) = Idle
refreshOf _       = LastFailed

-- | La fuente, la sesión y las filas del directo que se enseña, para 'liveCardStep';
-- 'Nothing' mientras se espera el retraso o antes de la primera respuesta buena.
liveInput :: Maybe Int -> Poll (Sourced LiveTable) -> Maybe (Maybe Source, Maybe SessionInfo, [LiveTimingRow])
liveInput (Just _) _ = Nothing
liveInput Nothing p =
  (\s -> (srcSource s, liveSession (srcValue s), liveRows (srcValue s))) <$> pollShown p

-- | Si la tarjeta enseña «Sesión aún sin correr» en lugar del cuerpo y la leyenda: con
-- el criterio y en el momento de 'Widgets.LiveTiming.liveStateOf', pasado el retraso
-- y con la tabla de la página ('Common.Session.notRunShown'), no con la comparación.
notRunOf :: Bool -> Maybe Int -> Poll (Sourced LiveTable) -> Bool
notRunOf chosen wait p = isNothing wait && notRunShown chosen (liveRows . srcValue <$> pollShown p)

-- | El directo de la tarjeta con el tipo elegido: solo el tipo 1 va en directo; los
-- demás pintan FastF1 ('Offline').
liveFor :: LiveCard -> ChartType -> LiveCard
liveFor c SectorDelta = c
liveFor _ _           = Offline

-- | Los pilotos de los desplegables: los del directo por número, o la parrilla de FastF1.
gridFor :: Maybe (Maybe SessionInfo, [LiveTimingRow]) -> [DriverEntry] -> [DriverEntry]
gridFor (Just (_, rows)) _ = liveDrivers rows
gridFor Nothing grid       = grid

-- | La comparación del directo de los dos coches elegidos, cada uno con su vuelta: la
-- regla o su excepción ('Common.Comparison.lapFor').
liveEntriesFor
  :: Maybe (Maybe SessionInfo, [LiveTimingRow]) -> (Maybe Text, Maybe Text) -> LapChoice
  -> (Maybe LapChoice, Maybe LapChoice) -> Maybe [LiveEntry]
liveEntriesFor (Just (s, rows)) (Just r, Just o) rule (a, b) =
  Just (liveComparison s rows [(r, lapFor offered rule a), (o, lapFor offered rule b)])
  where
    offered = lapChoicesOffered s
liveEntriesFor _ _ _ _ = Nothing

-- | La regla marcada en la cabecera: con FastF1, la más rápida; en directo, la regla si
-- se ofrece ('Common.Comparison.lapFor').
markedRule :: Maybe (Maybe SessionInfo) -> LapChoice -> LapChoice
markedRule Nothing _     = FastestLap
markedRule (Just s) rule = lapFor (lapChoicesOffered s) rule Nothing

-- | Lo que se pinta: la comparación del directo si la hay, o lo último de FastF1.
shownState :: Maybe [LiveEntry] -> CState -> CState
shownState (Just es) _ =
  Loaded MkLapComparison
    {lcEntries = map leEntry es, lcSamples = 0, lcNotice = "", lcTelemetry = Nothing, lcCut = Nothing}
shownState Nothing s   = s

-- | Lo que falta de la telemetría de lo que se enseña de FastF1, solo en los modos con
-- trazas: los demás no la usan.
shownGap :: ChartType -> CState -> Maybe TelemetryGap
shownGap t s
  | chartTypeTraces t = lcTelemetry =<< shownComparison s
  | otherwise         = Nothing

-- | Si en el minuto @minute@ (desde 1970, UTC) toca volver a pedir la comparación por lo
-- que falta de su telemetría ('Common.Account.retryDue'), y no se pidió ya por esa misma
-- hora.
dueGap :: (Maybe TelemetryGap, Maybe Text) -> Int -> Maybe TelemetryGap
dueGap (gap, done) minute = do
  g <- gap
  guard (Just (tgRetryAt g) /= done && retryDue minute g)
  pure g

-- | El tooltip de un desplegable cuyo coche sale sin barras, en directo o con FastF1.
noLapNote :: Maybe [LiveEntry] -> CState -> Text -> Maybe Text
noLapNote (Just es) _ car = liveNoLapFor car es
noLapNote Nothing s car   = noLapFor car =<< shownComparison s

-- | La parrilla indexada por __posición__, que es la clave de los dos
-- 'dropdown'.
--
-- __La clave es la posición y no el número de coche, y no es un detalle:__
-- 'dropdown' ordena las opciones por la clave del 'Map' (su propia fuente lo
-- reconoce con un @TODO@), así que un @'Map' 'Text'@ sobre @deNumber@ daría el
-- orden lexicográfico @1, 10, 11, 12, 14, 16, 3, 44…@ y un @'Map' 'Int'@ del
-- número obligaría a parsear @deNumber@ y a decidir qué hacer con lo que no
-- parsee. Con la posición, el orden del 'Map' __es__ el que dio FastF1 —medido
-- el 2026-08-07: @1 3 12 16 44 6 63 30 27 41 5 10 18 14 43 31 23 55 87 81 11
-- 77@, que en una carrera cargada es el de clasificación— y que
-- la decisión del 2026-08-06 registra como información del servicio:
-- reordenar aquí la destruiría.
--
-- El precio es que la selección no lleva el número encima y hay que buscarlo
-- ('carAt') contra la misma parrilla.
indexedGrid :: [DriverEntry] -> Map Int DriverEntry
indexedGrid = Map.fromList . zip [0 ..]

-- | El número de coche de una posición, o 'Nothing' si la parrilla no la tiene.
--
-- Devuelve el __número__ y no el 'DriverEntry' entero porque es lo único que
-- sale del widget: el acrónimo es para mirar, el número es lo que la API
-- entiende (2026-08-01).
carAt :: Map Int DriverEntry -> Int -> Maybe Text
carAt indexed = fmap deNumber . flip Map.lookup indexed

-- | La posición que ocupa un número de coche en la parrilla, o 'Nothing' si no
-- está. Es 'carAt' al revés, y hace falta porque el widget habla dos idiomas: el
-- 'dropdown' se maneja por posición ('indexedGrid') y la respuesta trae números.
--
-- Recorre la lista en vez de mantener un índice inverso: son 22 entradas y se
-- consulta dos veces por respuesta.
positionOf :: Map Int DriverEntry -> Text -> Maybe Int
positionOf indexed car =
  fst <$> find ((== car) . deNumber . snd) (Map.toAscList indexed)

-- | La posición a la que hay que llevar un selector, dada la parrilla vigente y
-- lo que el gráfico está pintando. 'Nothing' —y por tanto ningún @setValue@— en
-- los dos casos en que mover el selector sería mentir: todavía no hay
-- comparación, o el coche del que habla __no está en la parrilla__.
--
-- El segundo caso no es hipotético: con el microservicio apagado la comparación
-- es el dummy (@16@ y @1@) y la parrilla puede ser la real de otra sesión
-- cacheada. Que el selector se quede donde estaba y el @#n@ de 'lapLabel'
-- discrepe es justo la señal de que lo pintado no es lo pedido.
positionFor
  :: (LapComparison -> Maybe Text)
  -> Map Int DriverEntry
  -> Maybe LapComparison
  -> Maybe Int
positionFor car indexed shown = positionOf indexed =<< (car =<< shown)

-- | El número del coche @i@ de la comparación (0, la referencia), si lo hay.
carOf :: Int -> LapComparison -> Maybe Text
carOf i = fmap ceCar . listToMaybe . drop i . lcEntries

-- | La etiqueta de una opción: @\"1 · NOR — McLaren\"@.
--
-- Los tres campos de 'Common.Types.DriverEntry', y @deTeam@ entró al DTO en la
-- 2026-08-06 precisamente para esto. El __número__ va delante porque es lo que
-- permite cotejar de un vistazo lo elegido con el @#n@ que 'lapLabel' pinta en
-- la cabecera del gráfico: sin él no habría forma de ver que la respuesta
-- corresponde a lo pedido.
--
-- Con @deTeam@ vacío se omite el guion largo en vez de dejarlo colgando. Vacío
-- es lo que devuelve un microservicio que no resolvió el equipo, y también lo
-- que da @.:? … .!= \"\"@ ante uno anterior a que el campo existiera
-- (2026-08-06).
driverLabel :: DriverEntry -> Text
driverLabel d
  | T.null (deTeam d) = core
  | otherwise         = core <> " — " <> deTeam d
  where
    core = deNumber d <> " · " <> deCode d

-- | Lo que el usuario eligió para pintar la comparación: el tipo, la base de la Δ, el
-- eje de las trazas, si van sus fronteras, las siglas del piloto que pulsó en la
-- leyenda para llevarlo al frente y las gráficas de las trazas.
data View = View
  { vType      :: ChartType
  , vBase      :: Baseline
  , vAxis      :: Axis
  , vFrontiers :: Bool
  , vFront     :: Maybe Text
  , vCharts    :: [Channel]
  }
  deriving Eq

-- | El alto de la fila de fronteras pintada: el de su modo si hay fronteras que
-- nombrar, 0 si no hay fila.
rowHeightNow :: ChartMode -> View -> CState -> Double
rowHeightNow m v (Loaded c) | not (null (frontierCells (rowSeries v c))) = rowHeight m
rowHeightNow _ _ _          = 0

-- | La Δ de la fila de fronteras y la banda: en las trazas, la del par ('seriesOf'); en
-- el tipo 1, la del coche al frente ('Common.Comparison.frontSeries').
rowSeries :: View -> LapComparison -> [Double]
rowSeries v
  | chartTypeTraces (vType v) = seriesOf (vBase v)
  | otherwise                 = frontSeries (vBase v) (vFront v)

-- | El alto sin crecer del lienzo pintado: el de las trazas ('Common.Traces.tracesHeight')
-- o el de la gráfica del tipo 1 ('Common.Chart.chartHeight'). 'Nothing' sin comparación,
-- o con trazas que no se pintan (el aviso de la referencia sin vuelta en su lugar).
-- Con un aviso en lugar de la gráfica del tipo 1 no hay lienzo que medir.
canvasDrawn :: View -> CState -> Maybe Double
canvasDrawn v (Loaded c)
  | not (chartTypeTraces (vType v)) = Just chartHeight
  | Nothing <- missingReference (vBase v) c
  , _ : _ : _ <- lcEntries c = Just (tracesHeight (TraceRows (traceChannels (vType v) (vCharts v))))
canvasDrawn _ _ = Nothing

-- | La serie que se pinta con una base: la Δ del coche que no es la base
-- ('Common.Comparison.pairWith'), o @[]@.
seriesOf :: Baseline -> LapComparison -> [Double]
seriesOf b = maybe [] pairDelta . pairWith b

-- | Lo que se pinta de la petición de la vuelta de unos pilotos, por siglas, en la sesión de
-- un grupo: las entradas de esos pilotos, en su orden. Nada si la petición falla o si lo que
-- llega es el ejemplo, que no es de esa sesión.
groupLaps :: SessionKey -> [Text] -> Fetched (Sourced LapComparison) -> [(SessionKey, ComparisonEntry)]
groupLaps k codes (Got s)
  | srcOrigin s /= Just Sample = [(k, e) | e <- lcEntries (srcValue s), ceDriver e `elem` codes]
groupLaps _ _ _ = []

-- | Una fila de la comparación tal como se enseña: la clave con la que se lleva al frente
-- ('Common.Comparison.curveKey'), su nombre en la leyenda y en la cabecera, si la añade un
-- grupo, el número que lleva la cabecera (ninguno en la vuelta de otra sesión) y su coche.
data Item = Item
  { itKey    :: Text
  , itLegend :: Text
  , itHead   :: Text
  , itGroup  :: Bool
  , itCar    :: Text
  , itEntry  :: ComparisonEntry
  }
  deriving (Eq, Show)

-- | Las filas de lo que se pinta en el orden en que se enseñan: los coches de la tarjeta y
-- detrás lo que añaden los grupos, en su orden ('Common.Comparison.wgAdded'): un coche,
-- «VER, del grupo»; la vuelta de otra sesión, «LEC · P3, del grupo», si llegó (@laps@). La
-- etiqueta de la sesión es la de los grupos, vista desde @viewed@. Sin comparación, ninguna.
shownItemsOf :: Maybe SessionKey -> WithGroups -> [(SessionKey, ComparisonEntry)] -> CState -> [Item]
shownItemsOf viewed g laps (Loaded c) = map own [e | e <- lcEntries c, ceCar e `notElem` addedCars g] <> concatMap slot (wgAdded g)
  where
    own e = Item (ceDriver e) (ceDriver e) (ceDriver e) False (ceCar e) e
    slot (AddedCar n _) = [Item (ceDriver e) (ceDriver e <> ", del grupo") (ceDriver e) True n e | e <- lcEntries c, ceCar e == n]
    slot (AddedLap k code) =
      [ Item (code <> " · " <> renderSessionKey k) (name <> ", del grupo") name True "" e
      | (k', e) <- laps, k' == k, ceDriver e == code
      , let name = code <> " · " <> sessionLabel viewed k ]
shownItemsOf _ _ _ _ = []

-- | Las filas de tiempo según el tipo: una por curva (2026-11-21 (ad)). Los tipos con
-- trazas pintan la referencia y el primero de los demás (2026-11-23 (c)), así que solo esas
-- dos; con una sola gráfica que no es la velocidad (el segundo argumento,
-- Common.ComparisonCard.chartFirstFor), todos los coches de la tarjeta (2026-11-24); el
-- resto, todas.
rowItems :: ChartType -> Bool -> [Item] -> [Item]
rowItems t first items
  | chartTypeTraces t, first = [it | it <- items, not (itGroup it)]
  | chartTypeTraces t        = take 2 [it | it <- items, not (itGroup it)]
  | otherwise                = items

-- | Las curvas que se salen del eje de 'Common.Comparison.axisValues' (2026-11-23 (h)), en su
-- orden: si se pasan por arriba y su último valor, el que se escribe en el borde.
edgeNotes :: [Curve] -> [(Bool, Double)]
edgeNotes curves =
  [ (maximum d > hi, last d)
  | cv <- curves, let d = cvDelta cv, not (null d), any (\x -> x > hi || x < lo) d ]
  where
    (lo, hi) = axisRange (axisValues curves)

-- | Cómo se nombra en la leyenda lo de un grupo que no cabe: sus siglas, o con la sesión.
leftOutLabel :: Maybe SessionKey -> Added -> Text
leftOutLabel _ (AddedCar _ code)      = code
leftOutLabel viewed (AddedLap k code) = code <> " · " <> sessionLabel viewed k

-- | La etiqueta de la sesión de un grupo vista desde la que se ve ('Common.Group.fromTag');
-- sin saber cuál se ve, su clave.
sessionLabel :: Maybe SessionKey -> SessionKey -> Text
sessionLabel viewed k = maybe (renderSessionKey k) (`fromTag` k) viewed
