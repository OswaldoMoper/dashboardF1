{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget de Telemetría (categoría Telemetry).
--
-- Renderiza una tabla con los 'TelemetryPoint' del dominio compartido
-- ('Common.Types'). Consume @GET \/api\/telemetry@ en runtime
-- vía 'Client.fetchJson' + 'Common.Route.telemetryPath' (relativo, misma-origen:
-- el backend sirve el bundle y la API en el mismo puerto). Modela los tres
-- estados del fetch ('Loading' \/ 'Failed' \/ 'Loaded'); ya no hay datos dummy
-- locales (patrón espejo de 'Widgets.LiveTiming').
--
-- La lista es __multi-piloto__ (~1200 filas: la vuelta rápida de cada coche,
-- concatenada), así que hay un selector de piloto. Filtra __en cliente__, sin
-- volver a pedir nada, igual que los dos switchers de 'Widgets.Historical': el
-- endpoint ya acepta @?driver=@ desde el 2026-08-01, pero un fetch por clic
-- añadiría latencia visible a algo que es instantáneo sobre datos que ya están
-- en memoria. 'Common.Route.telemetryPathFor' queda como capacidad de la API
-- —para @curl@ y para el futuro widget de comparación—, no como mecanismo de
-- este widget.
--
-- Diferencia con 'Widgets.Historical', y es la razón de que aquí haya dos 'dyn_'
-- anidados: allí las opciones del switcher son un tipo cerrado y estático, así
-- que el switcher se monta __fuera__ del 'dyn_' del fetch. Aquí la lista de
-- pilotos __sale de la respuesta__, de modo que el switcher tiene que vivir
-- dentro. El fetch sigue sin re-dispararse: 'getPostBuild' está fuera de ambos y
-- el 'dyn_' interior solo re-pinta el @\<tbody\>@ al cambiar la selección.
module Widgets.Telemetry where

import           Client        (fetchJson)
import           Common.Format (formatFixed)
import           Common.Route  (telemetryPath)
import           Common.Types  (TelemetryPoint (..))
import           Data.List     (nub)
import           Data.Text     (Text)
import qualified Data.Text     as T
import           Reflex.Dom

-- | Estado del fetch de @\/api\/telemetry@. 'Failed' (no 'Error') para no chocar
-- con nombres de @base@\/@Prelude@ (mismo criterio que 'Widgets.LiveTiming').
data TState
  = Loading
  | Failed
  | Loaded [TelemetryPoint]

-- | Tabla de telemetría alimentada por @\/api\/telemetry@.
telemetryWidget :: MonadWidget t m => m ()
telemetryWidget = divClass "widget widget--telemetry" $ do
  divClass "widget__head" $ el "h2" $ text "Telemetry"
  pb    <- getPostBuild
  resp  <- fetchJson (telemetryPath <$ pb)
  state <- holdDyn Loading (ffor resp (maybe Failed Loaded))
  dyn_ (renderState <$> state)
  where
    renderState :: MonadWidget t m => TState -> m ()
    renderState Loading =
      elClass "p" "status status--loading" $ text "Cargando…"
    renderState Failed =
      elClass "p" "status status--error" $ text "Error al cargar /api/telemetry"
    renderState (Loaded points) = do
      selDyn <- driverSwitcher (driversOf points)
      dyn_ $ ffor selDyn $ \sel ->
        elClass "table" "telemetry" $ do
          el "thead" $ el "tr" $ mapM_ (el "th" . text) headers
          el "tbody" $ mapM_ row (filter (matchesDriver sel) points)

    -- 'Driver' encabeza la tabla porque la lista es __multi-piloto__: trae la
    -- vuelta rápida de varios coches concatenada y sin la etiqueta las filas no
    -- serían atribuibles (2026-07-31).
    headers :: [Text]
    headers =
      [ "Driver"
      , "Session Time"
      , "Distance"
      , "Speed"
      , "Throttle"
      , "Brake"
      , "Gear"
      , "RPM"
      ]

    -- Los decimales de cada magnitud salen de medir la respuesta real el
    -- 2026-08-26 (71 muestras de NOR), no de suponerlos: @sessionTime@ llega con 3
    -- decimales de resolución; @distance@ con los 17 dígitos de un @Double@ pero es
    -- una distancia en metros, así que uno basta; @speed@ es entera (98–324);
    -- @throttle@ es una __fracción__ 0–1 con 2 decimales de resolución (0.01, 0.48);
    -- y @brake@ trae __solo 0 o 1__, o sea un booleano metido en un 'Double' —lo que
    -- ya quedó anotado de él el 2026-08-19—.
    -- 'tpGear' y 'tpRpm' son 'Int' y no pasan por el formateador.
    row :: DomBuilder t m => TelemetryPoint -> m ()
    row p = el "tr" $ mapM_ (el "td" . text)
      [ tpDriver p
      , formatFixed 3 (tpSessionTime p)
      , formatFixed 1 (tpDistance p)
      , formatFixed 0 (tpSpeed p)
      , formatFixed 2 (tpThrottle p)
      , formatFixed 0 (tpBrake p)
      , T.pack (show (tpGear p))
      , T.pack (show (tpRpm p))
      ]

-- | Pilotos presentes en la respuesta, __en orden de aparición__ y sin repetir.
-- El orden lo fija el microservicio (los coches llegan en bloques contiguos), y
-- respetarlo hace que los botones no bailen entre cargas; ordenar
-- alfabéticamente sería inventar un criterio que los datos no traen.
driversOf :: [TelemetryPoint] -> [Text]
driversOf = nub . map tpDriver

-- | Si la muestra pasa la selección activa. 'Nothing' es "todos".
matchesDriver :: Maybe Text -> TelemetryPoint -> Bool
matchesDriver Nothing       _ = True
matchesDriver (Just driver) p = tpDriver p == driver

-- | Barra de botones con un piloto por acrónimo más un "All", que sostiene la
-- selección en un @Dynamic t (Maybe Text)@ (arranca en 'Nothing': la tabla
-- completa, que es el comportamiento previo al selector).
--
-- La lista de botones es __estática dentro de una carga__: se construye a partir
-- de los datos ya recibidos, así que hacer clic no la reconstruye. El acrónimo
-- es la unidad de selección porque es lo que 'TelemetryPoint' trae
-- (@tpDriver@); el @?driver=@ del endpoint habla en __números de coche__, y esa
-- diferencia de vocabulario es justo la razón por la que el filtro vive aquí y
-- no en un refetch.
driverSwitcher :: MonadWidget t m => [Text] -> m (Dynamic t (Maybe Text))
driverSwitcher drivers = divClass "driver-switcher" $ do
  allClick <- switcherButton "All"
  picks    <- mapM (\d -> fmap (Just d <$) (switcherButton d)) drivers
  holdDyn Nothing $ leftmost ((Nothing <$ allClick) : picks)

-- | Botón que emite un 'Event' al hacer click. Replicado aquí en lugar de
-- importado de 'Widgets.Historical': mismo criterio que allí, no acoplar dos
-- widgets entre sí por tres líneas de DOM. Lo que sí se comparte es la
-- __clase__ @switcher__btn@: los cuatro switchers del dashboard se
-- ven igual, así que la hoja los estila con una regla y no con cuatro.
switcherButton :: DomBuilder t m => Text -> m (Event t ())
switcherButton label = do
  (e, _) <- elClass' "button" "switcher__btn" $ text label
  pure (domEvent Click e)
