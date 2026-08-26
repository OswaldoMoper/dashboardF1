{-# LANGUAGE OverloadedStrings #-}

-- | Formateo de cifras para las tablas del dashboard.
--
-- Vive en @common@ y no en cada widget por dos razones. La primera es que los
-- consumidores son __dos áreas__ ('Widgets.Historical' y 'Widgets.Telemetry') y el
-- mismo defecto estaba en las dos. La segunda
-- es que así es __puro y testeable__: el paquete @frontend@ no tiene suite —solo
-- compila con GHCJS— así que la lógica pura del lado cliente se prueba mudándola
-- aquí, que es el criterio con el que nació 'Common.Chart'
-- (2026-08-04). Es un módulo nuevo y no una función más en 'Common.Chart' porque
-- aquél es lógica de gráfico; meter el formateo allí lo convertiría en el cajón de
-- sastre que esa decisión se propuso evitar.
--
-- __Qué arregla, medido el 2026-08-26 contra los endpoints en marcha:__
--
-- * @T.pack (show (hsPoints s))@ pintaba @\"393.0\"@ donde Jolpica da 393 puntos.
-- * @show@ sobre 'Double' usa __notación científica__ para magnitudes pequeñas, así
--   que la columna @throttle@ de telemetría mostraba literalmente @\"1.0e-2\"@ —hay
--   valores de @0.01@ y @0.03@ en la respuesta real— y @tpDistance@ salía con 17
--   dígitos (@\"5.936944444444445\"@). Eso último es la causa del @overflow-x@ que
--   la deuda anotada atribuía al no-formateo: el scroll hacía la
--   tabla legible, no estrecha.
--
-- __El redondeo es @half-to-even@ y no @half-up__, porque es el de
-- 'Numeric.showFFloat' de @base@ y no se envuelve para cambiarlo: @1.5@ va a @2@
-- pero @2.5@ __también__ va a @2@, y @0.5@ va a @0@. Medido, no supuesto. Envolverlo
-- para redondear siempre hacia arriba sería reimplementar el formateo de coma
-- flotante de @base@ para ganar un dígito en el último decimal de una tabla que se
-- lee de un vistazo.
module Common.Format
  ( formatFixed
  , formatTrimmed
  , noData
  ) where

import           Data.Text (Text)
import qualified Data.Text as T
import           Numeric   (showFFloat)

-- | Lo que se pinta cuando no hay cifra que pintar: una raya, __que no es un cero__.
--
-- Un @0@ afirmaría un dato que nadie dio; es la distinción que
-- 'Common.Types.hsWins' existe para conservar. Está aquí y no en el widget para que
-- la raya tenga __una sola definición__ en el repo: la usan tanto el @Nothing@ de
-- 'Common.Types.hsWins' como la rama de no-finito de las dos funciones de abajo.
noData :: Text
noData = "—"

-- | Cifra con __exactamente__ el número de decimales pedido.
--
-- Para columnas donde el alineado comunica: con @tabular-nums@ y el mismo número de
-- decimales en todas las filas, las cifras no bailan. Nunca emite notación
-- científica (comprobado hasta @1.2e7@ y @5.0e-4@), que es la misma propiedad que
-- 'Common.Chart' necesita de sus coordenadas.
--
-- Un número de decimales negativo se trata como @0@; no hay forma de expresar
-- «redondea a decenas» en esta API y fingir que sí la hay sería peor que ignorarlo.
--
-- __No-finito da 'noData'.__ 'Numeric.showFFloat' emitiría @\"NaN\"@ o
-- @\"Infinity\"@, o sea una palabra inglesa en una celda de cifras, y es el
-- quinto no-dato que llega por esta clase de puerta —el @NaN@ de 2026-07-31 venía
-- justo de FastF1, que es la fuente de 'Common.Types.TelemetryPoint'—. La raya dice
-- «no hay cifra», que es exactamente lo que un @NaN@ significa aquí.
formatFixed :: Int -> Double -> Text
formatFixed decimals x
  | isNaN x || isInfinite x = noData
  | otherwise = T.pack (showFFloat (Just (max 0 decimals)) x "")

-- | Cifra con __hasta__ el número de decimales pedido: los ceros de cola y el punto
-- que queda suelto se retiran.
--
-- Para columnas donde el decimal es la excepción y no la regla. Los puntos de la
-- clasificación son el caso: Jolpica los publica como 'Double' porque la F1 reparte
-- medios puntos, pero casi siempre son enteros, y @\"393.0\"@ afirma una precisión
-- que no aporta nada mientras @\"393.5\"@ sí.
--
-- El recorte solo mira lo que hay __después__ del punto: los ceros de la parte
-- entera están protegidos por el propio punto, así que @100.00@ da @\"100\"@ y no
-- @\"1\"@. Con @0@ decimales no hay punto que recortar y devuelve lo mismo que
-- 'formatFixed'.
--
-- @-0.0@ da @\"0\"@ y no @\"-0\"@: el cero negativo es una propiedad de la
-- representación en coma flotante, no una cifra que nadie quiera leer.
formatTrimmed :: Int -> Double -> Text
formatTrimmed decimals x
  | isNaN x || isInfinite x = noData
  | otherwise               = unsign (trim (formatFixed decimals x))
  where
    trim t
      | T.any (== '.') t = T.dropWhileEnd (== '.') (T.dropWhileEnd (== '0') t)
      | otherwise        = t

    unsign t = if t == "-0" then "0" else t
