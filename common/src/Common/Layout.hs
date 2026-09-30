-- | Aritmética del __lienzo libre__: pegar a la rejilla, el tamaño mínimo por
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
-- agranda y no mueve nada; 'fitsAt' y 'overlaps' __informan__ y no corrigen.
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
    -- * Tamaño mínimo
  , minWidthFor
  , minHeightFor
  , clampToMin
    -- * Comprobaciones que informan
  , fitsAt
  , overlaps
  , touchesTopRight
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
-- sigue sin salir. Decidido el 2026-09-04.
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
-- en 60, o el par @telemetry@\/@lap-comparison@ en 35— no dejan una raya
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
-- pone quien llama; decidido el 2026-09-07.
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
-- encoger. En unidades de 'canvasSpan', así que en píxeles vale distinto en cada
-- ventana.
--
-- Medidos en Edge con la base de 12 px sobre un lienzo de 1861 × 845 px
-- (2026-09-29): el ancho más estrecho sin barra horizontal, redondeado __hacia
-- arriba__ a múltiplo de 5 para caer en celda del imán. Las celdas de las tablas no
-- parten nunca; lo que cede es la fila de botones de 'Telemetry', que baja de
-- línea, y 'LapComparison', que se apila. 'TyreStrategy' y 'Custom' no tienen
-- widget y conservan el número a ojo.
--
-- Si un widget cambia de contenido, su número se vuelve a medir.
minWidthFor :: WidgetType -> Int
minWidthFor LiveTiming       = 30
minWidthFor Telemetry        = 35
minWidthFor LapComparison    = 25
minWidthFor HistoricalStats  = 25
minWidthFor ConstructorStats = 20
minWidthFor TyreStrategy     = 30
minWidthFor Custom           = 25

-- | Alto mínimo de un tipo de widget, en unidades de 'canvasSpan': el título, su
-- control y una fila de datos; en 'LapComparison', la tabla de mando entera y la
-- leyenda. Medido y redondeado como 'minWidthFor'; 'TyreStrategy' y 'Custom'
-- llevan el menor de los medidos.
--
-- __No depende de la forma de la tarjeta:__ 'LapComparison' apilada pide 65, y
-- con este mínimo su leyenda queda bajo el scroll. En el lienzo medido no llega a
-- apilarse sin bajar de 'minWidthFor'.
minHeightFor :: WidgetType -> Int
minHeightFor LiveTiming       = 20
minHeightFor Telemetry        = 30
minHeightFor LapComparison    = 50
minHeightFor HistoricalStats  = 20
minHeightFor ConstructorStats = 20
minHeightFor TyreStrategy     = 20
minHeightFor Custom           = 20

-- | Sube el ancho y el alto de un widget hasta sus mínimos si vienen por debajo.
--
-- __Solo agranda. No mueve nada, nunca__, ni siquiera cuando el widget se sale
-- del lienzo: no toca 'wcX' ni 'wcY'.
--
-- Que se salga es asunto de 'fitsAt', que lo __informa__ para que el consumidor
-- pinte la marca de «aquí no cabe». Y el reparto es deliberado: si esta función
-- corrigiera el desbordamiento moviendo el widget, sobre un layout ya saneado
-- 'fitsAt' diría siempre que sí y __la marca no aparecería jamás__. Decidido el
-- 2026-09-04 (c).
clampToMin :: WidgetConfig -> WidgetConfig
clampToMin w = w
  { wcW = max (wcW w) (minWidthFor  (widgetType w))
  , wcH = max (wcH w) (minHeightFor (widgetType w))
  }

-- | Si un widget cabe donde dice estar: empieza dentro del lienzo, no baja de su
-- ancho ni de su alto mínimos, y no se sale ni por la derecha ni por abajo.
--
-- __Informa; no corrige.__ Es lo que alimenta la marca visible, y por eso tiene
-- que poder decir que no sobre una 'WidgetConfig' intacta.
fitsAt :: WidgetConfig -> Bool
fitsAt w =
  wcX w >= 0
    && wcY w >= 0
    && wcW w >= minWidthFor (widgetType w)
    && wcH w >= minHeightFor (widgetType w)
    && wcX w + wcW w <= canvasSpan
    && wcY w + wcH w <= canvasSpan

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

-- | Si el rectángulo de un widget __toca la esquina superior derecha del
-- lienzo__: empieza arriba del todo y acaba en el borde derecho.
--
-- Existe por una colisión concreta y no por simetría: el botón que pliega la
-- cabecera (2026-09-07 b) es @position: fixed@ en esa esquina de la ventana, así
-- que la tarjeta que la ocupa tiene ahí encima algo que no es suyo. El indicador
-- @● Live@ va al borde derecho de su tarjeta (2026-09-12), y en esa —y solo en
-- esa— quedaría debajo del botón.
--
-- __Informa; no corrige__, como 'fitsAt' y 'overlaps'. Cuánto hueco dejar y con
-- qué regla es cosa de la hoja de estilos, que es la que sabe lo que mide el
-- botón; aquí solo se dice __a quién__ le pasa. Emitir el hueco en los seis
-- widgets sería más simple y se vería como un sangrado sin motivo en los cinco
-- que no lo necesitan.
--
-- El borde es exacto y por eso la comparación es de igualdad: un widget que
-- acabe en 119 no toca la esquina, y uno que se pase de 'canvasSpan' tampoco
-- —que no quepa ya lo dice 'fitsAt'—.
touchesTopRight :: WidgetConfig -> Bool
touchesTopRight w = wcY w == 0 && wcX w + wcW w == canvasSpan

-- | Recorta una coordenada al lienzo. Privada: fuera de 'snapTo' invitaría a
-- sanear posiciones a mano, que es justo lo que 'fitsAt' existe para no hacer.
clampSpan :: Int -> Int
clampSpan = max 0 . min canvasSpan
