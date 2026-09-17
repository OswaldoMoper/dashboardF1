-- | Qué devuelve un @Context@ cuando la petición puede no merecer respuesta (INFRA).
--
-- Hasta hoy los seis @Context@ del repo devolvían @IO a@, y ésa es exactamente la
-- razón por la que un @400@ del microservicio llegaba al cliente como un @200@ con
-- el dummy: un @a@ __no tiene sitio donde decir «la petición era mala»__. La
-- escalera @try@ → cache → dummy (2026-07-22) atrapa con
-- 'SomeException', así que un servicio apagado y un @drivers@ con tres coches
-- entran por la misma rama y salen por la misma puerta. No era un bug de dos
-- endpoints: era la firma.
--
-- Este módulo es el tipo que la arregla, y vive en la raíz —con 'Config', 'App' y
-- 'Server'— porque no es de un área: lo van a compartir las tres que hablan con el
-- microservicio (2026-08-14).
--
-- __La regla que gobierna el módulo entero: 'Nothing' es el caso por defecto.__
-- Solo se rechaza lo que se ha reconocido positivamente como culpa del cliente;
-- todo lo demás —servicio caído, timeout, JSON con otra forma, un @500@ del
-- servicio— sigue degradando como siempre. Está escrito así a propósito, porque el
-- riesgo de este arreglo es cometer la confusión __al revés__: convertir un
-- servicio apagado en un error visible sería peor que el bug que se está
-- corrigiendo, ya que el degradado es el escenario __normal__ de este servicio
-- (2026-08-04).
module Outcome
  ( Outcome (..)
  , Rejection (..)
  , rejectionFor
  , httpStatusOf
  , classify
  , serve
  ) where

import           Control.Exception         (SomeException, fromException)
import           Control.Monad.Error.Class (throwError)
import           Data.Aeson                (FromJSON (..), decodeStrict, encode,
                                            object, withObject, (.:), (.=))
import           Data.ByteString           (ByteString)
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Data.Text.Encoding        (decodeUtf8With)
import           Data.Text.Encoding.Error  (lenientDecode)
import qualified Network.HTTP.Client       as Client
import           Network.HTTP.Req          (HttpException (..))
import           Network.HTTP.Types        (hContentType, statusCode)
import           Servant                   (Handler, ServerError (..), err400,
                                            err404)

-- | Por qué no hay nada que servir, con el texto que lo explica.
--
-- __No incluye «el servicio está caído»__, y esa ausencia es el diseño: un
-- servicio caído no impide servir algo (la cache, o el dummy), así que sale por
-- 'Served' como ha salido siempre. Aquí solo entra aquello ante lo que servir un
-- respaldo sería __mentir__: el cliente pidió algo que no se le puede dar, y
-- devolverle la última comparación buena de otra petición lo dejaría sin saberlo.
data Rejection
  = -- | La petición está mal formada. Sale como @400@.
    BadRequest Text
  | -- | La petición está bien formada pero el recurso no existe. Sale como @404@.
    --
    -- __Es un caso propio y no una variante del anterior__ (decisión del
    -- 2026-08-14). @2026-99-R@ es una sesión que no se disputó: el cliente
    -- escribió bien y el dato no está, que no es lo mismo que teclear una
    -- @session_key@ con otra forma. Fundirlos costaría separarlos otra vez en
    -- cuanto un widget quiera distinguir «no existe» de «lo pediste mal».
    NotFound Text
  deriving (Eq, Show)

-- | El resultado de un @Context@: o hay algo que servir, o la petición se rechaza.
--
-- 'Served' cubre __las tres__ salidas buenas de la escalera —dato real, dato de
-- cache y dummy— y no las distingue, igual que antes: quién sirvió el dato es cosa
-- del @Context@, y el cliente recibe un @200@ en los tres casos.
data Outcome a
  = Served a
  | Refused Rejection
  deriving (Eq, Show)

-- | El @detail@ de FastAPI, que es el cuerpo que emite el microservicio en sus
-- cuatro @400@ y sus dos @404@ (@telemetry-service\/main.py@).
newtype Detail = Detail Text

instance FromJSON Detail where
  parseJSON = withObject "Detail" (\o -> Detail <$> o .: "detail")

-- | Qué es un no-2xx del microservicio, a partir de su status y su cuerpo. __Es la
-- parte pura del discriminador__, separada de 'classify' precisamente para que
-- @backend-test@ pueda cubrirla sin levantar una red.
--
-- 'Nothing' significa «esto no es culpa del cliente» y devuelve el caso a la
-- escalera de degradado. Cae ahí todo lo que no sea @400@ o @404@ — en particular
-- los @5xx@, donde el servicio está admitiendo que el fallo es suyo.
--
-- El texto sale del @detail@ del servicio y se propaga tal cual: quien conoce el
-- contrato es quien lo comprueba, y reescribir aquí el mensaje sería mantener dos
-- versiones del mismo criterio (2026-08-12). Si el cuerpo no
-- trae @detail@ —o no es JSON— se usa el propio cuerpo como texto, y solo si está
-- vacío un respaldo genérico: siempre es preferible un mensaje feo del servicio a
-- uno bonito inventado aquí.
rejectionFor :: Int -> ByteString -> Maybe Rejection
rejectionFor status body =
  case status of
    400 -> Just (BadRequest (detailOf body "petición mal formada"))
    404 -> Just (NotFound (detailOf body "el recurso no existe"))
    _   -> Nothing

-- | El @detail@ del cuerpo, o el cuerpo entero, o el respaldo.
--
-- La decodificación es __leniente a propósito__: el @detail@ del microservicio
-- viaja en UTF-8 y trae acentos («números», «comparación»), así que un @show@ del
-- 'ByteString' publicaría @n\\195\\186meros@. Y un cuerpo mal codificado no debe
-- tumbar la clasificación: en el peor caso se sirve un texto con caracteres de
-- reemplazo, que sigue siendo más informativo que perder el @400@.
detailOf :: ByteString -> Text -> Text
detailOf body fallback =
  case decodeStrict body of
    Just (Detail detail) -> nonEmpty detail
    Nothing              -> nonEmpty (decodeUtf8With lenientDecode body)
  where
    nonEmpty text = if T.null (T.strip text) then fallback else text

-- | El status y el cuerpo de un no-2xx, pelados de la excepción que los trae.
--
-- __La forma exacta está medida, no supuesta__ (2026-08-14).
-- @req@ con 'Network.HTTP.Req.defaultHttpConfig' convierte un no-2xx en
-- @VanillaHttpException (HttpExceptionRequest _ (StatusCodeException resp body))@,
-- y de ahí sobreviven las dos cosas que hacían falta: el @statusCode@ en el
-- 'Client.responseStatus', y el cuerpo __entero__ como segundo argumento del
-- constructor —los @86@ bytes del @detail@ caben de sobra en el preview de 1 KiB
-- que guarda @http-client@—. Sin esa medición no se podía escribir esta función, y
-- por eso hubo que tomarla antes de tocar el módulo.
--
-- 'Nothing' para todo lo que no sea un no-2xx de @req@:
-- 'Client.InvalidUrlException', los otros 'Client.HttpExceptionContent' (conexión
-- rechazada, timeout), 'Network.HTTP.Req.JsonHttpException' (el servicio contestó
-- @200@ con otra forma) y cualquier excepción ajena a @req@.
--
-- __Está expuesta porque el status interesa más allá del discriminador__: quien
-- solo quiere decir en el log qué contestó la fuente necesita esto y no un
-- 'Rejection', que se queda con dos códigos de los muchos que hay.
httpStatusOf :: SomeException -> Maybe (Int, ByteString)
httpStatusOf e = do
  VanillaHttpException vanilla <- fromException e
  Client.HttpExceptionRequest _ content <- Just vanilla
  Client.StatusCodeException response body <- Just content
  pure (statusCode (Client.responseStatus response), body)

-- | La excepción real de un no-2xx, clasificada. Delega en 'rejectionFor' en
-- cuanto 'httpStatusOf' ha conseguido extraer status y cuerpo.
--
-- Todo lo que 'httpStatusOf' no reconoce devuelve 'Nothing' y degrada, igual que
-- los status que 'rejectionFor' no reclama.
classify :: SomeException -> Maybe Rejection
classify e = uncurry rejectionFor =<< httpStatusOf e

-- | Traduce el 'Outcome' del @Context@ a la respuesta de Servant. Es __todo__ lo
-- que el handler hace con él: quien decide si un fallo es del cliente es quien
-- hizo la llamada y conoce el contrato, no la capa de interfaz. Mismo reparto que
-- ya tenían los @resolveParams@ — el handler baja los 'Maybe' sin interpretarlos.
serve :: Outcome a -> Handler a
serve (Served a)  = pure a
serve (Refused r) = throwError (serverError r)

-- | El 'ServerError' de cada rechazo, con el @detail@ del servicio dentro.
--
-- El cuerpo se rearma como JSON con la __misma clave__ @detail@ que emite el
-- microservicio, para que un consumidor no tenga que aprender dos formas de error
-- según quién lo generó. El @Content-Type@ va explícito porque 'ServerError' no lo
-- pone: sin él, Servant sirve el JSON anunciándolo como @text\/plain@.
serverError :: Rejection -> ServerError
serverError (BadRequest detail) = withDetail err400 detail
serverError (NotFound detail)   = withDetail err404 detail

-- | Un 'ServerError' de Servant con cuerpo JSON @{\"detail\": …}@.
withDetail :: ServerError -> Text -> ServerError
withDetail base detail =
  base
    { errBody = encode (object ["detail" .= detail])
    , errHeaders = [(hContentType, "application/json;charset=utf-8")]
    }
