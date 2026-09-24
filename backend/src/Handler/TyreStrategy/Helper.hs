-- | Área estrategia de neumáticos — lógica pura.
--
-- Modela solo los campos de OpenF1 @/stints@ que se consumen y los traduce a
-- 'TyreStint'. El cruce @driver_number → name_acronym@ (para 'tsDriver') usa
-- 'Of1Driver' del cliente compartido 'Handler.OpenF1.Helper'. Sin efectos:
-- determinista y testeable.
module Handler.TyreStrategy.Helper
  ( -- * Tipo crudo OpenF1 de stints
    Of1Stint (..)
    -- * Transformación pura
  , assembleStints
    -- * La escalera
  , tyreStep
  ) where

import           Common.Origin         (Origin (..), Source (..))
import           Common.Types          (TyreStint (..))
import           Data.Aeson            (FromJSON (..), withObject, (.:), (.:?))
import           Data.List             (find, sortOn)
import           Data.Maybe            (mapMaybe)
import           Data.Text             (Text)
import           Data.Time.Clock       (UTCTime)
import           Handler.OpenF1.Helper (Of1Driver (..))
import           Provenance            (Provenanced (..))

-- | @/stints@: periodo con un mismo compuesto para un piloto.
--
-- __'osCompound' admite ausencia y los otros tres campos no__, y la asimetría es
-- una observación y no una precaución: OpenF1 emite @compound: null@ en un stint
-- que __acaba de empezar__ —la vuelta ya está registrada y el compuesto todavía
-- no—, y con @o .: "compound"@ sobre 'Text' ese único objeto tumbaba el decode
-- del arreglo __completo__, así que 'Handler.TyreStrategy.Context' degradaba al
-- dummy con la red viva. Es el cuarto no-dato que entra por la misma clase de
-- puerta (el @NaN@ de 2026-07-31, el @'None'@ de 2026-08-13, el @tpBrake@ de
-- 2026-08-19).
--
-- El null __no está en el dato archivado__: medido el 2026-08-25 sobre 2268
-- stints de 44 sesiones, los cuatro campos llegan siempre y ninguno es nulo. Vive
-- solo en la sesión en curso, que es cuando el widget se mira. De ahí que el
-- arreglo sea de camino live y que la rama de omisión solo la ejercite
-- @backend\/test\/Spec.hs@ (2026-08-25).
data Of1Stint = Of1Stint
  { osNumber   :: Int          -- ^ @driver_number@.
  , osCompound :: Maybe Text   -- ^ SOFT/MEDIUM/HARD/INTER/WET, o 'Nothing' en un
                               --   stint aún sin compuesto publicado.
  , osLapStart :: Int
  , osLapEnd   :: Int
  }
  deriving (Eq, Show)

instance FromJSON Of1Stint where
  parseJSON = withObject "Of1Stint" $ \o ->
    Of1Stint
      <$> o .: "driver_number"
      <*> o .:? "compound"
      <*> o .: "lap_start"
      <*> o .: "lap_end"

-- | Ensambla los stints uniendo por @driver_number@ para resolver el acrónimo
-- del piloto. El resultado se ordena por acrónimo y luego por vuelta de inicio.
--
-- __Se omite el stint__ que no resuelve: ni el que trae un piloto ausente de
-- @/drivers@ (desde el 2026-08-11) ni el que llega sin compuesto (desde el
-- 2026-08-25). Los dos descartes comparten el 'Maybe' del bloque @do@, que es el
-- mecanismo que el 'mapMaybe' ya proporcionaba.
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
      pure
        TyreStint
          { tsDriver   = odAcronym d
          , tsCompound = compound
          , tsStartLap = osLapStart s
          , tsEndLap   = osLapEnd s
          }

-- | El peldaño de la escalera y lo que queda guardado, a partir de lo que trajo
-- OpenF1 ('Nothing' si el fetch falló) y de lo guardado con su hora.
--
-- __Lo traído solo vale con filas:__ una respuesta vacía cae a lo guardado igual que
-- un fallo. 'Nothing' en el primer componente es que no hay nada que servir, y quien
-- llama pone el respaldo estático. La fuente es siempre OpenF1, porque es la única
-- que esta área consulta.
tyreStep
  :: UTCTime
  -> Maybe [TyreStint]
  -> Maybe (UTCTime, [TyreStint])
  -> (Maybe (Provenanced [TyreStint]), Maybe (UTCTime, [TyreStint]))
tyreStep now (Just rows@(_ : _)) _ =
  (Just (Provenanced Fresh (Just OpenF1) Nothing rows), Just (now, rows))
tyreStep _ _ cached = (fromEntry <$> cached, cached)
  where
    fromEntry (fetchedAt, rows) = Provenanced Cached (Just OpenF1) (Just fetchedAt) rows
