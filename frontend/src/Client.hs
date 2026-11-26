{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Helpers de acceso HTTP del frontend (INFRA). Solo
-- lectura (GET + decode JSON) sobre la API XHR de reflex-dom; los paths salen
-- de 'Common.Route', así el fetch es relativo y misma-origen (el backend sirve
-- el bundle y @\/api\/*@ en el mismo puerto). XSRF, headers y utilidades de
-- @location@ llegan cuando haya mutaciones (POST/PUT) y navegación.
--
-- Las cabeceras __de respuesta__ sí se leen ya, pero solo las de procedencia y
-- solo en 'fetchJsonSourcedWith' ('Common.Origin').
module Client where

import           Client.Helper        (decodedFrom, fetchedFrom)
import           Common.Origin        (Sourced, sourcedFrom, sourcedHeaders)
import           Common.Shown         (Fetched)
import           Data.Aeson           (FromJSON)
import qualified Data.CaseInsensitive as CI
import qualified Data.Map             as Map
import qualified Data.Set             as Set
import           Data.Text            (Text)
import           Reflex.Dom

-- | Request GET simple (sin cuerpo). Base para variantes con headers/XSRF.
getReq :: Text -> XhrRequest ()
getReq url = XhrRequest "GET" url def

-- | Decodifica el cuerpo de una respuesta 200; 'Nothing' en cualquier otro caso
-- ('Client.Helper.decodedFrom').
decodeXhr :: FromJSON a => XhrResponse -> Maybe a
decodeXhr r = decodedFrom (_xhrResponse_status r) (_xhrResponse_responseText r)

-- | Como 'decodeXhr', pero un @404@ es 'Absent' y no un fallo cualquiera
-- ('Client.Helper.fetchedFrom').
fetchedXhr :: FromJSON a => XhrResponse -> Fetched a
fetchedXhr r = fetchedFrom (_xhrResponse_status r) (_xhrResponse_responseText r)

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

-- | Como 'fetchJson', con cada URL acompañada de lo que la pidió (@k@: su número, su
-- sesión): la respuesta llega con ello, para que quien pide tire la de una petición que
-- ya no vale.
fetchJsonWith
  :: (MonadWidget t m, FromJSON a)
  => Event t (k, Text) -> m (Event t (k, Maybe a))
fetchJsonWith urls = do
  resp <- performRequestsAsync (fmap getReq <$> urls)
  pure (fmap decodeXhr <$> resp)

-- | Las respuestas de 'fetchJsonWith' o 'fetchJsonSourcedWith' que salieron con lo que
-- @wanted@ vale todavía (la sesión elegida); las demás se tiran.
stillFor :: (Reflex t, Eq k) => Behavior t k -> Event t (k, a) -> Event t a
stillFor wanted = attachWithMaybe (\cur (k, r) -> if k == cur then Just r else Nothing) wanted

-- | Como 'fetchJsonWith', pero el valor llega con la procedencia que traían sus
-- cabeceras, y un @404@ se distingue de los demás fallos ('fetchedXhr'): un fallo de la
-- petición o del decode no tiene procedencia que contar.
fetchJsonSourcedWith
  :: (MonadWidget t m, FromJSON a)
  => Event t (k, Text) -> m (Event t (k, Fetched (Sourced a)))
fetchJsonSourcedWith urls = do
  resp <- performRequestsAsync (fmap getReqSourced <$> urls)
  pure (ffor resp $ fmap $ \r -> sourcedFrom (headerOf r) <$> fetchedXhr r)
  where
    headerOf r name = Map.lookup (CI.mk name) (_xhrResponse_headers r)
