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
module Common.Origin
  ( Origin (..)
  , originHeader
  , fetchedAtHeader
  , originLabel
  , originFrom
  , originNotice
  ) where

import           Data.Text (Text)
import qualified Data.Text as T

-- | Cuál de los tres peldaños de la escalera sirvió el dato.
--
-- El orden de los constructores es el de la escalera, de mejor a peor, y no es
-- decorativo: el 'Ord' derivado permite quedarse con el peor de varios sin escribir
-- la comparación, que es lo que necesitará una página cuyos widgets no comparten
-- procedencia.
data Origin
  = -- | Recién traído de la fuente. Es el único que no se anuncia.
    Fresh
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
-- Solo tiene sentido acompañando a 'Cached' —de un dato fresco la hora es «ahora» y
-- de uno inventado no hay hora—, y por eso es una cabecera aparte y no un campo de
-- 'Origin': el tipo no tendría qué poner en dos de sus tres casos.
fetchedAtHeader :: Text
fetchedAtHeader = "X-Data-Fetched-At"

-- | El valor que viaja en la cabecera. Minúsculas y sin espacios: es un valor de
-- protocolo, no un texto para leer — el que se lee lo da 'originNotice'.
originLabel :: Origin -> Text
originLabel Fresh  = "fresh"
originLabel Cached = "cached"
originLabel Sample = "sample"

-- | La procedencia a partir del valor de la cabecera.
--
-- __La ausencia y lo irreconocible no son lo mismo, y aun así se tratan igual:__
-- 'Nothing'. Un valor que no se reconoce podría venir de un backend más nuevo que el
-- bundle, y adivinar sería peor que no saber; quien llama decide qué hacer con la
-- duda, y en 'Widgets.LiveTiming' esa decisión es no avisar de nada — la alternativa
-- (avisar por si acaso) llenaría de avisos falsos la página cada vez que se despliega
-- un backend nuevo.
--
-- Recorta y normaliza a minúsculas porque una cabecera atraviesa proxies y
-- reescrituras que no controlamos, y @\"Cached \"@ es el mismo valor.
originFrom :: Text -> Maybe Origin
originFrom raw =
  case T.toLower (T.strip raw) of
    "fresh"  -> Just Fresh
    "cached" -> Just Cached
    "sample" -> Just Sample
    _        -> Nothing

-- | El aviso que corresponde a una procedencia, o 'Nothing' si no hay nada que
-- avisar.
--
-- 'Fresh' da 'Nothing' por la misma razón que 'Common.Types.statusLabel' da cadena
-- vacía para @Running@ (2026-08-26): un aviso que aparece
-- siempre deja de leerse, y el caso normal no es una excepción que señalar.
--
-- La hora es argumento y no campo de 'Origin' porque solo 'Cached' la tiene, y llega
-- ya formateada: componer aquí el texto —en vez de dejar que lo concatene el
-- widget— es lo que permite probarlo, que es el motivo de que el módulo esté en
-- @common@. Un 'Cached' sin hora sigue avisando: perder el cuándo no convierte el
-- dato en fresco.
originNotice :: Origin -> Maybe Text -> Maybe Text
originNotice Fresh _ = Nothing
originNotice Cached at =
  Just (maybe base (\t -> base <> " (" <> t <> ")") (nonBlank =<< at))
  where
    base = "Dato guardado: la fuente no responde ahora mismo"
originNotice Sample _ =
  Just "Datos de ejemplo: la fuente nunca ha respondido"

-- | El texto si dice algo, 'Nothing' si está en blanco. Una cabecera presente pero
-- vacía es lo mismo que ausente, y sin esto el aviso acabaría en @\"… ()\"@.
nonBlank :: Text -> Maybe Text
nonBlank t = if T.null (T.strip t) then Nothing else Just (T.strip t)
