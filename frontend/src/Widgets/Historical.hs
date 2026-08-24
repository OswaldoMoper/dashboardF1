{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Estadísticas Históricas (categoría HistoricalStats).
--
-- Renderiza __dos tablas__ con los 'HistoricalStat' del dominio compartido
-- ('Common.Types'). Consume @GET \/api\/historical@ en runtime
-- vía 'Client.fetchJson' + 'Common.Route.historicalPath' (relativo, misma-origen:
-- el backend sirve el bundle y la API en el mismo puerto, con datos reales de
-- Jolpica). Modela los tres estados del fetch ('Loading' \/ 'Failed' \/ 'Loaded');
-- sin datos dummy locales.
--
-- La columna de etiqueta es conmutable ('LabelMode'): código \/ apellido \/ nombre
-- completo. El modo es __estado local del widget__ y se deriva de la identidad
-- estructurada que ya trae cada 'HistoricalStat' (2026-07-28),
-- así que conmutar __no re-dispara el fetch__: el @getPostBuild@ vive fuera del
-- 'dyn_' y solo se re-renderiza la tabla.
--
-- La lista que llega es __heterogénea__ (pilotos y constructores) y se parte aquí
-- por 'StatEntity', que es para lo que esa marca viaja
-- (2026-07-29). __Dos tablas y no un filtro__ desde 2026-08-24: aquella decisión
-- eligió «lista heterogénea con filtro» sin hoja de estilos, y con ella dos tablas
-- se distinguen de un vistazo mientras un control que esconde una de las dos no
-- informa de nada.
module Widgets.Historical where

import           Client        (fetchJson)
import           Common.Route  (historicalPath)
import           Common.Types  (HistoricalStat (..), StatEntity (..))
import           Data.List     (partition)
import           Data.Text     (Text)
import qualified Data.Text     as T
import           Reflex.Dom

-- | Estado del fetch de @\/api\/historical@. 'Failed' (no 'Error') para no chocar
-- con nombres de @base@\/@Prelude@ (mismo criterio que 'Widgets.Telemetry').
data HState
  = Loading
  | Failed
  | Loaded [HistoricalStat]

-- | Qué identidad del piloto se muestra en la columna de etiqueta.
data LabelMode
  = Code    -- ^ Acrónimo (@"VER"@).
  | Family  -- ^ Apellido (@"Verstappen"@).
  | Full    -- ^ Nombre completo (@"Max Verstappen"@).
  deriving (Eq, Show)

-- | Las dos tablas de estadísticas históricas alimentadas por @\/api\/historical@,
-- con selector de etiqueta.
historicalWidget :: MonadWidget t m => m ()
historicalWidget = divClass "widget widget--historical" $ do
  el "h2" $ text "Historical Stats"
  modeDyn <- labelSwitcher
  pb      <- getPostBuild
  resp    <- fetchJson (historicalPath <$ pb)
  state   <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ $ ffor (zipDyn modeDyn state) $ \(mode, st) -> renderState mode st
  where
    renderState :: DomBuilder t m => LabelMode -> HState -> m ()
    renderState _ Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState _ Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/historical"
    renderState mode (Loaded stats) = do
      let (drivers, constructors) = partition isDriver stats
      table mode "Pilotos" "Piloto" drivers
      table mode "Constructores" "Constructor" constructors

    isDriver :: HistoricalStat -> Bool
    isDriver s = hsEntity s == DriverStat

    -- | Una de las dos tablas, con su encabezado propio. La cabecera de la primera
    -- columna es lo único que cambia entre ellas: @Piloto@ o @Constructor@, que es
    -- lo que la columna @Entity@ decía fila a fila antes de que hubiera dos tablas.
    table
      :: DomBuilder t m
      => LabelMode -> Text -> Text -> [HistoricalStat] -> m ()
    table mode title firstHeader rows = do
      el "h3" $ text title
      elClass "table" "historical" $ do
        el "thead" $ el "tr" $
          mapM_ (el "th" . text) [firstHeader, "Puntos", "Victorias"]
        el "tbody" $ mapM_ (row mode) rows

    row :: DomBuilder t m => LabelMode -> HistoricalStat -> m ()
    row mode s = el "tr" $ mapM_ (el "td" . text)
      [ statLabel mode s
      , T.pack (show (hsPoints s))
      , winsLabel s
      ]

-- | Etiqueta de la fila según el modo activo. Derivada de los campos ya cargados;
-- ningún modo requiere volver a consultar la API.
--
-- Un constructor lleva __etiqueta fija__ (su nombre legible): Jolpica no publica
-- acrónimo ni nombre\/apellido para un equipo, y mostrar el @constructorId@
-- (@"red_bull"@) sería exponer un identificador interno. El 'LabelMode' solo
-- proyecta sobre las filas de piloto.
statLabel :: LabelMode -> HistoricalStat -> Text
statLabel mode s = case hsEntity s of
  ConstructorStat -> hsFamilyName s
  DriverStat      -> case mode of
    Code   -> hsCode s
    Family -> hsFamilyName s
    Full   -> hsGivenName s <> " " <> hsFamilyName s

-- | Victorias de la fila, o una raya cuando Jolpica no las publica.
--
-- La raya __no es un cero__ y la distinción es la que 'Common.Types.hsWins' existe
-- para conservar: pintar @0@ afirmaría que la entidad no ganó ninguna carrera,
-- que es un dato que nadie dio. Con dato real no se ve —Jolpica publica @wins@
-- siempre, medido el 2026-08-24—; el dummy de 'Handler.Historical.Context' trae un
-- caso a propósito para que la rama sea visible sin editar código.
winsLabel :: HistoricalStat -> Text
winsLabel = maybe "—" (T.pack . show) . hsWins

-- | Barra de botones que conmutan el modo de etiqueta. Sostiene el modo activo en
-- un @Dynamic t LabelMode@ (arranca en 'Code', la etiqueta previa al toggle).
-- Mismo patrón que 'Pages.Dashboard.layoutSwitcher'; el botón se replica aquí en
-- lugar de importarlo para no acoplar un widget a una página.
labelSwitcher :: MonadWidget t m => m (Dynamic t LabelMode)
labelSwitcher = divClass "label-switcher" $ do
  codeClick   <- switcherButton "Código"
  familyClick <- switcherButton "Apellido"
  fullClick   <- switcherButton "Nombre completo"
  holdDyn Code $ leftmost
    [ Code   <$ codeClick
    , Family <$ familyClick
    , Full   <$ fullClick
    ]

-- | Botón que emite un 'Event' al hacer click.
--
-- La clase es @switcher__btn@ y no @label-switcher__btn@ desde el 2026-08-21,
-- cuando el widget tenía __dos__ switchers y el de entidad reusaba este botón:
-- sus botones salían al DOM con el nombre del otro switcher y
-- @frontend\/dashboard.css@ los estilaba por un nombre que mentía
-- (2026-08-21 (c)). El nombre genérico __se conserva__
-- aunque hoy solo quede el 'labelSwitcher': la regla de la hoja es la misma que
-- estila los otros tres switchers de la página, y volver a un nombre por bloque
-- sería deshacer aquella unificación.
switcherButton :: DomBuilder t m => Text -> m (Event t ())
switcherButton label = do
  (e, _) <- elClass' "button" "switcher__btn" $ text label
  pure (domEvent Click e)
