-- | Escalado de una serie a coordenadas de un @\<svg\>@ de tamaño fijo.
--
-- Primer gráfico del repo. Los cuatro widgets anteriores pintan tablas, así que
-- no había nada que escalar; 'Common.Types.LapComparison' trae @lcDelta@, que es
-- una serie, y una columna de 60 números no comunica una vuelta.
--
-- __Por qué esto vive en @common@ y no en el widget que lo usa.__ Es lógica de
-- presentación en el paquete de tipos, y conviene admitir que es un desvío. La
-- razón es que el paquete @frontend@ __no tiene suite de tests__: no está en
-- @cabal.project@ y solo se construye con GHCJS vía @nix build .#frontend@, así
-- que nada de lo que viva allí se puede probar hoy. @backend-test@ sí depende de
-- @common@. Como las dos funciones interesantes son justo las que tienen casos
-- límite con división por cero, la alternativa real era dejarlas sin cobertura
-- (2026-08-04). La solución de fondo —un @frontend-test@
-- bajo GHC nativo— es una sesión propia.
--
-- El módulo es __puro y sin Reflex__: entra una @[Double]@ y sale texto o
-- números. Quien monta el DOM es 'Widgets.Comparison'.
--
-- __Sin librería de gráficos.__ @ARCHITECTURE.md §2.2@ contempla Plotly\/Chart.js
-- vía FFI, y sigue siendo la salida el día que hagan falta tooltips o zoom; para
-- una polilínea son quince líneas puras contra servir un @.js@, escribir
-- @foreign import javascript@ y manejar que @dyn_@ re-monte el nodo bajo un
-- gráfico imperativo (2026-08-04).
module Common.Chart
  ( -- * Lienzo
    chartWidth
  , chartHeight
  , chartPad
    -- * Escalado
  , deltaRange
  , deltaPoints
  , deltaPolyline
  , zeroLineY
  ) where

import           Data.Text (Text)
import qualified Data.Text as T

-- | Ancho del @viewBox@. Es un sistema de coordenadas, no píxeles: el @\<svg\>@
-- se sirve con @width=\"100%\"@ y el navegador escala.
chartWidth :: Double
chartWidth = 600

-- | Alto del @viewBox@.
chartHeight :: Double
chartHeight = 200

-- | Margen interior, en las cuatro direcciones. Sin él la línea se recorta a la
-- mitad justo en los extremos, que es donde más se mira.
chartPad :: Double
chartPad = 10

-- | Rango del eje vertical para una serie. Dos garantías, y las dos son la
-- función entera:
--
-- * __Incluye siempre el cero__, aunque la serie no lo cruce. El cero es "iban
--   empatados": un eje @[min, max]@ de una serie toda positiva dibujaría la misma
--   forma que una toda negativa y el gráfico mentiría sobre quién iba delante.
--   De ahí el @0 :@ en las dos listas.
--
-- * __Nunca es degenerado__ (@lo \/= hi@), porque el resultado va a un
--   denominador. Ocurre en dos casos reales: la serie __vacía__ (que el
--   @Context@ del backend degrada a dummy, pero el widget no puede darlo por
--   hecho) y la serie __toda ceros__, que es @?drivers=1,1@ — una vuelta
--   comparada consigo misma. En ambos se abre a @(-1, 1)@, que centra la línea
--   del cero en vez de reventar.
deltaRange :: [Double] -> (Double, Double)
deltaRange xs
  | lo == hi  = (lo - 1, hi + 1)
  | otherwise = (lo, hi)
  where
    lo = minimum (0 : xs)
    hi = maximum (0 : xs)

-- | La serie como coordenadas del @viewBox@, en el mismo orden.
--
-- El índice da la X: @lcDelta@ es una serie a lo largo de la vuelta y el
-- microservicio ya la entrega submuestreada a paso regular, así que la posición
-- en la lista __es__ la distancia recorrida. No hay eje X que calcular.
deltaPoints :: [Double] -> [(Double, Double)]
deltaPoints xs =
  [ (scaleX (length xs) i, scaleY (deltaRange xs) v) | (i, v) <- zip [0 ..] xs ]

-- | Atributo @points@ de un @\<polyline\>@: @\"x,y x,y …\"@. La serie vacía da
-- @\"\"@, que es lo que hace que el widget pueda no dibujar nada sin un caso
-- especial aguas arriba.
--
-- __Coordenadas redondeadas a entero.__ Con un @viewBox@ de 600×200 la precisión
-- sobra, y evita el formato de 'show' sobre 'Double', que emite notación
-- científica para los valores pequeños (@1.0e-2@) — legal en SVG, pero ilegible
-- y molesto de comparar en un test.
deltaPolyline :: [Double] -> Text
deltaPolyline = T.unwords . map render . deltaPoints
  where
    render (x, y) = coord x <> "," <> coord y
    coord = T.pack . show . (round :: Double -> Int)

-- | Y del eje cero dentro del @viewBox@, para dibujar la línea de referencia.
-- Deriva del mismo 'deltaRange' que los puntos, así que la línea y la serie no
-- pueden desalinearse.
zeroLineY :: [Double] -> Double
zeroLineY xs = scaleY (deltaRange xs) 0

-- | X del punto @i@ de una serie de @n@. Con @n <= 1@ no hay @n-1@ por el que
-- dividir: el punto va al centro. Privada porque solo tiene sentido con la @n@
-- de la serie que se está pintando.
scaleX :: Int -> Int -> Double
scaleX n i
  | n <= 1    = chartWidth / 2
  | otherwise = chartPad + fromIntegral i * usableWidth / fromIntegral (n - 1)
  where
    usableWidth = chartWidth - 2 * chartPad

-- | Y de un valor dentro de un rango. __Invertida__: en SVG la Y crece hacia
-- abajo, así que el máximo de la serie va arriba.
--
-- Privada, y esa es la mitad de su seguridad: el único rango que la alcanza sale
-- de 'deltaRange', que garantiza @lo \/= hi@. Exponerla invitaría a pasarle un
-- @(0, 0)@ calculado a mano.
scaleY :: (Double, Double) -> Double -> Double
scaleY (lo, hi) v = chartPad + (hi - v) / (hi - lo) * (chartHeight - 2 * chartPad)
