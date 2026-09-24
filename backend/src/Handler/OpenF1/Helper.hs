-- | Cliente OpenF1 — tipos crudos compartidos y la línea del registro de peticiones
-- (lógica pura).
--
-- Modela los campos de OpenF1 comunes a varias áreas de negocio. Hoy alberga
-- 'Of1Driver' (@/drivers@), consumido por 'Handler.Live' (identidad + equipo del
-- piloto) y por 'Handler.TyreStrategy' (cruce @driver_number → name_acronym@
-- para poblar 'Common.Types.TyreStint'). Los tipos crudos específicos de un área
-- siguen viviendo en el @Helper@ de esa área.
--
-- Y lo que 'Handler.OpenF1.Manager.fetchListWith' escribe de cada petición: cómo
-- acabó ('Answer'), si se escribe sin @OPENF1_LOG@ ('alwaysWritten') y la línea
-- ('requestLine').
module Handler.OpenF1.Helper
  ( Of1Driver (..)
  , Answer (..)
  , answerOf
  , alwaysWritten
  , requestLine
  ) where

import           Control.Exception        (toException)
import           Data.Aeson               (FromJSON (..), withObject, (.:))
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

-- | @/drivers@: identidad y equipo del piloto.
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
      <*> o .: "team_name"

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

-- | Si la línea sale aunque @OPENF1_LOG@ no esté puesta: todo fallo menos el @404@,
-- que es como OpenF1 dice «aún no hay datos» (@\/intervals@ fuera de carrera, en cada
-- tic). Con la variable puesta sale todo.
alwaysWritten :: Answer -> Bool
alwaysWritten (Answered code _) = not (code >= 200 && code < 300) && code /= 404
alwaysWritten (Unanswered _)    = True

-- | La línea de una petición: el instante del envío con milisegundos, la ruta con sus
-- parámetros, el código (@---@ si no lo hubo), la duración y, si lo hay, el texto del
-- rechazo o la causa.
--
-- __Siempre una sola línea__, para que al contarlas una petición sea una línea: los
-- saltos del texto se vuelven espacios, y se corta a 200 caracteres.
--
-- __Una línea es una llamada, no un intento__: los reintentos de @req@ por techo
-- vencido ('Handler.PublicApi.Manager.publicApiConfig') quedan dentro de ella, como
-- una duración larga.
requestLine
  :: UTCTime -> Text -> [(Text, Maybe Text)] -> NominalDiffTime -> Answer -> Text
requestLine sent path params took answer =
  millisInstant sent <> " [openf1] " <> route <> " " <> code <> " "
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
