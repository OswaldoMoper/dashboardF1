-- | Política de fallo de los clientes del microservicio FastF1, común a sus cuatro
-- consumidores ('Handler.Telemetry.Manager', 'Handler.Comparison.Manager',
-- 'Handler.Drivers.Manager' y 'Handler.Feed.Manager'). No puede divergir entre
-- ellos: el mismo servicio caído degradaría a velocidades distintas según el widget
-- (2026-08-04).
--
-- No comparte la base de URL, la forma de la respuesta ni dónde viajan los coches:
-- son de cada cliente.
module Handler.FastF1.Manager
  ( fastf1Config
  , fastf1Port
  , fastf1Timeout
  , fastf1Options
  ) where

import           Config           (Config (..))
import           Network.HTTP.Req

-- | 'HttpConfig' de los clientes del microservicio: 'defaultHttpConfig'
-- __sin reintentos__ (2026-08-04). Un intento dura como mucho 'fastf1Timeout';
-- sin él, el @responseTimeout@ por defecto de @http-client@ son 30 s.
--
-- No cambia qué excepciones atrapa el @try@ de cada @Context@: solo llegan antes.
fastf1Config :: HttpConfig
fastf1Config =
  defaultHttpConfig
    { httpConfigRetryJudge = \_ _ -> False
    , httpConfigRetryJudgeException = \_ _ -> False
    }

-- | Puerto del microservicio como 'Option', monomorfizada a @'Http'@ para que el
-- esquema case con el de las bases de URL de los clientes.
fastf1Port :: Int -> Option 'Http
fastf1Port = port

-- | Techo de duración de __un__ intento, en segundos (@req@ lo toma en
-- microsegundos).
--
-- Es configurable y no una constante porque los dos escenarios del servicio
-- piden números opuestos, y no hay uno que sirva para ambos:
--
-- * __Servicio caído__ (el normal): conectar a un puerto sin escuchar __se
--   cuelga__ en vez de dar @ECONNREFUSED@, así que sin techo el intento consume
--   los 30 s por defecto. Aquí se quiere fallar en segundos.
-- * __Servicio arriba con la sesión sin cargar__: la primera llamada a una sesión
--   la carga entera —de disco, o de la red si nunca se bajó— y puede pasar del
--   techo. Con un techo corto esa llamada degrada al dummy.
--
-- El default (@TELEMETRY_TIMEOUT@, 5 s) sirve al primero. Del segundo se ocupa
-- @dashboardF1-dev@, que carga la última carrera antes de arrancar el backend;
-- otra sesión, o el servicio lanzado de otra forma, sigue pidiendo subir el techo
-- por entorno o pedirle antes la sesión al microservicio.
fastf1Timeout :: Int -> Option 'Http
fastf1Timeout seconds = responseTimeout (seconds * 1000000)

-- | Puerto y techo de duración juntos, ya resueltos desde la 'Config'. Los clientes
-- añaden las suyas con @\<\>@ (por ejemplo el @drivers@ de comparación).
--
-- __Lo usan los clientes que comparten el techo, no todos.__
-- 'Handler.Feed.Manager' compone el puerto con un techo propio, porque una foto del
-- feed cuesta ~17 s y el default de aquí la leería como fallo.
fastf1Options :: Config -> Option 'Http
fastf1Options cfg =
  fastf1Port (cfgTelemetryPort cfg) <> fastf1Timeout (cfgTelemetryTimeout cfg)
