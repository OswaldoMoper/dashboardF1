{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Helpers de acceso HTTP del frontend (INFRA). Solo
-- lectura (GET + decode JSON) sobre la API XHR de reflex-dom; los paths salen
-- de 'Common.Route', así el fetch es relativo y misma-origen (el backend sirve
-- el bundle y @\/api\/*@ en el mismo puerto). XSRF, headers y utilidades de
-- @location@ llegan cuando haya mutaciones (POST/PUT) y navegación.
module Client where

import           Data.Aeson         (FromJSON, decodeStrict)
import           Data.Text          (Text)
import           Data.Text.Encoding (encodeUtf8)
import           Reflex.Dom

-- | Request GET simple (sin cuerpo). Base para variantes con headers/XSRF.
getReq :: Text -> XhrRequest ()
getReq url = XhrRequest "GET" url def

-- | Decodifica el cuerpo de una respuesta 200; 'Nothing' en cualquier otro caso.
decodeXhr :: FromJSON a => XhrResponse -> Maybe a
decodeXhr r
  | _xhrResponse_status r == 200 =
      decodeStrict . encodeUtf8 =<< _xhrResponse_responseText r
  | otherwise = Nothing

-- | Dispara un GET por cada 'Text' (URL) del 'Event' y emite el JSON decodificado
-- (o 'Nothing' si falla el request o el decode).
fetchJson
  :: (MonadWidget t m, FromJSON a)
  => Event t Text -> m (Event t (Maybe a))
fetchJson urls = do
  resp <- performRequestAsync (getReq <$> urls)
  pure (decodeXhr <$> resp)
