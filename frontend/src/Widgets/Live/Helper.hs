-- | Lo puro de 'Widgets.Live': de qué sesión es lo que se enseña, el indicador @● Live@ de
-- las cabeceras y los avisos de la banda.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo, y un import de Reflex aquí lo deja sin compilar.
module Widgets.Live.Helper
  ( sessionOf
  , stateOf
  , indicatorOf
  , missingTitle
  , liveAside
  ) where

import           Common.Origin  (Sourced (..))
import           Common.Session (SessionKey, notFoundNotice, renderSessionKey)
import           Common.Shown   (Indicator (..), Poll (..), indicatorFrom)
import           Common.Types   (LapProgress (..), LiveTable (..),
                                 SessionInfo (..), SessionState (..),
                                 StateReading (..), sessionInProgress,
                                 sessionRolling)
import           Control.Monad  (guard)
import           Data.Maybe     (isNothing)
import           Data.Text      (Text)
import qualified Data.Text      as T

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
--
-- @chosen@ dice si la página tiene una sesión elegida: con ella, filas y sin rodar, es una
-- sesión ya corrida ('Common.Shown.indPast', 2026-11-18 (k)).
indicatorOf :: Bool -> Poll (Sourced LiveTable) -> Indicator
indicatorOf chosen p =
  (indicatorFrom running (state == Just SessionFinalised) p) {indPast = chosen && hasRows && not running}
  where
    state = srState <$> stateOf p
    running = sessionInProgress state
    hasRows = maybe False (not . null . liveRows . srcValue) (pollShown p)

-- | El aviso de la banda para una sesión elegida que no existe, con su clave
-- (2026-11-17 (e)): solo si el refresco dio @404@ y no enseña nada. Si no, vacío.
missingTitle :: Maybe SessionKey -> Poll a -> Text
missingTitle (Just k) p
  | pollNotFound p && isNothing (pollShown p) = notFoundNotice <> ": " <> renderSessionKey k
missingTitle _ _ = ""

-- | Lo que dice el aviso de la banda tras «EN DIRECTO:» con una sesión elegida mientras el
-- directo rueda ('Common.Types.sessionRolling'; 2026-11-13 (f)): gran premio, sesión y,
-- en carrera, la vuelta (@Las Vegas Grand Prix · Race · vuelta 30/50@). Recibe el refresco
-- del directo con su diferido. 'Nothing' sin sesión elegida o sin directo rodando.
liveAside :: Maybe SessionKey -> Poll (Sourced LiveTable) -> Maybe Text
liveAside chosen live = do
  _ <- chosen
  s <- sessionOf live
  guard (sessionRolling (srState <$> siState s))
  pure (T.intercalate " · " (filter (not . T.null) [siMeeting s, siName s, maybe "" lap (siLaps s)]))
  where
    lap l = "vuelta " <> T.pack (show (lpCurrent l)) <> "/" <> T.pack (show (lpTotal l))
