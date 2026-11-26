-- | La línea del registro de peticiones a las APIs públicas (lógica pura): cómo acabó
-- una petición ('Answer', 'answerOf') y la línea que la cuenta ('requestLine'). La
-- escriben 'Handler.OpenF1.Manager.fetchListWith' y 'Handler.Historical.Manager', cada
-- una con su etiqueta.
module Handler.PublicApi.Helper
  ( Answer (..)
  , answerOf
  , requestLine
  ) where

import           Control.Exception        (toException)
import           Data.ByteString          (ByteString)
import           Data.Text                (Text)
import qualified Data.Text                as T
import           Data.Text.Encoding       (decodeUtf8With)
import           Data.Text.Encoding.Error (lenientDecode)
import           Data.Time.Clock          (NominalDiffTime, UTCTime (..))
import           Data.Time.Format         (defaultTimeLocale, formatTime)
import qualified Network.HTTP.Client      as Client
import           Network.HTTP.Req         (HttpException (..))
import           Outcome                  (httpStatusOf)
import           Text.Printf              (printf)

-- | Cómo acabó una petición.
data Answer
  = Answered Int ByteString -- ^ Contestó: el código y, si fue un rechazo, su cuerpo.
  | Unanswered Text         -- ^ No hubo código: la causa.
  deriving (Eq, Show)

-- | El desenlace de una excepción de @req@.
--
-- __La causa es solo el motivo__ (@ResponseTimeout@, @ConnectionFailure …@): el texto
-- entero de la excepción vuelca también la petición, y la ruta ya va en la línea.
answerOf :: HttpException -> Answer
answerOf e =
  maybe (Unanswered (cause e)) (uncurry Answered) (httpStatusOf (toException e))
  where
    cause (VanillaHttpException (Client.HttpExceptionRequest _ content)) =
      T.pack (show content)
    cause (VanillaHttpException (Client.InvalidUrlException _ why)) = T.pack why
    cause (JsonHttpException why) = T.pack why

-- | La línea de una petición: el instante del envío con milisegundos, la fuente entre
-- corchetes (@[openf1]@, @[jolpica]@), la ruta con sus parámetros, el código (@---@ si no
-- lo hubo), la duración y, si lo hay, el texto del rechazo o la causa.
--
-- __Siempre una sola línea__, para que al contarlas una petición sea una línea: los
-- saltos del texto se vuelven espacios, y se corta a 200 caracteres.
--
-- __Una línea es una llamada, no un intento__: los reintentos de @req@ por techo
-- vencido ('Handler.PublicApi.Manager.publicApiConfig') quedan dentro de ella, como
-- una duración larga.
requestLine
  :: Text -> UTCTime -> Text -> [(Text, Maybe Text)] -> NominalDiffTime -> Answer -> Text
requestLine source sent path params took answer =
  millisInstant sent <> " [" <> source <> "] " <> route <> " " <> code <> " "
    <> T.pack (printf "%.3f" (realToFrac took :: Double)) <> " s" <> detail
  where
    route
      | null params = path
      | otherwise   = path <> "?" <> T.intercalate "&" (map param params)
    param (k, v) = maybe k (\x -> k <> "=" <> x) v
    (code, said) = case answer of
      Answered c body -> (T.pack (show c), decodeUtf8With lenientDecode body)
      Unanswered why  -> ("---", why)
    detail
      | T.null said = ""
      | otherwise   = ": " <> T.take 200 (T.map flatten said)
    flatten c = if c == '\n' || c == '\r' then ' ' else c

-- | ISO 8601 con milisegundos, truncados. No es 'Provenance.isoInstant', que va en
-- segundos enteros.
millisInstant :: UTCTime -> Text
millisInstant t =
  T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S" t)
    <> T.pack (printf ".%03dZ" millis)
  where
    millis = (floor (toRational (utctDayTime t) * 1000) :: Integer) `mod` 1000
