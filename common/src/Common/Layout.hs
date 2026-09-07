-- | Aritmética del __lienzo libre__: pegar a la rejilla, el ancho mínimo por
-- widget, si un widget cabe donde dice estar, y la traducción de su rectángulo a
-- CSS.
--
-- Desde el 2026-09-03 un 'Common.Types.Layout' no es una
-- lista cuyo orden coloca ni un árbol cuyos hermanos reparten: cada widget lleva
-- __posición y tamaño propios, independientes de los demás__, los huecos vacíos
-- son legales, y al arrastrar hay imán a una rejilla de 24×24. Este módulo es la
-- parte de eso que se puede calcular sin DOM.
--
-- __La unidad es 1\/120 del contenedor__ y no la centésima (2026-09-04): con 120
-- el paso del imán es @120\/24 = 5@ __exacto__, mientras con 100 salía 4.166… y
-- había que alternar pasos de 4 y de 5. Ver 'canvasSpan'.
--
-- __Por qué esto vive en @common@ y no en el frontend que lo usa.__ Es la misma
-- razón que 'Common.Chart' documenta desde el 2026-08-04: el paquete @frontend@
-- __no tiene suite__ —no está en @cabal.project@ y solo se construye con GHCJS
-- vía @nix build .#frontend@—, así que nada de lo que viva allí se puede probar
-- hoy. @backend-test@ sí depende de @common@. Y aquí aprieta más que en el
-- gráfico: 'Common.Types.Pages.Dashboard' solo compila bajo GHCJS, o sea que un
-- error suyo no aparece hasta el build completo.
--
-- __Ninguna función de este módulo decide una política.__ 'clampToMin' solo
-- ensancha y no mueve nada; 'fitsAt' y 'overlaps' __informan__ y no corrigen.
-- Quién pinta la marca de «aquí no cabe», si el encimado se permite y qué hace
-- el lienzo en pantalla estrecha son cosas del consumidor y preguntas abiertas
-- del @ROADMAP.md@, y no se cierran de tapadillo dentro de una función pura.
module Common.Layout
  ( -- * El lienzo
    canvasSpan
  , gridDivisions
    -- * El slot
  , slotStyle
  , spanCss
    -- * Imán
  , snapTo
    -- * Ancho mínimo
  , minWidthFor
  , clampToMin
    -- * Comprobaciones que informan
  , fitsAt
  , overlaps
  ) where

import           Common.Types (WidgetConfig (..), WidgetType (..))
import           Data.Text    (Text)
import qualified Data.Text    as T

-- | Lado del lienzo, en sus propias unidades: __120__, en los dos ejes.
--
-- No es una centésima y el número no es arbitrario. La rejilla del imán es de
-- 24×24 (ver 'gridDivisions') y el paso tiene que ser entero: @120\/24 = 5@
-- exacto, contra el @100\/24 = 4.166…@ que obligaba a pasos alternos de 4 y de 5.
-- Con 120 caen en celda la mitad (60), el tercio (40), el cuarto (30) y el sexto
-- (20); el quinto es 24, exacto como número aunque el imán no lo alcance — que es
-- media respuesta al riesgo «24 no divide entre 5» del 2026-09-03. El séptimo
-- sigue sin salir. Ver (2026-09-04).
canvasSpan :: Int
canvasSpan = 120

-- | Divisiones de la rejilla del imán por eje: __24__.
--
-- Es el valor por defecto y no el único: 'snapTo' acepta cualquiera, porque el
-- 2026-09-03 pide un interruptor visible y una tecla que invierta el imán
-- mientras dura el arrastre.
gridDivisions :: Int
gridDivisions = 24

-- | Una medida en unidades del lienzo, como longitud CSS: @35@ sale como
-- @calc(35 * 100% \/ 120)@.
--
-- __El @calc@ es la decisión, no un detalle de escritura__ (2026-09-07). La otra
-- salida era emitir el porcentaje ya dividido, y no es equivalente: @35@ da
-- @29.1666…@, o sea que habría que elegir cuántos decimales y aceptar el error
-- que dejan. Con @calc@ la división __no se hace aquí__: viajan el numerador y el
-- denominador tal cual y la resuelve el navegador a precisión de subpíxel.
--
-- Lo que eso compra es __exactitud en los bordes compartidos__, que es donde el
-- redondeo se vería. Dos widgets pegados —uno acabando en 60 y el otro empezando
-- en 60, el caso que el par @telemetry@\/@telemetry-2@ produce— no dejan una raya
-- de fondo entre ellos ni se montan un píxel, porque
-- @calc(60 * 100% \/ 120)@ y @calc(60 * 100% \/ 120)@ son __la misma cantidad__ y
-- no dos redondeos que casi coinciden. Lo que se paga es que el inspector del
-- navegador muestra la expresión y no el porcentaje.
--
-- __No recorta ni valida__: una coordenada fuera del lienzo se traduce igual, y
-- decir que no cabe es cosa de 'fitsAt'.
spanCss :: Int -> Text
spanCss v =
  "calc(" <> T.pack (show v) <> " * 100% / " <> T.pack (show canvasSpan) <> ")"

-- | Estilo del __slot__ de un widget: los cuatro bordes de su rectángulo como
-- declaraciones CSS, listas para el atributo @style@.
--
-- El slot es la caja que __envuelve__ al widget y lo coloca. El widget no sabe
-- dónde va —@renderWidget@ despacha por tipo y nada más—, así que el rectángulo lo
-- pone quien llama; ver (2026-09-07).
--
-- __Emite la posición y el tamaño, y nada más.__ Ni @position: absolute@, ni el
-- separador entre widgets, ni el @z-index@: eso es política del lienzo y vive en
-- la hoja de estilos, junto a la regla de @.widget-slot@. Aquí solo está lo que
-- __depende del dato__ y por eso no puede estar en un fichero @.css@.
slotStyle :: WidgetConfig -> Text
slotStyle w = T.intercalate "; "
  [ "left: "   <> spanCss (wcX w)
  , "top: "    <> spanCss (wcY w)
  , "width: "  <> spanCss (wcW w)
  , "height: " <> spanCss (wcH w)
  ]

-- | Pega una coordenada a una rejilla de N divisiones, y la deja siempre dentro
-- del lienzo.
--
-- Con @'gridDivisions'@ el resultado es múltiplo de 5, que es el paso exacto.
--
-- __@divisions \<= 0@ es el imán apagado__, no un error: devuelve la coordenada
-- tal cual, solo recortada al lienzo. Es el estado que pide el interruptor del
-- 2026-09-03, así que el consumidor no necesita un camino aparte para él.
--
-- __Es idempotente__, y esa es la mitad de la función: pegar algo ya pegado no lo
-- mueve. Sin esa garantía, arrastrar dos veces desplazaría el widget sin que el
-- usuario lo pida, y es el defecto que no se ve mirando. Lo consigue el doble
-- redondeo al centro —a celda, y de vuelta a unidades—, y está comprobado por
-- fuerza bruta sobre las 120 divisiones y todo el rango de coordenadas, no solo
-- sobre las que dividen a 120.
snapTo :: Int -> Int -> Int
snapTo divisions v
  | divisions <= 0 = clampSpan v
  | otherwise      = clampSpan ((cell * canvasSpan + divisions `div` 2) `div` divisions)
  where
    cell = (clampSpan v * divisions + canvasSpan `div` 2) `div` canvasSpan

-- | Ancho mínimo de un tipo de widget, por debajo del cual el lienzo no deja
-- encoger. En unidades de 'canvasSpan'.
--
-- __Los siete números son a ojo__ hasta que se midan en navegador, y el riesgo
-- está escrito desde el 2026-09-03 (d): un mínimo demasiado grande se nota como
-- «no me deja hacerlo pequeño» sin decir por qué. Salen del contenido de cada
-- widget y no de una configuración — 'LiveTiming', con siete columnas, pide más
-- que 'ConstructorStats', con tres:
--
-- * 'LiveTiming' — @Pos@, @Driver@, @Team@, @Gap@, @Interval@, @Last Lap@ y la
--   marca de estado.
-- * 'Telemetry' — ocho magnitudes por muestra más el selector de piloto.
-- * 'LapComparison' — dos desplegables de parrilla más el @\<svg\>@ de
--   'Common.Chart'.
-- * 'HistoricalStats' \/ 'ConstructorStats' — nombre, @Puntos@ y @Victorias@; el
--   nombre del constructor es más corto.
-- * 'TyreStrategy' y 'Custom' son hoy placeholders; sus números entran cuando el
--   widget exista.
--
-- __Vive aquí y no en @frontend\/Widgets\/*@__, que es donde el 2026-09-03 (d)
-- los había puesto. La razón es de largo plazo: por el 2026-09-03 (c) una caja
-- __conmuta de contenido__, así que su ancho mínimo real será el máximo de los
-- mínimos de su lista de favoritos, y ese cálculo necesita los siete números
-- __como valor__. Repartidos por widget, la caja tendría que importar los seis
-- para calcular uno — o sea el @case@ de @renderWidget@ duplicado, que es
-- justamente el trabajo que ese punto señala. Lo que se pierde es la cercanía del
-- número al contenido que lo justifica, y lo recupera la lista de arriba. Ver
-- (2026-09-04 b).
minWidthFor :: WidgetType -> Int
minWidthFor LiveTiming       = 55
minWidthFor Telemetry        = 50
minWidthFor LapComparison    = 45
minWidthFor HistoricalStats  = 35
minWidthFor ConstructorStats = 30
minWidthFor TyreStrategy     = 30
minWidthFor Custom           = 25

-- | Sube el ancho de un widget hasta su mínimo si viene por debajo.
--
-- __Solo ensancha. No mueve nada, nunca__, ni siquiera cuando el widget se sale
-- del lienzo por la derecha: no toca 'wcX', ni 'wcY', ni 'wcH'.
--
-- Que se salga es asunto de 'fitsAt', que lo __informa__ para que el consumidor
-- pinte la marca de «aquí no cabe». Y el reparto es deliberado: si esta función
-- corrigiera el desbordamiento moviendo el widget a la izquierda, sobre un layout
-- ya saneado 'fitsAt' diría siempre que sí y __la marca no aparecería jamás__.
-- Ver (2026-09-04 c).
clampToMin :: WidgetConfig -> WidgetConfig
clampToMin w = w { wcW = max (wcW w) (minWidthFor (widgetType w)) }

-- | Si un widget cabe donde dice estar: empieza dentro del lienzo, no baja de su
-- ancho mínimo, y no se sale por la derecha.
--
-- __Informa; no corrige.__ Es lo que alimenta la marca visible, y por eso tiene
-- que poder decir que no sobre una 'WidgetConfig' intacta.
--
-- __Mira solo el eje horizontal__, y es a propósito. Por el 2026-09-03 (d) el
-- alto solo lleva un mínimo muy pequeño —título y su control—, porque encoger el
-- alto ya se resuelve con el scroll vertical que la tarjeta tiene desde el
-- 2026-08-21. A lo ancho, en cambio, la barra es el último recurso (2026-09-04 c)
-- y por eso hay algo que avisar antes de llegar a ella.
fitsAt :: WidgetConfig -> Bool
fitsAt w =
  wcX w >= 0
    && wcW w >= minWidthFor (widgetType w)
    && wcX w + wcW w <= canvasSpan

-- | Si los rectángulos de dos widgets se enciman.
--
-- __No decide qué hacer con el solape.__ Si dos widgets pueden encimarse como las
-- ventanas de un escritorio sigue siendo __pregunta abierta__ del @ROADMAP.md@,
-- anotada para responderse viendo el lienzo funcionando. Esta función existe para
-- poder responderla __midiendo__, no para prohibirlo por adelantado.
--
-- __El borde compartido no cuenta.__ Dos widgets pegados —uno acabando en 60 y el
-- otro empezando en 60— no se solapan, y es el caso que el grupo acoplado del
-- 2026-09-03 (b) va a producir constantemente, porque el borde entre dos miembros
-- __es__ un separador compartido. De ahí que las comparaciones sean estrictas:
-- cada widget ocupa @[x, x+w)@ y no @[x, x+w]@.
--
-- Un widget __contenido__ en otro sí solapa, y un widget solapa consigo mismo:
-- son solapes de verdad y no casos límite que esconder. Lo que sí es degenerado
-- es un widget de ancho o alto cero, que 'clampToMin' impide en el ancho.
overlaps :: WidgetConfig -> WidgetConfig -> Bool
overlaps a b =
  overlaps1 (wcX a) (wcW a) (wcX b) (wcW b)
    && overlaps1 (wcY a) (wcH a) (wcY b) (wcH b)
  where
    overlaps1 p s q t = p < q + t && q < p + s

-- | Recorta una coordenada al lienzo. Privada: fuera de 'snapTo' invitaría a
-- sanear posiciones a mano, que es justo lo que 'fitsAt' existe para no hacer.
clampSpan :: Int -> Int
clampSpan = max 0 . min canvasSpan
