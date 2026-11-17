-- | Lo puro de 'Widgets.Live': de qué sesión es lo que se enseña y el indicador
-- @● Live@ de las cabeceras.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo, y un import de Reflex aquí lo deja sin compilar.
module Widgets.Live.Helper
  ( sessionOf
  , stateOf
  , indicatorOf
  ) where

import           Common.Origin (Sourced (..))
import           Common.Shown  (Indicator, Poll (..), indicatorFrom)
import           Common.Types  (LiveTable (..), SessionInfo (..),
                                SessionState (..), StateReading (..),
                                sessionInProgress)

-- | De qué sesión son las filas que se están enseñando, si se sabe.
--
-- Los dos 'Nothing' que atraviesa significan cosas distintas y aquí se juntan a
-- propósito: no haber recibido nada todavía y haber recibido una tabla que no
-- nombra su sesión se ven igual en la banda, porque en los dos casos no hay sesión
-- que enseñar. Es el contrapunto de 'Widgets.LiveTiming.Helper.liveStateOf', que se
-- queda con las filas y descarta esto.
sessionOf :: Poll (Sourced LiveTable) -> Maybe SessionInfo
sessionOf p = liveSession . srcValue =<< pollShown p

-- | En qué punto está esa sesión, si alguien lo dijo o el calendario lo permitió
-- deducir. Atraviesa los mismos dos 'Nothing' que 'sessionOf' y uno más —el de la
-- sesión que no trae estado—, y los tres se pintan igual porque los tres son «no se
-- sabe».
stateOf :: Poll (Sourced LiveTable) -> Maybe StateReading
stateOf p = siState =<< sessionOf p

-- | El indicador de la cabecera a partir de lo que ya hay en la mano: la
-- procedencia y el último intento salen del refresco, y si hay carrera sale de la
-- sesión que la tabla trae al lado.
--
-- __Es este módulo quien lo junta y no 'Common.Shown'__, que no conoce el
-- dominio: allí la sesión rodando y la finalizada entran como 'Bool' y aquí es
-- donde está el 'Common.Types.LiveTable' del que sacarlas.
indicatorOf :: Poll (Sourced LiveTable) -> Indicator
indicatorOf p = indicatorFrom (sessionInProgress state) (state == Just SessionFinalised) p
  where
    state = srState <$> stateOf p
