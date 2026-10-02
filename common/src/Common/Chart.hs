-- | Escalado de una serie a coordenadas de un @\<svg\>@ de tamaño fijo.
--
-- Primer gráfico del repo. Los cuatro widgets anteriores pintan tablas, así que
-- no había nada que escalar; la Δ de Lap Comparison
-- ('Common.Comparison.deltasAgainst') es una serie, y una columna de números no
-- comunica una vuelta.
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
    -- * Fronteras
  , frontierCells
  , frontierCellsAt
    -- * Eje
  , axisRange
  , axisTicks
  , axisPoints
  , axisPolyline
  , axisZeroY
  ) where

import           Common.Format (formatDelta)
import           Data.Text     (Text)
import qualified Data.Text     as T

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
--   De ahí el @0@ como semilla de los dos pliegues.
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
    lo = foldr min 0 xs
    hi = foldr max 0 xs

-- | La serie como coordenadas del @viewBox@, en el mismo orden.
--
-- El índice da la X, y no hay eje X que calcular: la posición en la lista es el
-- __orden a lo largo de la vuelta__, que es lo único que la Δ garantiza.
--
-- __Cuidado con leer la X como distancia.__ Desde el 2026-08-11
-- la Δ son las cuatro __fronteras de sector__ —meta, fin de S1, fin de S2,
-- fin de vuelta—, y los sectores de un circuito no miden lo mismo, así que
-- repartirlas a espacio igual estira unos tramos y encoge otros. Es deliberado:
-- el eje X real exigiría que viajara en el DTO, y lo que el gráfico afirma —el
-- orden de las fronteras y el valor exacto en cada una— sigue siendo cierto.
-- Antes la afirmación era más fuerte y más falsa: que la posición __era__ la
-- distancia recorrida, sobre una serie submuestreada de un eje que resultó no
-- ser medible (ver 2026-08-10).
deltaPoints :: [Double] -> [(Double, Double)]
deltaPoints xs = pointsIn (deltaRange xs) xs

-- | Atributo @points@ de un @\<polyline\>@: @\"x,y x,y …\"@. La serie vacía da
-- @\"\"@, que es lo que hace que el widget pueda no dibujar nada sin un caso
-- especial aguas arriba.
--
-- __Coordenadas redondeadas a entero.__ Con un @viewBox@ de 600×200 la precisión
-- sobra, y evita el formato de 'show' sobre 'Double', que emite notación
-- científica para los valores pequeños (@1.0e-2@) — legal en SVG, pero ilegible
-- y molesto de comparar en un test.
deltaPolyline :: [Double] -> Text
deltaPolyline = polyline . deltaPoints

-- | Y del eje cero dentro del @viewBox@, para dibujar la línea de referencia.
-- Deriva del mismo 'deltaRange' que los puntos, así que la línea y la serie no
-- pueden desalinearse.
zeroLineY :: [Double] -> Double
zeroLineY xs = scaleY (deltaRange xs) 0

-- | La fila de debajo del gráfico: por cada frontera, la X de su punto en tanto
-- por ciento del ancho, su nombre y su valor ('Common.Format.formatDelta').
--
-- __Solo con las cuatro fronteras__ (@Inicio@, @S1@, @S2@, @S3@: cada punto lleva el
-- sector que acaba de terminar). Con cualquier otro número de valores la lista es
-- vacía: nombrar puntos que no son esas fronteras sería afirmar algo falso.
--
-- La X sale del mismo escalado que los puntos, así que cada valor queda debajo del
-- suyo aunque el @\<svg\>@ se estire.
frontierCells :: [Double] -> [(Double, Text, Text)]
frontierCells xs =
  frontierCellsAt [scaleX (length xs) i / chartWidth * 100 | i <- [0 .. length xs - 1]] xs

-- | 'frontierCells' con la X de cada frontera dada, en tanto por ciento del ancho:
-- la de las trazas, donde las fronteras no caen a espacio igual. Vacía si no son
-- cuatro X y cuatro valores.
frontierCellsAt :: [Double] -> [Double] -> [(Double, Text, Text)]
frontierCellsAt at xs
  | length xs == length names && length at == length names =
      [(x, name, formatDelta v) | (x, name, v) <- zip3 at names xs]
  | otherwise = []
  where
    names = ["Inicio", "S1", "S2", "S3"]

-- | El rango del eje vertical con las marcas: el de 'deltaRange' con cada extremo
-- alargado hasta el múltiplo del paso de 'axisTicks' más lejano del cero, cuando
-- el extremo queda igual o más cerca de él que del múltiplo más cercano al cero.
-- Contiene siempre a 'deltaRange', y coincide con él con la serie vacía o toda en
-- cero.
--
-- Es el rango que comparten las marcas y la curva cuando el eje se enseña, para que
-- conmutar entre «Valores» y «Eje» no cambie la escala.
axisRange :: [Double] -> (Double, Double)
axisRange xs
  | null xs || all (== 0) xs = deltaRange xs
  | otherwise                = stretch (axisStep xs) (deltaRange xs)

-- | Las marcas del eje vertical, de arriba abajo: su valor, su Y en el @viewBox@ y su
-- etiqueta ('Common.Format.formatDelta').
--
-- * La Y sale de 'axisRange', no de 'deltaRange': quien pinte la curva junto a las
--   marcas tiene que escalarla con ese mismo rango.
-- * Las marcas son los múltiplos de un paso redondo —1, 2 o 5 por una potencia de
--   diez, nunca menor que @0.001@, que es lo que 'formatDelta' distingue—: el menor
--   que deja como mucho 'axisMaxTicks' sin alargar y una más alargado. El cero es
--   múltiplo de todos, así que siempre sale.
-- * Con la serie toda en cero solo sale el cero, y con la serie vacía nada: el rango
--   @(-1, 1)@ de esos dos casos no sale de los datos.
axisTicks :: [Double] -> [(Double, Double, Text)]
axisTicks xs
  | null xs       = []
  | all (== 0) xs = [tick 0]
  | otherwise     = [tick (fromIntegral k * step) | k <- [kHi, kHi - 1 .. kLo]]
  where
    range      = axisRange xs
    step       = axisStep xs
    (kLo, kHi) = multiplesIn step range
    tick v     = (v, scaleY range v, formatDelta v)

-- | La serie como coordenadas del @viewBox@, escalada con 'axisRange': la curva que
-- casa con las marcas de 'axisTicks'. Misma X que 'deltaPoints'.
axisPoints :: [Double] -> [(Double, Double)]
axisPoints xs = pointsIn (axisRange xs) xs

-- | Atributo @points@ de 'axisPoints', con el formato de 'deltaPolyline'.
axisPolyline :: [Double] -> Text
axisPolyline = polyline . axisPoints

-- | Y del cero con el rango de 'axisRange'; es la Y de la marca @0.000 s@.
axisZeroY :: [Double] -> Double
axisZeroY xs = scaleY (axisRange xs) 0

-- | Tope de marcas antes de alargar. El alargamiento puede añadir una, nunca dos.
axisMaxTicks :: Integer
axisMaxTicks = 7

-- | El paso de 'axisTicks' para una serie con algún valor distinto de cero.
axisStep :: [Double] -> Double
axisStep xs = tickStep (until fits (+ 1) 0)
  where
    raw = deltaRange xs
    fits n =
      let s = tickStep n
      in count s raw <= axisMaxTicks && count s (stretch s raw) <= axisMaxTicks + 1
    count s r = let (a, b) = multiplesIn s r in b - a + 1

-- | Los dos extremos de un rango, alargados según la regla de 'axisRange'.
stretch :: Double -> (Double, Double) -> (Double, Double)
stretch s (lo, hi) = (reach lo, reach hi)
  where
    reach v
      | offset < 1e-9       = v
      | offset >= 0.5 - 1e-9 = fromIntegral (near + away) * s
      | otherwise           = v
      where
        q      = v / s
        near   = if q >= 0 then floor (q + 1e-9) else ceiling (q - 1e-9) :: Integer
        away   = if q >= 0 then 1 else -1
        offset = abs (q - fromIntegral near)

-- | Los múltiplos enteros del paso dentro de un rango. La holgura recupera el
-- extremo que la coma flotante deja a una milmillonésima de paso de un múltiplo.
multiplesIn :: Double -> (Double, Double) -> (Integer, Integer)
multiplesIn s (lo, hi) = (ceiling (lo / s - 1e-9), floor (hi / s + 1e-9))

-- | El paso @n@-ésimo de la serie @0.001, 0.002, 0.005, 0.01, …@.
tickStep :: Int -> Double
tickStep n = mantissa * 10 ^^ (decade - 3)
  where
    (decade, m) = n `divMod` 3
    mantissa = case m of
      0 -> 1
      1 -> 2
      _ -> 5

-- | La serie escalada con un rango dado: el índice da la X y el rango la Y.
pointsIn :: (Double, Double) -> [Double] -> [(Double, Double)]
pointsIn range xs =
  [ (scaleX (length xs) i, scaleY range v) | (i, v) <- zip [0 ..] xs ]

-- | Coordenadas como atributo @points@, redondeadas a entero (ver 'deltaPolyline').
polyline :: [(Double, Double)] -> Text
polyline = T.unwords . map render
  where
    render (x, y) = coord x <> "," <> coord y
    coord = T.pack . show . (round :: Double -> Int)

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
-- Privada, y esa es la mitad de su seguridad: los rangos que la alcanzan salen de
-- 'deltaRange', que garantiza @lo \/= hi@, o de 'axisRange', que lo contiene.
-- Exponerla invitaría a pasarle un @(0, 0)@ calculado a mano.
scaleY :: (Double, Double) -> Double -> Double
scaleY (lo, hi) v = chartPad + (hi - v) / (hi - lo) * (chartHeight - 2 * chartPad)
