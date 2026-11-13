{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Helpers de acceso HTTP del frontend (INFRA). Solo
-- lectura (GET + decode JSON) sobre la API XHR de reflex-dom; los paths salen
-- de 'Common.Route', así el fetch es relativo y misma-origen (el backend sirve
-- el bundle y @\/api\/*@ en el mismo puerto). XSRF, headers y utilidades de
-- @location@ llegan cuando haya mutaciones (POST/PUT) y navegación.
--
-- Las cabeceras __de respuesta__ sí se leen ya, pero solo las de procedencia y
-- solo en 'fetchJsonSourced' ('Common.Origin').
module Client where

import           Common.Origin        (Sourced, sourcedFrom, sourcedHeaders)
import           Data.Aeson           (FromJSON, decodeStrict)
import qualified Data.CaseInsensitive as CI
import qualified Data.Map             as Map
import qualified Data.Set             as Set
import           Data.Text            (Text)
import           Data.Text.Encoding   (encodeUtf8)
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

-- | GET que además pide las cabeceras de procedencia.
--
-- __Hay que pedirlas por nombre:__ el @def@ de 'XhrRequestConfig' trae
-- @OnlyHeaders mempty@, así que con 'getReq' el mapa de cabeceras de la respuesta
-- llega vacío. Y el fallo sería silencioso, porque 'Common.Origin.originFrom' trata
-- la ausencia como duda y no como error.
--
-- __Cuáles son no se escribe aquí:__ la lista es
-- 'Common.Origin.sourcedHeaders', la misma que lee 'Common.Origin.sourcedFrom'.
-- Dos listas que tuvieran que coincidir podrían dejar de hacerlo sin que nada se
-- pusiera rojo — el paquete @frontend@ no tiene suite.
getReqSourced :: Text -> XhrRequest ()
getReqSourced url =
  XhrRequest "GET" url
    (def
       { _xhrRequestConfig_responseHeaders =
           OnlyHeaders (Set.fromList (map CI.mk sourcedHeaders))
       })

-- | Como 'fetchJson', pero el valor llega con la procedencia que traían sus
-- cabeceras. 'Nothing' en los mismos casos que 'fetchJson': un fallo de la
-- petición o del decode no tiene procedencia que contar.
fetchJsonSourced
  :: (MonadWidget t m, FromJSON a)
  => Event t Text -> m (Event t (Maybe (Sourced a)))
fetchJsonSourced urls = do
  resp <- performRequestAsync (getReqSourced <$> urls)
  pure (ffor resp $ \r -> sourcedFrom (headerOf r) <$> decodeXhr r)
  where
    headerOf r name = Map.lookup (CI.mk name) (_xhrResponse_headers r)

-- | Como 'fetchJsonSourced', con cada URL numerada: la respuesta llega con el número
-- de su petición.
fetchJsonSourcedNumbered
  :: (MonadWidget t m, FromJSON a)
  => Event t (Int, Text) -> m (Event t (Int, Maybe (Sourced a)))
fetchJsonSourcedNumbered urls = do
  resp <- performRequestsAsync (fmap getReqSourced <$> urls)
  pure (ffor resp $ fmap $ \r -> sourcedFrom (headerOf r) <$> decodeXhr r)
  where
    headerOf r name = Map.lookup (CI.mk name) (_xhrResponse_headers r)
