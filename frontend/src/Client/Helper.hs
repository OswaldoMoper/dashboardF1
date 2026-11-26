-- | Lo puro de 'Client': qué se lee de una respuesta según su código y su cuerpo.
--
-- __No importa Reflex ni nada del navegador__: @frontend-test@ lo compila con GHC
-- nativo.
module Client.Helper
  ( decodedFrom
  , fetchedFrom
  ) where

import           Common.Shown       (Fetched (..))
import           Data.Aeson         (FromJSON, decodeStrict)
import           Data.Text          (Text)
import           Data.Text.Encoding (encodeUtf8)

-- | El cuerpo de un @200@, decodificado; 'Nothing' con cualquier otro código, sin
-- cuerpo o si no se entiende.
decodedFrom :: FromJSON a => Word -> Maybe Text -> Maybe a
decodedFrom 200 body = decodeStrict . encodeUtf8 =<< body
decodedFrom _ _      = Nothing

-- | Como 'decodedFrom', pero un @404@ es 'Absent' y no un fallo cualquiera.
fetchedFrom :: FromJSON a => Word -> Maybe Text -> Fetched a
fetchedFrom 404 _     = Absent
fetchedFrom code body = maybe NotFetched Got (decodedFrom code body)
