-- | Cliente Jolpica (Ergast) — plumbing HTTP de estadísticas históricas.
--
-- Acceso a la API pública de Jolpica (@api.jolpi.ca\/ergast\/f1@) con el cliente
-- @req@. Base de URL propia: NO reusa 'Handler.OpenF1.Manager.fetchList', que está
-- fijado a @openf1Base@ + @session_key=latest@. Si más adelante hay >1 consumidor de
-- Jolpica, se extraerá un cliente compartido (mismo criterio que OpenF1).
--
-- Lo que sí comparte con OpenF1 es la __política de fallo__, y vive en
-- 'Handler.PublicApi.Manager': las dos son redes públicas y no pueden degradar a
-- velocidades distintas. Se importa de allí y no de 'Handler.OpenF1.Manager' para
-- que este cliente no dependa del otro. Lo mismo la línea del log de cada petición
-- ('Handler.PublicApi.Helper'), que aquí sale siempre.
module Handler.Historical.Manager
  ( jolpicaBase
  , standingsUrl
  , jolpicaRoute
  , fetchStandings
  , fetchConstructorStandings
  , fetchStandingsAfter
  , fetchConstructorStandingsAfter
  , fetchSeasonSchedule
  , fetchSeasonOf
  ) where

import           Config                    (Config)
import           Control.Exception         (throwIO, try)
import qualified Data.ByteString           as BS
import qualified Data.ByteString.Lazy      as LBS
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Data.Text.Encoding        (encodeUtf8)
import           Data.Time.Clock           (diffUTCTime, getCurrentTime)
import           Handler.Historical.Helper (Root)
import           Handler.PublicApi.Helper  (Answer (..), answerOf, requestLine)
import           Handler.PublicApi.Manager (publicApiConfig, publicApiOptions)
import           Network.HTTP.Req
import           System.IO                 (stderr)

-- | Base de la API pública de Jolpica (sucesor de Ergast).
jolpicaBase :: Url 'Https
jolpicaBase = https "api.jolpi.ca" /: "ergast" /: "f1"

-- | Clasificación de pilotos de la temporada en curso (@\/current\/driverStandings@),
-- decodificada a la envoltura 'Root'.
fetchStandings :: Config -> IO Root
fetchStandings cfg = fetchRoot cfg ["current"] "driverStandings"

-- | Clasificación de constructores de la temporada en curso
-- (@\/current\/constructorStandings@). Misma envoltura 'Root': el nivel
-- @StandingsList@ trae @ConstructorStandings@ en vez de @DriverStandings@ y ambas
-- claves son opcionales allí.
fetchConstructorStandings :: Config -> IO Root
fetchConstructorStandings cfg = fetchRoot cfg ["current"] "constructorStandings"

-- | Las dos clasificaciones tras esa ronda de ese año (@\/{año}\/{ronda}\/…@). Una
-- ronda aún no corrida, o la 0, llega como lista vacía, no como fallo.
fetchStandingsAfter, fetchConstructorStandingsAfter :: Config -> Int -> Int -> IO Root
fetchStandingsAfter cfg year rnd = fetchRoot cfg (roundPath year rnd) "driverStandings"
fetchConstructorStandingsAfter cfg year rnd = fetchRoot cfg (roundPath year rnd) "constructorStandings"

roundPath :: Int -> Int -> [Text]
roundPath year rnd = [T.pack (show year), T.pack (show rnd)]

-- | La URL de una clasificación, con la barra final: sin ella Jolpica contesta 301 y cada
-- GET son dos peticiones.
standingsUrl :: [Text] -> Text -> Url 'Https
standingsUrl season table = foldl (/:) jolpicaBase season /: table /: ""

fetchRoot :: Config -> [Text] -> Text -> IO Root
fetchRoot cfg season table = fetchLogged url $ do
  res <-
    req
      GET
      url
      NoReqBody
      jsonResponse
      (publicApiOptions cfg)
  pure (responseStatusCode res, responseBody res)
  where
    url = standingsUrl season table

-- | El calendario de la temporada en curso (@\/current\/races.json@), sin leer: todas
-- las carreras caben en la página por defecto. Sin @.json@ la API responde con una
-- redirección.
fetchSeasonSchedule :: Config -> IO LBS.ByteString
fetchSeasonSchedule cfg = fetchRaces cfg "current"

-- | El calendario de ese año (@\/{año}\/races.json@), sin leer.
fetchSeasonOf :: Config -> Int -> IO LBS.ByteString
fetchSeasonOf cfg year = fetchRaces cfg (T.pack (show year))

fetchRaces :: Config -> Text -> IO LBS.ByteString
fetchRaces cfg season = fetchLogged url $ do
  res <-
    req
      GET
      url
      NoReqBody
      lbsResponse
      (publicApiOptions cfg)
  pure (responseStatusCode res, responseBody res)
  where
    url = jolpicaBase /: season /: "races.json"

-- | La ruta de una URL de Jolpica tras @…\/ergast\/f1\/@, como sale en la línea del log.
jolpicaRoute :: Url 'Https -> Text
jolpicaRoute url = T.drop (T.length (renderUrl jolpicaBase) + 1) (renderUrl url)

-- | Una petición a Jolpica, con su línea en @stderr@ siempre, salga como salga
-- ('Handler.PublicApi.Helper.requestLine', etiqueta @[jolpica]@), en una sola escritura.
-- El fallo se vuelve a lanzar tal cual.
fetchLogged :: Url 'Https -> Req (Int, a) -> IO a
fetchLogged url call = do
  sent <- getCurrentTime
  config <- publicApiConfig
  result <- try (runReq config call)
  done <- getCurrentTime
  let answer = either answerOf (\(code, _) -> Answered code "") result
  BS.hPut stderr . encodeUtf8 . (<> "\n") $
    requestLine "jolpica" sent (jolpicaRoute url) [] (diffUTCTime done sent) answer
  either throwIO (pure . snd) result
