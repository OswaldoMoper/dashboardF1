-- | Cliente OpenF1 — plumbing HTTP compartido (capa de efectos).
--
-- Punto único de acceso a la API pública de OpenF1 (@api.openf1.org/v1@) con el
-- cliente @req@: base de URL, las opciones que seleccionan de qué se habla y el GET
-- genérico que decodifica un arreglo JSON — 'fetchListWith' para cualquier
-- selección y 'fetchList' para la sesión en curso, que es la mayoría. Reúne también
-- 'fetchDrivers' (@/drivers@), compartido por 'Handler.Live' y
-- 'Handler.TyreStrategy'. Los GET específicos de un área viven en el @Manager@ de
-- esa área, reusando estos dos.
--
-- La __política de fallo__ (techo por intento y número de intentos) no está aquí
-- sino en 'Handler.PublicApi.Manager', porque es la misma que la de Jolpica y no
-- puede divergir entre las dos.
module Handler.OpenF1.Manager where

import           Config                    (Config (..))
import           Control.Concurrent        (threadDelay)
import           Control.Concurrent.MVar   (MVar, modifyMVar)
import           Control.Exception         (throwIO, try)
import           Control.Monad             (when)
import           Data.Aeson                (FromJSON)
import qualified Data.ByteString           as BS
import           Data.Text                 (Text)
import           Data.Text.Encoding        (encodeUtf8)
import           Data.Time.Clock           (UTCTime, diffUTCTime,
                                            getCurrentTime)
import           Handler.OpenF1.Helper     (Answer (..), Of1Driver,
                                            alwaysWritten, answerOf, brakeBurst,
                                            brakeWait, requestLine)
import           Handler.PublicApi.Manager (publicApiConfig, publicApiOptions)
import           Network.HTTP.Req
import           System.IO                 (stderr)

-- | Base de la API pública de OpenF1.
openf1Base :: Url 'Https
openf1Base = https "api.openf1.org" /: "v1"

-- | La mayoría de los endpoints se piden para la sesión en curso.
latestSession :: Option 'Https
latestSession = "session_key" =: ("latest" :: Text)

-- | @\/meetings@ no se pide por sesión sino por la clave del gran premio, que
-- llega dentro de otras respuestas.
meetingKey :: Int -> Option 'Https
meetingKey = ("meeting_key" =:)

-- | Y también por año, que es como se piden todos los del calendario de una vez.
--
-- __Va con @('=:')@ y no con 'queryFlag'__, al contrario que 'endsAfter': aquí el
-- filtro es una igualdad, así que el operador no forma parte del nombre y el @=@ que
-- @req@ intercala es el que toca. Medido el 2026-09-17: @?year=2026@ contesta 200
-- con los 27 grandes premios.
meetingYear :: Integer -> Option 'Https
meetingYear = ("year" =:)

-- | Las sesiones que __aún no han terminado__ según el calendario, dado un instante
-- en ISO 8601.
--
-- __Se filtra por la hora de fin y no por la de inicio__, y la diferencia importa:
-- con @date_start@ la sesión que está rodando queda fuera —su arranque ya pasó—, y
-- un backend que reiniciara en plena carrera concluiría que no hay nada que mirar.
-- Verificado contra OpenF1: preguntando desde mitad de la carrera 11369, con
-- @date_end@ la sesión en curso sale en la respuesta.
--
-- __Va como parámetro sin valor y no con @('=:')@, y eso no es estilo.__ En los
-- filtros de comparación de OpenF1 el operador forma parte del __nombre__ del
-- parámetro, así que @\"date_end>=\" '=:' instante@ intercala un @=@ y manda
-- @date_end%3E%3D=2026-…@, al que OpenF1 responde @404 \"No results found\"@.
-- 'queryFlag' pega el valor al nombre y manda @date_end%3E%3D2026-…@, que es la
-- forma que contesta. Medido el 2026-09-15 contra las dos.
--
-- __La suite lo ancla mirando el parámetro construido__ (@describe \"endsAfter\"@),
-- que es la única prueba del repositorio sobre una petición de salida en vez de
-- sobre un dato de entrada. Hace falta porque el fallo no se ve leyendo: vuelve como
-- un @404@ que el @Context@ se traga, y lo único que se nota es que el calendario
-- nunca llega.
endsAfter :: Text -> Option 'Https
endsAfter instant = queryFlag ("date_end>=" <> instant)

-- | GET a un endpoint de OpenF1 que devuelve un arreglo JSON, decodificado, con
-- las opciones que se le den.
--
-- Existe aparte de 'fetchList' porque __no todos los endpoints hablan de la sesión
-- en curso__: @\/meetings@ se pide por su propia clave. El techo de duración se
-- añade aquí y no lo pone quien llama, para que no se pueda olvidar.
--
-- Recibe la 'Config' porque de ella sale ese techo
-- ('Handler.PublicApi.Manager.publicApiOptions'); el 'Env' la transporta, así que
-- los @Context@ la pasan con @envConfig@ (mismo patrón que
-- 'Handler.Drivers.Manager.fetchDrivers').
--
-- __Deja una línea en @stderr@__ ('Handler.OpenF1.Helper.requestLine'): de cada
-- petición con @OPENF1_LOG@, y sin ella de los fallos que no son @404@
-- ('Handler.OpenF1.Helper.alwaysWritten'). __El fallo se vuelve a lanzar tal cual__,
-- así que el @try@ de quien llama ve lo mismo que sin la línea. La línea sale en una
-- sola escritura: dos peticiones a la vez no mezclan las suyas.
--
-- __Antes de salir espera su turno__ ('takeTurn'), así que ninguna área puede pasarse
-- del límite por segundo de OpenF1. Los reintentos de @req@ por techo vencido salen
-- sin turno.
fetchListWith :: FromJSON a => Config -> Text -> Option 'Https -> IO [a]
fetchListWith cfg path opts = do
  sent <- takeTurn (cfgOpenF1Brake cfg)
  result <- try $ runReq publicApiConfig $ do
    res <-
      req
        GET
        (openf1Base /: path)
        NoReqBody
        jsonResponse
        (opts <> publicApiOptions cfg)
    pure (responseStatusCode res, responseBody res)
  done <- getCurrentTime
  let answer = either answerOf (\(code, _) -> Answered code "") result
  when (cfgOpenF1Log cfg || alwaysWritten answer) $
    BS.hPut stderr . encodeUtf8 . (<> "\n") $
      requestLine sent path (queryParamToList opts) (diffUTCTime done sent) answer
  either throwIO (pure . snd) result

-- | Espera el turno del freno de OpenF1 ('Handler.OpenF1.Helper.brakeWait'), apunta la
-- salida y devuelve su hora.
--
-- __Quien espera retiene el turno__: el que llega detrás espera a que éste salga, así
-- que dos áreas a la vez no se cuelan juntas.
takeTurn :: MVar [UTCTime] -> IO UTCTime
takeTurn brake = modifyMVar brake $ \recent -> do
  wait <- (`brakeWait` recent) <$> getCurrentTime
  when (wait > 0) $
    threadDelay (ceiling (realToFrac wait * 1e6 :: Double))
  sent <- getCurrentTime
  pure (take brakeBurst (sent : recent), sent)

-- | 'fetchListWith' para la sesión en curso, que es el caso mayoritario.
fetchList :: FromJSON a => Config -> Text -> IO [a]
fetchList cfg path = fetchListWith cfg path latestSession

fetchDrivers :: Config -> IO [Of1Driver]
fetchDrivers cfg = fetchList cfg "drivers"
