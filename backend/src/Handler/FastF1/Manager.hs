-- | Cliente del microservicio FastF1 — lo común a sus dos consumidores
-- ('Handler.Telemetry.Manager' y 'Handler.Comparison.Manager').
--
-- El 2026-08-03 se aplazó este módulo al tercer consumidor porque lo compartido
-- era __una línea__ (@telemetryPort = port@) y un módulo para un alias de puerto
-- es más ceremonia que valor. Lo que lo adelanta no es el tercer consumidor sino
-- la __política de fallo__: desde hoy los dos clientes comparten también una
-- 'HttpConfig' y un timeout, y esos sí son una decisión que no puede divergir
-- entre áreas — si un área reintentara y la otra no, el mismo servicio caído
-- degradaría a velocidades distintas según el widget. Ese era el disparador
-- escrito en aquella decisión ("si el import se repite, deja de ser opcional").
--
-- Efecto lateral buscado: desaparece el @Manager@ de negocio importando de otro
-- @Manager@ de negocio, que era la anomalía que el 2026-08-03 anotó como riesgo.
--
-- Lo que este módulo __no__ comparte, y por eso los dos clientes siguen
-- existiendo: la base de URL (difieren en el último segmento), la forma de la
-- respuesta (una lista contra un objeto) y dónde viajan los coches (segmento de
-- path contra query string).
module Handler.FastF1.Manager
  ( fastf1Config
  , fastf1Port
  , fastf1Timeout
  , fastf1Options
  ) where

import           Config           (Config (..))
import           Network.HTTP.Req

-- | 'HttpConfig' de los clientes del microservicio: 'defaultHttpConfig'
-- __sin reintentos__.
--
-- El motivo es medido, no preventivo. Con el microservicio apagado
-- @\/api\/telemetry@ y @\/api\/comparison@ tardaban __~180 s__ en degradar al
-- dummy, y el degradado es el escenario __normal__ de este servicio: el widget
-- se quedaba tres minutos en "Cargando…".
--
-- __La causa no es el backoff__, al contrario de lo que se anotó el 2026-08-03:
-- @retryPolicyDefault@ es @constantDelay 50 ms \<\> limitRetries 5@, unos 250 ms
-- en total. Los 180 s son __6 intentos × 30 s__, y esos 30 s son el
-- @responseTimeout@ por defecto de @http-client@. De ahí que el arreglo tenga
-- dos piezas y no una: aquí se deja __un solo intento__, y 'fastf1Timeout' acota
-- lo que ese intento puede durar. Tocar solo el retry habría dejado 30 s.
--
-- Reintentar no aporta nada aquí y por una razón concreta: el servicio es
-- __local__ y nuestro. Si no está, no va a estar en el intento siguiente. Los
-- reintentos de @req@ están pensados para redes públicas con fallos
-- transitorios, que es el caso de OpenF1 y Jolpica — por eso ellos __sí__ los
-- conservan, aunque acotados a 2 en vez de a 5
-- ('Handler.PublicApi.Manager.publicApiRetries', 2026-08-19).
--
-- No cambia la semántica del degradado: el @try@ de cada @Context@ atrapa
-- exactamente las mismas excepciones, solo que antes.
fastf1Config :: HttpConfig
fastf1Config =
  defaultHttpConfig
    { httpConfigRetryJudge = \_ _ -> False
    , httpConfigRetryJudgeException = \_ _ -> False
    }

-- | Puerto del microservicio como 'Option', monomorfizada a @'Http'@ para que el
-- esquema case con el de las bases de URL de los dos clientes. Se muda aquí desde
-- 'Handler.Telemetry.Manager', donde vivía como @telemetryPort@.
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
-- * __Servicio arriba y con la cache de FastF1 fría__: la primera llamada a una
--   sesión nueva descarga y parsea la sesión entera y tarda __minutos__. Un techo
--   corto la convertiría en un degradado al dummy — el camino feliz sería
--   inalcanzable desde el backend.
--
-- El default (@TELEMETRY_TIMEOUT@, 5 s) sirve al primero, que es el de todos los
-- días. Para validar el segundo con la cache fría se sube por entorno
-- (@TELEMETRY_TIMEOUT=600@), o se calienta la cache llamando al microservicio
-- directamente antes de medir nada.
fastf1Timeout :: Int -> Option 'Http
fastf1Timeout seconds = responseTimeout (seconds * 1000000)

-- | Las 'Option' que todo GET al microservicio necesita: puerto y techo de
-- duración, ya resueltos desde la 'Config'. Los clientes añaden las suyas con
-- @\<\>@ (por ejemplo el @drivers@ de comparación).
fastf1Options :: Config -> Option 'Http
fastf1Options cfg =
  fastf1Port (cfgTelemetryPort cfg) <> fastf1Timeout (cfgTelemetryTimeout cfg)
