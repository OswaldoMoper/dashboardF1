-- | Área Live timing — lógica pura.
--
-- Modela solo los campos de OpenF1 que se consumen y los traduce a
-- 'LiveTimingRow'. Las respuestas @/position@, @/intervals@ y @/laps@ son
-- series temporales (muchas filas por piloto); aquí se reducen a la última
-- entrada por piloto y se ensambla la tabla ordenada por posición. Sin
-- efectos: todo es determinista y testeable.
module Handler.Live.Helper
  ( -- * Tipos crudos OpenF1 específicos de Live
    Of1Position (..)
  , Of1Interval (..)
  , Of1Lap (..)
  , Of1Result (..)
    -- * Transformaciones puras
  , assembleRows
  , statusOf
  , latestByDriver
  , formatLap
  , classificationTime
  , classificationGaps
  ) where

import           Common.Types          (DriverStatus (..), LiveTimingRow (..))
import           Data.Aeson            (FromJSON (..), Value (..), withObject,
                                        (.!=), (.:), (.:?))
import           Data.Aeson.Types      (Parser)
import           Data.Foldable         (toList)
import           Data.Function         (on)
import           Data.List             (find, groupBy, maximumBy, sortOn)
import           Data.Maybe            (fromMaybe, mapMaybe)
import           Data.Ord              (comparing)
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Handler.OpenF1.Helper (Of1Driver (..))
import           Text.Printf           (printf)

-- | @/position@: posición del piloto en un instante (@date@).
data Of1Position = Of1Position
  { opNumber   :: Int
  , opPosition :: Int
  , opDate     :: Text  -- ^ ISO8601; orden lexicográfico = orden temporal.
  }
  deriving (Eq, Show)

instance FromJSON Of1Position where
  parseJSON = withObject "Of1Position" $ \o ->
    Of1Position
      <$> o .: "driver_number"
      <*> o .: "position"
      <*> o .: "date"

-- | @/intervals@: gap al líder e intervalo al de delante en un instante.
-- Ambos campos pueden ser número, cadena (p. ej. @"+1 LAP"@) o @null@; se
-- normalizan a 'Text' de presentación en el decode.
data Of1Interval = Of1Interval
  { oiNumber   :: Int
  , oiGap      :: Text
  , oiInterval :: Text
  , oiDate     :: Text
  }
  deriving (Eq, Show)

-- Los dos campos de gap van con @.:?@ y no con @.:@: el nulo ya lo absorbía
-- 'gapText', pero la __clave ausente__ tumbaba el decode del arreglo entero y con
-- él @\/api\/live@, que degradaba al dummy de tres filas con la red viva. Es el
-- mismo modo de fallo que @compound@ en 'Handler.TyreStrategy.Helper'
-- (2026-08-25) y entra por la misma puerta: @.!= Null@ hace
-- que la clave ausente y el nulo compartan rama.
instance FromJSON Of1Interval where
  parseJSON = withObject "Of1Interval" $ \o ->
    Of1Interval
      <$> o .: "driver_number"
      <*> (o .:? "gap_to_leader" .!= Null >>= gapText)
      <*> (o .:? "interval" .!= Null >>= gapText)
      <*> o .: "date"

-- | Normaliza un valor de gap/intervalo (número | cadena | null) a 'Text'.
gapText :: Value -> Parser Text
gapText Null       = pure "-"
gapText (String s) = pure s
gapText (Number n) = pure (diffText (realToFrac n))
gapText _          = pure "-"

-- | Una diferencia en segundos, con signo y tres decimales (@0.166 → \"+0.166\"@).
--
-- La comparten el gap que publica OpenF1 y el que se deriva de la clasificación
-- ('classificationGaps'), para que las dos procedencias de la misma columna no se
-- distingan al leerlas.
diffText :: Double -> Text
diffText d = T.pack (printf "%+.3f" d)

-- | @/laps@: duración de una vuelta concreta (@null@ en out/in laps).
data Of1Lap = Of1Lap
  { olNumber   :: Int
  , olLapNum   :: Int
  , olDuration :: Maybe Double  -- ^ Segundos; 'Nothing' si no cronometrada.
  }
  deriving (Eq, Show)

instance FromJSON Of1Lap where
  parseJSON = withObject "Of1Lap" $ \o ->
    Of1Lap
      <$> o .: "driver_number"
      <*> o .: "lap_number"
      <*> o .:? "lap_duration"

-- | @/session_result@: clasificación de la sesión, una fila por piloto.
--
-- __Se modelan cinco de los diez campos.__ @position@ y @gap_to_leader@ siguen
-- fuera: la posición de la tabla sale de @\/position@, y la diferencia se deriva de
-- 'orDuration' en vez de leerse, porque la que publica OpenF1 en una Qualy es
-- contra el líder de __cada segmento__ y no contra la pole.
--
-- Vive aquí y no en 'Handler.OpenF1.Helper' porque hoy lo consume solo Live; el
-- criterio de reparto está en la cabecera de ese módulo y asciende cuando lo
-- comparta una segunda área.
data Of1Result = Of1Result
  { orNumber   :: Int
  , orDnf      :: Bool
  , orDns      :: Bool
  , orDsq      :: Bool
  , orDuration :: Maybe Double
    -- ^ El tiempo que la clasificación ordena, en segundos; 'Nothing' si el piloto
    -- no tiene ninguno. Ver 'classificationTime': __no siempre es una vuelta__.
  }
  deriving (Eq, Show)

-- Las tres banderas van con @.:? … .!= False@ aunque OpenF1 no emita un solo nulo
-- en ellas (22 de 22 en la 11353). No es defensa contra un dato visto sino contra
-- un cambio de contrato: con @.:@, una clave que desaparezca tumbaría el decode
-- del arreglo y con él @\/api\/live@ entera. Y el default es __semánticamente__
-- correcto, que es lo que lo hace aceptable: una bandera ausente significa «no
-- consta que abandonara», que es exactamente 'Running'.
--
-- @duration@ entra por la misma puerta y por el mismo motivo que los dos gaps de
-- 'Of1Interval': con @.:? … .!= Null@, la clave ausente y el nulo comparten rama.
instance FromJSON Of1Result where
  parseJSON = withObject "Of1Result" $ \o ->
    Of1Result
      <$> o .: "driver_number"
      <*> o .:? "dnf" .!= False
      <*> o .:? "dns" .!= False
      <*> o .:? "dsq" .!= False
      <*> (classificationTime <$> (o .:? "duration" .!= Null))

-- | El tiempo por el que la clasificación ordena, a partir del valor crudo de
-- @duration@.
--
-- __La misma clave llega con tres formas, y las tres son legítimas:__ un número en
-- prácticas (la mejor vuelta), un __arreglo de tres__ en Qualy (Q1, Q2 y Q3, con
-- nulos en los segmentos que el piloto no disputó) y un número en carrera (el
-- tiempo total, no una vuelta). De ahí que el consumidor no pueda pintar este valor
-- tal cual: 'classificationGaps' solo lo resta.
--
-- Del arreglo vale __el último no nulo__, que es el mejor tiempo de la última Q que
-- el piloto corrió y el que enseña la clasificación oficial. Cualquier otra forma
-- —cadena, booleano, nulo o clave ausente— da 'Nothing'.
classificationTime :: Value -> Maybe Double
classificationTime (Number n) = Just (realToFrac n)
classificationTime (Array xs) =
  case [ realToFrac n :: Double | Number n <- toList xs ] of
    [] -> Nothing
    ns -> Just (last ns)
classificationTime _ = Nothing

-- | Estado de un piloto a partir de las tres banderas de @/session_result@.
--
-- __El orden es una decisión, no un detalle:__ las tres banderas son
-- independientes en el contrato y nada impide que lleguen dos a la vez, así que
-- hay que elegir cuál gana. Se ordena de más específico a menos: una
-- descalificación explica por sí sola el resultado y una no-salida hace del
-- abandono una consecuencia, no una causa. Decidido el 2026-08-27.
statusOf :: Of1Result -> DriverStatus
statusOf r
  | orDsq r   = Dsq
  | orDns r   = Dns
  | orDnf r   = Dnf
  | otherwise = Running

-- | Diferencia al mejor y al de delante por piloto, derivadas de la clasificación.
--
-- Es lo que alimenta las columnas @Gap@ e @Interval@ en las sesiones donde
-- @\/intervals@ no publica nada, que son todas menos la carrera. El piloto sin
-- tiempo no aparece en la lista, y el más rápido lleva las dos a @\"-\"@: no tiene
-- a nadie delante ni diferencia consigo mismo.
--
-- __Lo que devuelve es siempre una resta, nunca el tiempo crudo__, y por eso vale
-- igual para las cinco sesiones: en prácticas resta vueltas, en Qualy resta el
-- tiempo de cada uno contra la pole, y en carrera —donde solo se llega si
-- @\/intervals@ falló— resta tiempos totales, que da el mismo gap de carrera.
classificationGaps :: [Of1Result] -> [(Int, (Text, Text))]
classificationGaps results =
  case sortOn snd [ (orNumber r, t) | r <- results, Just t <- [orDuration r] ] of
    []                       -> []
    ordered@((n0, best) : _) ->
      (n0, ("-", "-"))
        : [ (n, (diffText (t - best), diffText (t - ahead)))
          | ((n, t), (_, ahead)) <- zip (drop 1 ordered) ordered
          ]

-- | Reduce una serie temporal a la última entrada por piloto: agrupa por
-- @driver_number@ y se queda con el máximo según la clave de orden dada.
latestByDriver :: Ord o => (a -> Int) -> (a -> o) -> [a] -> [a]
latestByDriver drv ordf xs =
  [ maximumBy (comparing ordf) grp
  | grp <- groupBy ((==) `on` drv) (sortOn drv xs)
  ]

-- | Formatea segundos de vuelta a @"M:SS.mmm"@ (p. ej. @89.345 → "1:29.345"@).
formatLap :: Double -> Text
formatLap secs =
  let m = floor (secs / 60) :: Int
      s = secs - fromIntegral (m * 60)
   in T.pack (printf "%d:%06.3f" m s)

-- | Ensambla la tabla de live timing uniendo por @driver_number@ y ordenando
-- por posición. Un piloto sin posición conocida se omite. El líder muestra
-- @"LEADER"@ como gap y @"-"@ como intervalo.
--
-- Cruza __cinco__ respuestas, y es la función que más cruza del repo. La unidad
-- de la fila es el piloto de @\/drivers@: se itera sobre la parrilla y se busca
-- en las otras cuatro, así que una muestra de un coche que no está en la
-- parrilla no aparece.
--
-- __La omisión por falta de posición no la alcanza el dato de hoy.__ Medido el
-- 2026-08-27 sobre la sesión 11353: @\/position@ publica los 22 coches de la
-- parrilla, los 6 abandonos incluidos y con posición (el coche 3, con 0 vueltas,
-- sale en P22). O sea que esta rama solo la ejercita el fixture, igual que la del
-- @compound@ nulo de 'Handler.TyreStrategy.Helper'. Vive para la sesión __en
-- curso__, donde un coche puede no tener posición publicada todavía.
--
-- @\/session_result@ es la única de las cinco cuya ausencia __no__ pierde filas:
-- un piloto que no aparezca en ella entra como 'Running'. Es degradado parcial a
-- propósito —la tabla sin marcas sigue siendo la tabla—, y no lo elige esta
-- función sino el default de 'Of1Result'.
--
-- __@\/intervals@ vacía no vacía las columnas:__ cuando no trae nada, el gap y el
-- intervalo salen de 'classificationGaps' en vez de perderse. La condición es la
-- lista y no el tipo de sesión, así que no hace falta averiguarlo.
assembleRows
  :: [Of1Driver]
  -> [Of1Position]
  -> [Of1Interval]
  -> [Of1Lap]
  -> [Of1Result]
  -> [LiveTimingRow]
assembleRows drivers positions intervals laps results =
  sortOn ltPosition (mapMaybe row drivers)
  where
    posByDrv = latestByDriver opNumber opDate positions
    intByDrv = latestByDriver oiNumber oiDate intervals
    lapByDrv =
      latestByDriver olNumber olLapNum $
        filter (maybe False (> 0) . olDuration) laps

    derived = classificationGaps results

    -- El gap y el intervalo de un piloto, de la fuente que haya. Se elige una sola
    -- vez para toda la tabla, para que dos filas no puedan salir de fuentes
    -- distintas.
    gapsFor n
      | null intervals = lookup n derived
      | otherwise =
          (\i -> (oiGap i, oiInterval i)) <$> find ((== n) . oiNumber) intByDrv

    row d = do
      p <- find ((== odNumber d) . opNumber) posByDrv
      let mg  = gapsFor (odNumber d)
          ml  = find ((== odNumber d) . olNumber) lapByDrv
          mr  = find ((== odNumber d) . orNumber) results
          pos = opPosition p
          gap
            | pos == 1  = "LEADER"
            | otherwise = maybe "-" fst mg
          intv
            | pos == 1  = "-"
            | otherwise = maybe "-" snd mg
          lastLap = maybe "-" (formatLap . fromMaybe 0 . olDuration) ml
      pure
        LiveTimingRow
          { ltPosition = pos
          , ltDriver   = odAcronym d
          , ltTeam     = odTeam d
          , ltGap      = gap
          , ltInterval = intv
          , ltLastLap  = lastLap
          , ltStatus   = maybe Running statusOf mr
          }
