-- | De dónde sale el dato que un endpoint acaba de servir.
--
-- La escalera @try@ → cache → dummy (2026-07-22) tiene __tres
-- salidas buenas__ y hasta hoy las tres se servían iguales: un @200@ indistinguible.
-- Con la fuente de OpenF1 devolviendo @401@ durante las sesiones en vivo
-- (2026-09-06 b) eso dejó de ser un detalle — la página enseña
-- el dummy como si fuera la carrera—, así que la procedencia pasa a viajar con la
-- respuesta.
--
-- __Es ortogonal a "Outcome" y por eso no es un constructor suyo.__ Aquél responde
-- «¿merece respuesta esta petición?» y solo lo usan las tres áreas que hablan con el
-- microservicio; éste responde «¿de dónde salió lo que devuelvo?» y aplica a las
-- seis. Fundirlos obligaría a @live@ a adoptar @Outcome@, que el 2026-08-14 dejó
-- fuera a propósito.
--
-- __Vive en @common@ y no en el backend__ porque lo consumen los dos extremos: el
-- backend lo emite y el widget lo lee para decidir si avisa. Es el criterio del
-- 2026-08-04 —lo puro y sin Reflex va a @common@, que es lo único con suite—, el
-- mismo que trajo 'Common.Format' y 'Common.Layout'.
--
-- __El módulo responde dos preguntas, y son independientes.__ 'Origin' dice __qué
-- peldaño__ de la escalera sirvió el dato; 'Source' dice __de qué fuente__ salió.
-- Un dato fresco puede venir del feed o de OpenF1, y uno guardado conserva la
-- fuente que tenía cuando se guardó. Cruzarlas en un solo tipo daría seis valores
-- de los que dos no existen —el respaldo estático no tiene fuente— y obligaría a
-- cada lector a casar contra casos que no le llegan.
module Common.Origin
  ( Origin (..)
  , originHeader
  , fetchedAtHeader
  , originLabel
  , originFrom
  , originNotice
  , Source (..)
  , sourceHeader
  , sourceLabel
  , sourceFrom
  , sourceName
  , Sourced (..)
  , sourcedHeaders
  , sourcedFrom
  ) where

import           Data.Text (Text)
import qualified Data.Text as T

-- | Qué sirvió el dato.
--
-- __No son los peldaños de la escalera, y dejaron de serlo el 2026-09-18:__ lo
-- guardado tiene dos lecturas —servirlo porque aún vale o servirlo porque no hubo
-- otra— y el peldaño es el mismo. Lo que este tipo dice es __por qué__ se sirvió eso,
-- que es lo que decide si hay algo que avisar.
--
-- El orden de los constructores es de mejor a peor, y no es decorativo: el 'Ord'
-- derivado permite quedarse con el peor de varios sin escribir la comparación, que es
-- lo que necesitará una página cuyos widgets no comparten procedencia.
data Origin
  = -- | Recién traído de la fuente. El único que 'originNotice' no redacta, que
    -- desde el 2026-09-11 (d) no es lo mismo que no anunciarse.
    Fresh
  | -- | Lo guardado, servido __porque aún vale__ y no porque nadie contestara: el
    -- backend decidió no volver a preguntar tan pronto.
    --
    -- __Existe para que 'Cached' siga significando una sola cosa.__ Desde que el
    -- backend se frena a sí mismo para caber en el presupuesto de la fuente
    -- (2026-09-17: OpenF1 acepta 30 peticiones por minuto), la mayoría de las
    -- respuestas salen de lo guardado sin que nada haya fallado. Servirlas como
    -- 'Cached' haría que su aviso —«la fuente no responde ahora mismo»— fuese falso
    -- la mayor parte del tiempo, y con él la única señal de fallo que tiene la
    -- página.
    --
    -- __Va aquí y no al final por el 'Ord', que es la escalera de mejor a peor:__
    -- un dato de hace segundos que nadie quiso repetir es peor que uno recién
    -- traído y mejor que uno que se sirve porque no hubo otra.
    Recent
  | -- | La última respuesta buena guardada. El dato fue cierto; la duda es cuándo.
    Cached
  | -- | El respaldo estático. Nunca fue cierto, y es el que obliga a avisar.
    Sample
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Cabecera que transporta la procedencia.
--
-- Se eligió cabecera y no envoltorio del JSON (decisión del 2026-09-11) para que los
-- seis endpoints sigan devolviendo __exactamente__ el mismo cuerpo: ni los DTO de
-- este paquete ni los widgets cambian de forma. El precio es que no se ve sin
-- @curl -i@, y está aceptado a sabiendas.
originHeader :: Text
originHeader = "X-Data-Origin"

-- | Cabecera con el instante en que se trajo el dato, en ISO 8601.
--
-- Solo tiene sentido acompañando a los dos que salen de lo guardado, 'Recent' y
-- 'Cached' —de un dato fresco la hora es «ahora» y de uno inventado no hay hora—, y
-- por eso es una cabecera aparte y no un campo de 'Origin': el tipo no tendría qué
-- poner en los otros dos casos.
fetchedAtHeader :: Text
fetchedAtHeader = "X-Data-Fetched-At"

-- | El valor que viaja en la cabecera. Minúsculas y sin espacios: es un valor de
-- protocolo, no un texto para leer — el que se lee lo da 'originNotice'.
originLabel :: Origin -> Text
originLabel Fresh  = "fresh"
originLabel Recent = "recent"
originLabel Cached = "cached"
originLabel Sample = "sample"

-- | La procedencia a partir del valor de la cabecera.
--
-- __La ausencia y lo irreconocible no son lo mismo, y aun así se tratan igual:__
-- 'Nothing'. Un valor que no se reconoce podría venir de un backend más nuevo que el
-- bundle, y adivinar sería peor que no saber; quien llama decide qué hacer con la
-- duda, y desde el 2026-09-12 esa decisión la toma 'Common.Indicator': __decirla__,
-- con el punto gris y «Procedencia desconocida». Callar dejó de ser una salida
-- cuando el indicador pasó a estar siempre en pantalla — lo que se elige ya no es
-- si se pinta algo, sino qué se pinta cuando no se sabe.
--
-- Recorta y normaliza a minúsculas porque una cabecera atraviesa proxies y
-- reescrituras que no controlamos, y @\"Cached \"@ es el mismo valor.
originFrom :: Text -> Maybe Origin
originFrom raw =
  case T.toLower (T.strip raw) of
    "fresh"  -> Just Fresh
    "recent" -> Just Recent
    "cached" -> Just Cached
    "sample" -> Just Sample
    _        -> Nothing

-- | El aviso que corresponde a una procedencia, o 'Nothing' si no hay nada que
-- avisar.
--
-- __'Fresh' da 'Nothing' porque aquí no hay nada que redactar, no porque no se
-- anuncie.__ Hasta el 2026-09-11 eran lo mismo, con el argumento de
-- 'Common.Types.statusLabel' (2026-08-26): lo que aparece siempre deja de leerse, y
-- el caso normal no es una excepción que señalar. El indicador de 2026-09-11 (d) lo
-- revoca — con refresco de verdad, que el dato sea fresco __es__ la señal, la de que
-- lo que se lee está pasando ahora —, pero esa la pinta 'Common.Indicator' con su
-- propio texto y su parpadeo, y no una frase de este módulo.
--
-- La hora es argumento y no campo de 'Origin' porque solo 'Cached' la tiene, y llega
-- ya formateada: componer aquí el texto —en vez de dejar que lo concatene el
-- widget— es lo que permite probarlo, que es el motivo de que el módulo esté en
-- @common@. Un 'Cached' sin hora sigue avisando: perder el cuándo no convierte el
-- dato en fresco.
originNotice :: Origin -> Maybe Text -> Maybe Text
originNotice Fresh _ = Nothing
originNotice Recent at = Just (withInstant at "Dato reciente: no se ha vuelto a preguntar")
originNotice Cached at =
  Just (withInstant at "Dato guardado: la fuente no responde ahora mismo")
originNotice Sample _ =
  Just "Datos de ejemplo: la fuente nunca ha respondido"

-- | El aviso con la hora entre paréntesis si la hay.
--
-- __Lo comparten los dos que salen de lo guardado__, porque el paréntesis es del
-- hecho de estar guardado y no del motivo: escribirlo dos veces dejaría que uno
-- cambiara de forma sin el otro.
withInstant :: Maybe Text -> Text -> Text
withInstant at base = maybe base (\t -> base <> " (" <> t <> ")") (nonBlank =<< at)

-- | De qué fuente salió el dato.
--
-- Las dos son __complementarias y no redundantes__ (2026-09-12 (h)): el feed publica
-- mientras la sesión rueda y calla después; OpenF1 cierra con @401@ mientras rueda y
-- abre después. Por eso ninguna sustituye a la otra y la respuesta tiene que decir
-- cuál contestó.
--
-- No hay constructor para el respaldo estático: no salió de ninguna fuente, y por eso
-- la cabecera __falta__ en ese caso en vez de llevar un valor inventado.
data Source
  = -- | El feed oficial de cronometraje, a través del microservicio.
    Feed
  | -- | La API pública de OpenF1.
    OpenF1
  deriving stock (Eq, Show, Enum, Bounded)

-- | Cabecera que transporta la fuente.
--
-- Es una tercera cabecera y no un campo de 'Origin' por lo mismo que
-- 'fetchedAtHeader': hay un peldaño que no tiene qué poner en ella.
sourceHeader :: Text
sourceHeader = "X-Data-Source"

-- | El valor que viaja en la cabecera. Minúsculas y sin espacios, como
-- 'originLabel': es un valor de protocolo, no un texto para leer.
sourceLabel :: Source -> Text
sourceLabel Feed   = "feed"
sourceLabel OpenF1 = "openf1"

-- | La fuente a partir del valor de la cabecera, con el criterio de 'originFrom':
-- recorta, normaliza a minúsculas y __no adivina__.
sourceFrom :: Text -> Maybe Source
sourceFrom raw =
  case T.toLower (T.strip raw) of
    "feed"   -> Just Feed
    "openf1" -> Just OpenF1
    _        -> Nothing

-- | El nombre de la fuente para leerlo, que es lo que enseña el tooltip.
--
-- Va aparte de 'sourceLabel' porque uno lo lee una persona y el otro una máquina:
-- fundirlos ataría el texto de la pantalla al valor del protocolo.
sourceName :: Source -> Text
sourceName Feed   = "Feed oficial"
sourceName OpenF1 = "OpenF1"

-- | El texto si dice algo, 'Nothing' si está en blanco. Una cabecera presente pero
-- vacía es lo mismo que ausente, y sin esto el aviso acabaría en @\"… ()\"@.
nonBlank :: Text -> Maybe Text
nonBlank t = if T.null (T.strip t) then Nothing else Just (T.strip t)

-- | Un valor junto con la procedencia que traían las cabeceras de su respuesta.
--
-- Es lo que el widget tiene en la mano tras leer la respuesta: el cuerpo ya
-- decodificado y lo que dijeron las dos cabeceras. La procedencia va en 'Maybe'
-- porque la duda es un caso real —cabecera ausente o irreconocible, ver
-- 'originFrom'— y el widget decide qué pintar con ella.
data Sourced a = Sourced
  { srcOrigin    :: Maybe Origin
    -- ^ 'Nothing' si la cabecera no llegó o no se reconoce.
  , srcSource    :: Maybe Source
    -- ^ 'Nothing' si la cabecera no llegó, no se reconoce o el dato no salió de
    -- ninguna fuente.
  , srcFetchedAt :: Maybe Text
    -- ^ El instante tal cual viaja, recortado; 'Nothing' si falta o está en blanco.
  , srcValue     :: a
  }
  deriving stock (Eq, Show)

-- | Las cabeceras que 'sourcedFrom' lee, y por tanto las que hay que pedir.
--
-- __Existe porque pedir y leer son dos sitios que tienen que decir lo mismo.__ Un
-- cliente XHR declara qué cabeceras de respuesta quiere y las demás no le llegan,
-- así que una que se lea aquí sin pedirse allí sale __siempre__ ausente — y la
-- ausencia es un caso legítimo ('sourcedFrom'), no un error, o sea que nadie se
-- entera. Con una sola lista no hay dos que puedan divergir.
sourcedHeaders :: [Text]
sourcedHeaders = [originHeader, sourceHeader, fetchedAtHeader]

-- | Arma un 'Sourced' a partir de una forma de buscar cabeceras por nombre.
--
-- __Recibe la búsqueda como función y no el mapa de cabeceras__ porque las del XHR
-- vienen con claves que ignoran mayúsculas (@CI Text@, del paquete
-- @case-insensitive@), y traerlo aquí haría depender a @common@ de él solo por la
-- clave. Quien llama sabe cómo buscar; aquí se decide qué significa lo encontrado.
--
-- __Quien llama tiene que haber pedido 'sourcedHeaders'__: lo que no se pida llega
-- ausente, y ausente aquí significa duda y no fallo.
sourcedFrom :: (Text -> Maybe Text) -> a -> Sourced a
sourcedFrom lookupHeader value =
  Sourced
    { srcOrigin    = originFrom =<< lookupHeader originHeader
    , srcSource    = sourceFrom =<< lookupHeader sourceHeader
    , srcFetchedAt = nonBlank =<< lookupHeader fetchedAtHeader
    , srcValue     = value
    }
