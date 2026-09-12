{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widgets de Estadísticas Históricas — __dos__ widgets independientes
-- ('driverStatsWidget' y 'constructorStatsWidget'), uno por clasificación.
--
-- Los dos renderizan 'HistoricalStat' del dominio compartido ('Common.Types') y
-- los dos consumen @GET \/api\/historical@ en runtime vía 'Client.fetchJson' +
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
-- __El coste es que hay dos fetch del mismo endpoint__, con los 2 GET en serie a
-- Jolpica de @Handler.Historical.Context.fetchStats@ cada uno: 4 GET por carga de
-- página donde antes había 2. Aceptado a sabiendas y medido: 0.42–0.43 s por
-- respuesta, __plano__ entre llamadas consecutivas (el @Context@ siempre intenta el
-- fetch real y su cache es solo respaldo ante fallo). Los dos widgets montan a la
-- vez, así que el reloj de pared no se dobla; la carga sobre Jolpica sí. Lo cierra
-- el @Dynamic t SessionKey@ que la página debe compartir, y que implica un fetch
-- compartido. Decidido el 2026-08-26.
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

import           Client        (fetchJson)
import           Common.Format (formatFixed, formatTrimmed, noData)
import           Common.Route  (historicalPath)
import           Common.Types  (HistoricalStat (..), StatEntity (..))
import           Data.Text     (Text)
import           Reflex.Dom

-- | Estado del fetch de @\/api\/historical@. 'Failed' (no 'Error') para no chocar
-- con nombres de @base@\/@Prelude@ (mismo criterio que 'Widgets.Telemetry').
-- Compartido por los dos widgets del módulo.
data HState
  = Loading
  | Failed
  | Loaded [HistoricalStat]

-- | Clasificación de __pilotos__: @Clave | Piloto | Puntos | Victorias@.
--
-- Las dos proyecciones de la identidad —el acrónimo y el nombre completo— van en
-- __columnas distintas__ y no en una sola conmutable: es lo que la identidad
-- estructurada del 2026-07-28 permite, y el motivo de que
-- 'hsCode' y 'hsGivenName'\/'hsFamilyName' viajen por separado en vez de una
-- etiqueta ya compuesta.
driverStatsWidget :: MonadWidget t m => m ()
driverStatsWidget = divClass "widget widget--driver-stats" $ do
  divClass "widget__head" $ el "h2" $ text "Pilotos"
  pb    <- getPostBuild
  resp  <- fetchJson (historicalPath <$ pb)
  state <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ $ ffor state renderState
  where
    renderState :: DomBuilder t m => HState -> m ()
    renderState Loading = loadingStatus
    renderState Failed  = errorStatus
    renderState (Loaded stats) =
      elClass "table" "historical historical--drivers" $ do
        el "thead" $ el "tr" $
          mapM_ (el "th" . text) ["Clave", "Piloto", "Puntos", "Victorias"]
        el "tbody" $ mapM_ row (onlyEntity DriverStat stats)

    row :: DomBuilder t m => HistoricalStat -> m ()
    row s = el "tr" $ mapM_ (el "td" . text)
      [ hsCode s
      , hsGivenName s <> " " <> hsFamilyName s
      , pointsLabel s
      , winsLabel s
      ]

-- | Clasificación de __constructores__: @Constructor | Puntos | Victorias@.
--
-- Tres columnas y no cuatro: Jolpica no publica acrónimo ni nombre\/apellido para un
-- equipo, y la convención del DTO deja 'hsCode' con el @constructorId@
-- (@"red_bull"@), que es un identificador interno y no se muestra. La etiqueta es
-- 'hsFamilyName', el nombre legible.
constructorStatsWidget :: MonadWidget t m => m ()
constructorStatsWidget = divClass "widget widget--constructor-stats" $ do
  divClass "widget__head" $ el "h2" $ text "Constructores"
  pb    <- getPostBuild
  resp  <- fetchJson (historicalPath <$ pb)
  state <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ $ ffor state renderState
  where
    renderState :: DomBuilder t m => HState -> m ()
    renderState Loading = loadingStatus
    renderState Failed  = errorStatus
    renderState (Loaded stats) =
      elClass "table" "historical historical--constructors" $ do
        el "thead" $ el "tr" $
          mapM_ (el "th" . text) ["Constructor", "Puntos", "Victorias"]
        el "tbody" $ mapM_ row (onlyEntity ConstructorStat stats)

    row :: DomBuilder t m => HistoricalStat -> m ()
    row s = el "tr" $ mapM_ (el "td" . text)
      [ hsFamilyName s
      , pointsLabel s
      , winsLabel s
      ]

-- | Las filas de una sola clasificación, sacadas de la lista heterogénea que sirve
-- @\/api\/historical@. Puro, y el único punto del módulo donde se lee 'hsEntity'.
onlyEntity :: StatEntity -> [HistoricalStat] -> [HistoricalStat]
onlyEntity entity = filter ((== entity) . hsEntity)

-- | Los dos estados de no-dato del fetch, idénticos en los dos widgets. Son las
-- únicas piezas de DOM que se comparten: no toman fila, así que no arrastran el
-- problema de rango que el Haddock del módulo explica.
loadingStatus :: DomBuilder t m => m ()
loadingStatus = elClass "p" "status status--loading" $ text "Cargando…"

-- | Ver 'loadingStatus'.
errorStatus :: DomBuilder t m => m ()
errorStatus =
  elClass "p" "status status--error" $ text "Error al cargar /api/historical"

-- | Puntos de la fila, sin el @.0@ que sobra.
--
-- 'Common.Format.formatTrimmed' y no 'Common.Format.formatFixed' porque el decimal
-- es la excepción: Jolpica publica los puntos como 'Double' —la F1 reparte medios
-- puntos— pero casi siempre son enteros, y hasta el 2026-08-26 la columna mostraba
-- @393.0@. Un decimal es todo lo que el reglamento permite.
pointsLabel :: HistoricalStat -> Text
pointsLabel = formatTrimmed 1 . hsPoints

-- | Victorias de la fila, o una raya cuando Jolpica no las publica.
--
-- La raya __no es un cero__ y la distinción es la que 'Common.Types.hsWins' existe
-- para conservar: pintar @0@ afirmaría que la entidad no ganó ninguna carrera,
-- que es un dato que nadie dio. Con dato real no se ve —Jolpica publica @wins@
-- siempre, medido el 2026-08-24 y de nuevo el 2026-08-26—; el dummy de
-- @Handler.Historical.Context@ trae un caso a propósito para que la rama sea visible
-- sin editar código.
--
-- La raya viene de 'Common.Format.noData' y no de un literal local: es la misma que
-- emite la rama de no-finito del formateador, así que una victoria ausente y una
-- cifra imposible se ven igual —que es lo correcto, porque las dos son «nadie dio
-- esta cifra»— y el carácter se define una sola vez en el repo.
winsLabel :: HistoricalStat -> Text
winsLabel = maybe noData (formatFixed 0) . hsWins
