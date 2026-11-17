-- | Lo puro de 'Widgets.Comparison': qué se enseña y qué aviso lleva según lo que
-- devuelve cada petición.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo, y un import de Reflex aquí lo deja sin compilar.
module Widgets.Comparison.Helper
  ( CState (..)
  , step
  , shownComparison
  , Refresh (..)
  , refreshOf
  ) where

import           Common.Types (LapComparison)

-- | Estado del fetch de @\/api\/comparison@. 'Failed' (no 'Error') para no
-- chocar con nombres de @base@\/@Prelude@, mismo criterio que los otros widgets.
data CState
  = Loading
  | Failed
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
-- único caso en que no hay nada que conservar — que no llegara nunca nada.
--
-- 'CState' no gana un cuarto constructor de \"recargando\": el estado de la
-- __petición__ vive aparte, en 'Refresh', justamente para que no se mezcle con
-- el de los __datos__. Meterlos en el mismo tipo obligaría a que cada
-- combinación fuera un constructor.
step :: Maybe LapComparison -> CState -> CState
step (Just c) _          = Loaded c
step Nothing  (Loaded c) = Loaded c
step Nothing  _          = Failed

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

-- | La respuesta traducida a estado de petición.
refreshOf :: Maybe LapComparison -> Refresh
refreshOf = maybe LastFailed (const Idle)
