-- | Cliente OpenF1 — tipos crudos compartidos y la línea del registro de peticiones
-- (lógica pura). 'Answer' y 'answerOf' son los de 'Handler.PublicApi.Helper'.
--
-- Modela los campos de OpenF1 que consume más de un módulo de 'Handler.Live':
-- 'Of1Driver' (@/drivers@, identidad y equipo del piloto) y 'Of1Stint' (@/stints@),
-- y su cruce 'assembleStints' en 'Common.Types.TyreStint'.
--
-- Y lo que 'Handler.OpenF1.Manager.fetchListWith' escribe de cada petición: cómo
-- acabó ('Answer'), si se escribe sin @OPENF1_LOG@ ('alwaysWritten') y la línea
-- ('requestLine'); y cuánto espera antes de salir ('brakeWait').
module Handler.OpenF1.Helper
  ( Of1Driver (..)
  , Of1Stint (..)
  , assembleStints
  , Answer (..)
  , answerOf
  , alwaysWritten
  , requestLine
  , brakeBurst
  , brakeWindow
  , brakeWait
  ) where

import           Common.Types             (TyreStint (..))
import           Data.Aeson               (FromJSON (..), withObject, (.!=), (.:),
                                           (.:?))
import           Data.List                (find, sortOn)
import           Data.Maybe               (mapMaybe)
import           Data.Text                (Text)
import qualified Data.Text                as T
import           Data.Time.Clock          (NominalDiffTime, UTCTime (..),
                                           diffUTCTime)
import           Handler.PublicApi.Helper (Answer (..), answerOf)
import qualified Handler.PublicApi.Helper as PublicApi

-- | @/drivers@: identidad y equipo del piloto. El número y el acrónimo son
-- obligatorios: sin uno de ellos no decodifica la lista entera. El equipo, nulo o
-- ausente, sale @""@.
data Of1Driver = Of1Driver
  { odNumber  :: Int
  , odAcronym :: Text
  , odTeam    :: Text
  }
  deriving (Eq, Show)

instance FromJSON Of1Driver where
  parseJSON = withObject "Of1Driver" $ \o ->
    Of1Driver
      <$> o .: "driver_number"
      <*> o .: "name_acronym"
      <*> o .:? "team_name" .!= ""

-- | @/stints@: periodo con un mismo compuesto para un piloto.
--
-- __'osCompound' y 'osLapEnd' admiten ausencia, 'osNumber' y 'osLapStart' no__ ('osAge'
-- tampoco la exige: sin edad cuenta 0, la misma regla que el feed). Un @lap_end@ nulo no
-- se ha visto nunca; admitirlo es una precaución para que un stint no tumbe el arreglo.
-- En el compuesto es una observación: OpenF1 emite @compound: null@ en un stint
-- que __acaba de empezar__ —la vuelta ya está registrada y el compuesto todavía
-- no—, y con @o .: "compound"@ sobre 'Text' ese único objeto tumbaba el decode
-- del arreglo __completo__. Es el cuarto no-dato que entra por la misma clase de
-- puerta (el @NaN@ de 2026-07-31, el @'None'@ de 2026-08-13, el @tpBrake@ de
-- 2026-08-19).
--
-- El null __no está en el dato archivado__: medido el 2026-08-25 sobre 2268
-- stints de 44 sesiones, los cuatro campos llegan siempre y ninguno es nulo. Vive
-- solo en la sesión en curso, así que la rama de omisión solo la ejercita
-- @backend\/test\/Spec.hs@ (2026-08-25).
data Of1Stint = Of1Stint
  { osNumber   :: Int          -- ^ @driver_number@.
  , osCompound :: Maybe Text   -- ^ SOFT/MEDIUM/HARD/INTER/WET, o 'Nothing' en un
                               --   stint aún sin compuesto publicado.
  , osLapStart :: Int
  , osLapEnd   :: Maybe Int    -- ^ 'Nothing' si llega nulo o sin clave.
  , osAge      :: Int          -- ^ @tyre_age_at_start@; 0 si llega nulo o sin clave.
  }
  deriving (Eq, Show)

instance FromJSON Of1Stint where
  parseJSON = withObject "Of1Stint" $ \o ->
    Of1Stint
      <$> o .: "driver_number"
      <*> o .:? "compound"
      <*> o .: "lap_start"
      <*> o .:? "lap_end"
      <*> (o .:? "tyre_age_at_start" .!= 0)

-- | Ensambla los stints uniendo por @driver_number@ para resolver el acrónimo
-- del piloto. El resultado se ordena por acrónimo y luego por vuelta de inicio.
--
-- __Se omite el stint__ que no resuelve: ni el que trae un piloto ausente de
-- @/drivers@ (desde el 2026-08-11) ni el que llega sin compuesto (desde el
-- 2026-08-25) ni el que llega sin vuelta de fin (desde el 2026-11-20). Los tres
-- descartes comparten el 'Maybe' del bloque @do@, que es el mecanismo que el
-- 'mapMaybe' ya proporcionaba.
--
-- __Se omite en vez de degradar__, al revés que 'Common.Types.hsWins' —que admite
-- ausencia para no perder la entidad entera—, porque la unidad de la fila es otra:
-- allí es la entidad y aquí el stint, uno entre decenas, de modo que omitirlo
-- cuesta un tramo de una barra y no un piloto. Ni se inventa un @\"UNKNOWN\"@ que
-- OpenF1 no publicó. El contraste, en las decisiones del 2026-08-25 y 2026-08-24.
assembleStints :: [Of1Driver] -> [Of1Stint] -> [TyreStint]
assembleStints drivers stints =
  sortOn (\t -> (tsDriver t, tsStartLap t)) (mapMaybe toStint stints)
  where
    toStint s = do
      d        <- find ((== osNumber s) . odNumber) drivers
      compound <- osCompound s
      lapEnd   <- osLapEnd s
      pure
        TyreStint
          { tsDriver   = odAcronym d
          , tsCar      = T.pack (show (osNumber s))
          , tsCompound = compound
          , tsStartLap = osLapStart s
          , tsEndLap   = lapEnd
          , tsLaps     = lapEnd - osLapStart s + 1
          , tsAge      = osAge s
          , tsNew      = Nothing
          , tsSameSet  = Nothing
          }

-- | Si la línea sale aunque @OPENF1_LOG@ no esté puesta: todo fallo menos el @404@,
-- que es como OpenF1 dice «aún no hay datos» (@\/intervals@ fuera de carrera, en cada
-- tic). Con la variable puesta sale todo.
alwaysWritten :: Answer -> Bool
alwaysWritten (Answered code _) = not (code >= 200 && code < 300) && code /= 404
alwaysWritten (Unanswered _)    = True

-- | La línea de una petición a OpenF1: 'Handler.PublicApi.Helper.requestLine' con la
-- etiqueta @[openf1]@.
requestLine
  :: UTCTime -> Text -> [(Text, Maybe Text)] -> NominalDiffTime -> Answer -> Text
requestLine = PublicApi.requestLine "openf1"

-- | Cuántas salidas deja pasar el freno dentro de cada 'brakeWindow'.
brakeBurst :: Int
brakeBurst = 3

-- | La ventana del freno: el segundo del límite de OpenF1 («Max 3 requests/second»,
-- en su propio rechazo) más 0,2 s de margen, porque OpenF1 cuenta con su reloj y a
-- la llegada, no a la salida.
brakeWindow :: NominalDiffTime
brakeWindow = 1.2

-- | Cuánto tiene que esperar una salida, dadas las horas de las últimas, __la más
-- reciente primero__: nada si en la ventana caben más, y si no, lo que falta para que
-- la más vieja de las 'brakeBurst' salga de ella.
--
-- __Nunca más que la ventana__: una hora del futuro solo sale de un reloj que ha
-- retrocedido, y esperar todo lo retrocedido dejaría a OpenF1 sin preguntas.
brakeWait :: UTCTime -> [UTCTime] -> NominalDiffTime
brakeWait now recent = case drop (brakeBurst - 1) recent of
  oldest : _ -> max 0 (min brakeWindow (brakeWindow - diffUTCTime now oldest))
  []         -> 0
