{-# LANGUAGE OverloadedStrings #-}

-- | Formateo de cifras y de tiempos para el dashboard.
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
  , ClockForm (..)
  , formatClock
  , formatCountdown
  ) where

import           Data.List (dropWhileEnd)
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

-- | Cuánto sitio ocupa un reloj, que es lo único en lo que se distinguen las tres
-- formas: el valor que dicen es el mismo.
--
-- __'ClockCompact' y 'ClockHours' son idénticas por encima de una hora__, así que
-- la diferencia entre ellas existe solo por debajo. Quien elija 'ClockCompact' tiene
-- que contar con que el ancho __cambia al cruzar la hora__ y con él la posición de
-- lo que tenga al lado.
data ClockForm
  = ClockCompact  -- ^ Sin horas mientras no haga falta: @\"15:00\"@, @\"0:09\"@.
  | ClockHours    -- ^ Siempre con horas, sin relleno: @\"0:15:00\"@.
  | ClockPadded   -- ^ Siempre con horas y a dos dígitos: @\"00:15:00\"@.
  deriving (Eq, Show)

-- | Segundos a reloj de cuenta atrás.
--
-- La entrada son los segundos que quedan de sesión, que es lo que
-- 'Common.Types.scRemaining' lleva: el minuto y el segundo van __siempre a dos
-- dígitos__, y lo que varía entre formas es la cabeza.
--
-- __Lo negativo es cero__, por el mismo criterio con que 'formatFixed' trata un
-- número de decimales negativo: no hay forma de expresar «quedan menos que nada» y
-- fingir que sí la hay sería peor que ignorarlo. El productor de hoy ya no baja de
-- cero, pero eso es invariante suyo y no de aquí.
--
-- __Las horas no se envuelven a las 24__: un valor de más de un día sale con la
-- cuenta entera de horas, y el relleno de 'ClockPadded' es un mínimo y no un
-- recorte.
-- | Cuánto falta para algo, en las __tres unidades mayores__ que no sean cero.
--
-- @
-- 6 d 19 h 25 min
-- 2 h 30 min 15 s
-- 4 min 50 s
-- @
--
-- __No es 'formatClock', y la diferencia no es de estilo.__ Aquél cuenta segundos
-- dentro de una sesión y su unidad mayor es la hora; éste cuenta días, y con dos
-- puntos —@\"163:25:10\"@— nadie lee una semana. Por eso lleva las unidades escritas
-- y no separadores.
--
-- __Tres unidades y no todas__, porque la cuarta no cambia la decisión de nadie: a
-- seis días, los segundos son ruido; a cuatro minutos ya no hay días que enseñar y
-- los segundos entran solos.
--
-- __Las unidades de cola que valen cero se recortan__ —@6 d@ y no @6 d 0 h 0 min@—,
-- pero las de en medio no: @6 d 0 h 25 min@ sale entero, porque saltárselas diría
-- que faltan seis días y veinticinco minutos.
--
-- __Lo negativo es cero__, y el cero se dice @\"0 s\"@ y no en blanco: por el mismo
-- criterio que 'formatClock', no hay forma de expresar «falta menos que nada», y una
-- cadena vacía se leería como que la cuenta atrás se rompió.
formatCountdown :: Int -> Text
formatCountdown secs
  | null fromTop = "0 s"
  | otherwise    = T.unwords (concatMap piece shown)
  where
    total              = max 0 secs
    (days, rest)       = total `divMod` 86400
    (hours, rest')     = rest `divMod` 3600
    (minutes, seconds) = rest' `divMod` 60

    fromTop = dropWhile ((== 0) . fst)
      [(days, "d"), (hours, "h"), (minutes, "min"), (seconds, "s")]

    shown = dropWhileEnd ((== 0) . fst) (take 3 fromTop)

    piece (n, unit) = [T.pack (show n), unit]

formatClock :: ClockForm -> Int -> Text
formatClock form secs = case form of
    ClockCompact
      | hours == 0 -> T.intercalate ":" [tshow minutes, pad2 seconds]
      | otherwise  -> withHours (tshow hours)
    ClockHours     -> withHours (tshow hours)
    ClockPadded    -> withHours (pad2 hours)
  where
    (hours, rest)      = max 0 secs `divMod` 3600
    (minutes, seconds) = rest `divMod` 60

    withHours h = T.intercalate ":" [h, pad2 minutes, pad2 seconds]

    tshow :: Int -> Text
    tshow = T.pack . show

    pad2 = T.justifyRight 2 '0' . tshow
