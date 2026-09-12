-- | El indicador __@● Live@__ de una tarjeta: qué color lleva su punto, si
-- parpadea y qué dice su tooltip.
--
-- Es la parte con decisiones del indicador de procedencia (2026-09-11 (d)),
-- sacada del widget para que no sea ciega: 'Widgets.LiveTiming' solo cablea el
-- resultado a una clase y a un atributo @title@. Mismo criterio que
-- 'Common.Refresh' —lo puro y sin Reflex va a @common@, que es lo único con
-- suite— y misma razón: el paquete @frontend@ no se prueba.
--
-- __Une "Common.Origin" y "Common.Refresh" sin que ninguno de los dos dependa
-- del otro.__ La procedencia dice de dónde salió lo que se ve; el refresco dice
-- si lo último que se intentó llegó. Son preguntas independientes —de ahí que
-- los dos módulos lo sean— y el indicador es el único sitio donde se cruzan.
--
-- __El color y el parpadeo dicen cosas distintas, y por eso son dos señales.__
-- El color es la procedencia del dato que hay en pantalla y nunca miente sobre
-- ella; el parpadeo es «esto es la carrera, ahora mismo», y por eso solo lo
-- lleva el dato fresco cuyo último refresco volvió. Un refresco fallido sobre
-- dato guardado o de ejemplo no cambia el punto: vive en el tooltip.
--
-- __El parpadeo no se apaga con @prefers-reduced-motion@__, solo se alarga
-- (1 s → 3 s, en la hoja de estilos). No es decoración: es la única señal de que
-- lo que se lee está pasando ahora, y apagarla dejaría dos estados distintos
-- pintados igual.
module Common.Indicator
  ( Indicator (..)
  , indicatorFrom
  , indicatorClass
  , indicatorTooltip
  , fetchedAtLabel
  ) where

import           Common.Origin  (Origin (..), Source, Sourced (..), originNotice,
                                 sourceName)
import           Common.Refresh (Poll (..), liveRefreshSeconds)
import           Data.Char      (isDigit)
import           Data.Maybe     (fromMaybe, isJust)
import           Data.Text      (Text)
import qualified Data.Text      as T

-- | Lo que el indicador necesita saber para pintarse.
--
-- __'indOrigin', 'indSource' e 'indFetched' solo significan algo con 'indShown' a
-- 'True'__: son la procedencia de lo que hay en pantalla, y sin pantalla no hay
-- procedencia. El único constructor legítimo es 'indicatorFrom', que mantiene
-- esa relación; el récord es plano por la misma razón que 'Common.Refresh.Poll'
-- lo es, y no para poder construirlo a mano.
--
-- 'indShown' no cambia ningún color —sin dato la procedencia es desconocida, que
-- ya es gris— pero sí el tooltip: «se muestra la tabla anterior» es falso cuando
-- no hay tabla anterior, que es justo el caso del fallo en la primera carga.
data Indicator = Indicator
  { indShown   :: Bool
    -- ^ Hay algo en pantalla, aunque sea de una respuesta vieja.
  , indOrigin  :: Maybe Origin
    -- ^ Procedencia de lo que se ve; 'Nothing' si la cabecera faltaba, no se
    -- reconoció o aún no ha llegado ninguna respuesta.
  , indSource  :: Maybe Source
    -- ^ Fuente de lo que se ve; 'Nothing' también cuando el dato es el respaldo
    -- estático, que no salió de ninguna.
  , indFetched :: Maybe Text
    -- ^ El instante tal cual viajó en la cabecera, sin formatear.
  , indFailed  :: Bool
    -- ^ El último refresco no volvió.
  }
  deriving stock (Eq, Show)

-- | El indicador que corresponde al estado del refresco.
indicatorFrom :: Poll (Sourced a) -> Indicator
indicatorFrom p = Indicator
  { indShown   = isJust (pollShown p)
  , indOrigin  = srcOrigin =<< pollShown p
  , indSource  = srcSource =<< pollShown p
  , indFetched = srcFetchedAt =<< pollShown p
  , indFailed  = pollLastFailed p
  }

-- | Clase de la etiqueta, bloque y modificador.
--
-- __El modificador va siempre__, al revés que el de 'Widgets.LiveTiming.rowClass'
-- (2026-08-27, donde lo normal no lleva marca): aquí los cinco estados son
-- igual de dignos de señalar, y el modificador ausente sería un sexto estado sin
-- color.
--
-- Solo el primero parpadea, y el parpadeo lo pone la hoja de estilos: aquí se
-- decide __cuándo__, no cómo.
indicatorClass :: Indicator -> Text
indicatorClass i = "widget__badge widget__badge--" <> modifier
  where
    modifier =
      case (indOrigin i, indFailed i) of
        (Just Fresh,  False) -> "live"
        (Just Fresh,  True)  -> "stalled"
        (Just Cached, _)     -> "saved"
        (Just Sample, _)     -> "sample"
        (Nothing,     _)     -> "unknown"

-- | El texto del tooltip. __Nunca vacío__: la etiqueta dice siempre @Live@, así
-- que todo lo que la explica vive aquí.
--
-- __Se compone cuando hay dos cosas que decir.__ Un dato guardado cuyo refresco
-- además falló son dos hechos —de cuándo es lo que se ve, y que no se ha podido
-- cambiar— y el punto solo puede pintar uno. Los textos de la procedencia son
-- los de 'originNotice' tal cual, sin redactarlos otra vez: una segunda
-- redacción de lo mismo envejece mal.
--
-- El dato fresco es la excepción: si su refresco falló, «en vivo» ya no es
-- cierto, así que no se compone — se sustituye.
--
-- __La fuente va delante y como etiqueta__, separada por @·@ y no por un punto: es
-- lo primero que se lee y no alarga la cadena de frases, que en el peor caso ya son
-- dos. El respaldo estático no lleva ninguna porque no salió de ninguna fuente.
indicatorTooltip :: Indicator -> Text
indicatorTooltip i = maybe body (\s -> sourceName s <> " · " <> body) (indSource i)
  where
    body =
      case (indOrigin i, indFailed i) of
        (Just Fresh, False) -> liveNotice
        (Just Fresh, True)  -> retryFailedNotice
        (origin, failed)    -> withFailure failed (noticeOf origin)

    noticeOf (Just origin) =
      fromMaybe unknownNotice (originNotice origin (fetchedAtLabel =<< indFetched i))
    noticeOf Nothing = unknownNotice

    -- Sin nada en pantalla el fallo no se menciona: el cuerpo de la tarjeta ya
    -- pinta su «Error al cargar», y «se muestra la tabla anterior» sería falso.
    withFailure True t | indShown i = t <> ". " <> retryFailedNotice
    withFailure _    t = t

-- | El periodo sale de 'liveRefreshSeconds' y no de un número escrito aquí: si
-- el refresco cambia de ritmo, el tooltip no puede quedarse diciendo el viejo.
liveNotice :: Text
liveNotice = "En vivo: se actualiza cada " <> T.pack (show liveRefreshSeconds) <> " s"

retryFailedNotice :: Text
retryFailedNotice = "No se pudo recargar: se muestra la tabla anterior"

-- | Cubre la cabecera ausente y la irreconocible, que 'Common.Origin.originFrom'
-- ya decidió no distinguir, y también el hueco antes de la primera respuesta.
unknownNotice :: Text
unknownNotice = "Procedencia desconocida"

-- | La hora de un instante ISO 8601, para leerla: de @2026-09-11T14:03:22Z@ sale
-- @14:03 UTC@.
--
-- __Es puro y no depende de @time@__, que es lo que permite probarlo en
-- @backend-test@ sin traer la dependencia a @common@. A cambio no interpreta la
-- fecha: recorta la hora y el minuto que vienen detrás de la @T@ y comprueba su
-- __forma__, no su rango — el emisor es el propio backend (2026-09-11 (b)), que
-- la escribe en UTC y sin fracción.
--
-- Un texto que no tenga esa forma da 'Nothing', y el tooltip va sin hora: un
-- 'Common.Origin.Cached' sin hora sigue avisando, porque perder el cuándo no
-- convierte el dato en fresco.
fetchedAtLabel :: Text -> Maybe Text
fetchedAtLabel raw
  | [hh, mm] <- T.splitOn ":" hhmm
  , twoDigits hh
  , twoDigits mm
  = Just (hhmm <> " UTC")
  | otherwise = Nothing
  where
    hhmm = T.take 5 (T.drop 1 (T.dropWhile (/= 'T') (T.strip raw)))
    twoDigits t = T.length t == 2 && T.all isDigit t
