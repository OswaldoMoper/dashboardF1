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
-- __El parpadeo afirma algo sobre la SESIÓN y no sobre el refresco__, y de ahí que no
-- lo herede lo reciente: que la página siga pidiendo cada pocos segundos no convierte
-- en directo la clasificación final de una sesión acabada.
--
-- __Si hay sesión rodando es la tercera pregunta, y no se deduce de las otras dos__
-- (2026-09-21). Fuera de sesión el backend sirve la clasificación final de la última
-- con el sello 'Common.Origin.Fresh', y el sello no miente —el dato acaba de
-- llegar—: lo que mentiría es el punto del directo. Por eso entra por argumento en
-- vez de adivinarse desde la procedencia, y por eso los dos sellos de refresco
-- bueno —'Common.Origin.Fresh' y 'Common.Origin.Recent'— caen sin ella en el mismo
-- apagado. Fuera de sesión el backend se frena, así que la respuesta llega con uno
-- y con otro un ciclo sí y otro no; con un punto por sello, el punto latiría.
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

import           Common.Origin  (Origin (..), Source, Sourced (..),
                                 originNotice, sourceName)
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
  , indRunning :: Bool
    -- ^ Consta que hay una sesión en curso. __No sale de los otros campos__: un
    -- dato recién traído fuera de sesión sigue siendo fresco, y el sello no dice
    -- nada de si hay carrera.
  }
  deriving stock (Eq, Show)

-- | El indicador que corresponde al estado del refresco y al de la sesión.
--
-- __Si la sesión rueda entra por argumento y no se saca del 'Poll'__, que es lo que
-- mantiene este módulo genérico en @a@ y sin conocer el dominio: quien llama tiene
-- la tabla y sabe proyectarla ('Widgets.LiveTiming.stateOf'), y aquí solo se decide
-- qué pintar con la respuesta.
indicatorFrom :: Bool -> Poll (Sourced a) -> Indicator
indicatorFrom running p = Indicator
  { indShown   = isJust (pollShown p)
  , indOrigin  = srcOrigin =<< pollShown p
  , indSource  = srcSource =<< pollShown p
  , indFetched = srcFetchedAt =<< pollShown p
  , indFailed  = pollLastFailed p
  , indRunning = running
  }

-- | Clase de la etiqueta, bloque y modificador.
--
-- __El modificador va siempre__, al revés que el de 'Widgets.LiveTiming.rowClass'
-- (2026-08-27, donde lo normal no lleva marca): aquí los estados son todos
-- igual de dignos de señalar, y el modificador ausente sería uno más sin color.
--
-- __Los modificadores son siete y las procedencias cuatro__, porque no hay
-- biyección: 'Common.Origin.Fresh' y 'Common.Origin.Recent' se separan según si el
-- último refresco volvió, y los dos que no volvieron caen en el mismo — un dato que
-- no se ha podido recargar se lee igual venga de donde venga.
-- 'Common.Origin.Cached' no se desdobla porque su fallo lo cuenta el tooltip
-- (2026-09-12).
--
-- __Sin sesión rodando los dos de refresco bueno caen juntos en el apagado__, que es
-- el séptimo. Los que sí son un fallo —guardado, de ejemplo, refresco caído— no lo
-- cruzan: pintarlos como el estado normal escondería lo único que el punto existe
-- para avisar.
--
-- Solo el del directo parpadea, y el parpadeo lo pone la hoja de estilos: aquí se
-- decide __cuándo__, no cómo.
indicatorClass :: Indicator -> Text
indicatorClass i = "widget__badge widget__badge--" <> modifier
  where
    modifier =
      case (indOrigin i, indFailed i) of
        (Just Fresh,  False) -> withSession "live"
        (Just Fresh,  True)  -> "stalled"
        (Just Recent, False) -> withSession "recent"
        (Just Recent, True)  -> "stalled"
        (Just Cached, _)     -> "saved"
        (Just Sample, _)     -> "sample"
        (Nothing,     _)     -> "unknown"

    withSession m
      | indRunning i = m
      | otherwise    = "idle"

-- | El texto del tooltip. __Nunca vacío__: la etiqueta dice siempre @Live@, así
-- que todo lo que la explica vive aquí.
--
-- __Se compone cuando hay dos cosas que decir.__ Un dato guardado cuyo refresco
-- además falló son dos hechos —de cuándo es lo que se ve, y que no se ha podido
-- cambiar— y el punto solo puede pintar uno. Los textos de la procedencia son
-- los de 'originNotice' tal cual, sin redactarlos otra vez: una segunda
-- redacción de lo mismo envejece mal.
--
-- El dato fresco es la excepción, y por dos motivos: si su refresco falló o si no
-- hay sesión rodando, «en vivo» ya no es cierto, así que no se compone — se
-- sustituye.
--
-- __Lo reciente conserva el suyo aunque comparta punto con el fresco fuera de
-- sesión.__ El punto es lo que se ve sin querer y tiene que estar quieto; el aviso
-- solo aparece al apuntarlo, y ahí decir de cuándo es el dato y por qué salió de lo
-- guardado vale más que repetir que no hay carrera.
--
-- __La fuente va delante y como etiqueta__, separada por @·@ y no por un punto: es
-- lo primero que se lee y no alarga la cadena de frases, que en el peor caso ya son
-- dos. El respaldo estático no lleva ninguna porque no salió de ninguna fuente.
indicatorTooltip :: Indicator -> Text
indicatorTooltip i = maybe body (\s -> sourceName s <> " · " <> body) (indSource i)
  where
    body =
      case (indOrigin i, indFailed i) of
        (Just Fresh, False) | indRunning i -> liveNotice
                            | otherwise    -> idleNotice
        (Just Fresh, True)  -> retryFailedNotice
        (origin, failed)    -> withFailure failed (noticeOf origin)

    noticeOf (Just origin) =
      fromMaybe unknownNotice (originNotice origin (fetchedAtLabel =<< indFetched i))
    noticeOf Nothing = unknownNotice

    -- Sin nada en pantalla el fallo no se menciona: el cuerpo de la tarjeta ya
    -- pinta su «Error al cargar», y «se muestra la tabla anterior» sería falso.
    withFailure True t | indShown i = t <> ". " <> retryFailedNotice
    withFailure _    t = t

-- | Lo que pasa cuando el refresco está volviendo bien, con la cabeza que cambia
-- delante.
--
-- __El periodo sale de 'liveRefreshSeconds' y no de un número escrito aquí__: si el
-- refresco cambia de ritmo, el tooltip no puede quedarse diciendo el viejo. Y va una
-- sola vez porque lo dicen los dos avisos: lo único que los separa es la cabeza.
refreshedEvery :: Text -> Text
refreshedEvery lead =
  lead <> ": se actualiza cada " <> T.pack (show liveRefreshSeconds) <> " s"

liveNotice :: Text
liveNotice = refreshedEvery "En vivo"

-- | __El periodo sigue siendo cierto sin sesión__, y por eso no se calla: la página
-- pregunta al mismo ritmo pase lo que pase; quien se frena por detrás es el backend,
-- y eso no lo decide este lado.
idleNotice :: Text
idleNotice = refreshedEvery "Sin sesión en marcha"

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
