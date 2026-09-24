-- | Política de fallo de los clientes de __redes públicas__ — lo común a OpenF1 y
-- Jolpica ('Handler.OpenF1.Manager' y 'Handler.Historical.Manager').
--
-- Existe por la misma razón que 'Handler.FastF1.Manager' y no por reuso de código:
-- la política de fallo __no puede divergir entre clientes__. Si OpenF1 esperara
-- 15 s y Jolpica 180 s, la misma red caída degradaría a velocidades distintas
-- según el widget, y el usuario lo leería como que unos widgets funcionan y otros
-- no. Aquí no hay nada más que compartir: la base de URL, la sesión @latest@ y la
-- forma de la respuesta son propias de cada API, y de ahí que los dos clientes
-- sigan existiendo.
--
-- __No vive en ninguno de los dos clientes__ a propósito. Ponerla en
-- 'Handler.OpenF1.Manager' obligaría al cliente de Jolpica a importar del de
-- OpenF1 — un @Manager@ importando otro @Manager@, que es la anomalía que el
-- 2026-08-03 anotó como riesgo y de la que el 2026-08-04 se salió extrayendo
-- 'Handler.FastF1.Manager'.
module Handler.PublicApi.Manager
  ( publicApiRetries
  , publicApiConfig
  , publicApiTimeout
  , publicApiOptions
  ) where

import           Config           (Config (..))
import           Control.Retry    (constantDelay, limitRetries)
import           Network.HTTP.Req

-- | Reintentos __además__ del primer intento: 2, o sea __3 intentos__ en total
-- (@retryPolicyDefault@ trae 5, o sea 6).
--
-- Es una constante y no un campo de la 'Config', al contrario que el techo: no hay
-- dos escenarios opuestos que pidan números distintos —el argumento que puso
-- @TELEMETRY_TIMEOUT@ en la 'Config' (2026-08-04)—, así que
-- sería una perilla que nadie necesita y un segundo número que puede quedar
-- incoherente con lo que este Haddock afirma.
--
-- __Reintentar aquí sí aporta__, y ésa es la diferencia con
-- 'Handler.FastF1.Manager', donde se dejó __un solo intento__: el microservicio es
-- local y nuestro, así que si no está no va a estar 50 ms después. OpenF1 y
-- Jolpica son redes públicas, donde un fallo transitorio es lo normal y el segundo
-- intento tiene una razón para salir bien.
publicApiRetries :: Int
publicApiRetries = 2

-- | 'HttpConfig' de los dos clientes públicos: 'defaultHttpConfig' con
-- 'publicApiRetries' reintentos en vez de 5 (2026-08-19).
--
-- El techo total de un GET es __intentos × techo por intento__, y @req@ solo deja
-- fijar el segundo ('publicApiTimeout'); por eso este módulo exporta las dos piezas.
-- Con 3 intentos de 5 s, ~15 s.
--
-- El backoff (50 ms entre intentos) y el @retryJudge@ por defecto se conservan: solo
-- se reintentan __timeouts__ (@ResponseTimeout@\/@ConnectionTimeout@ y los status
-- 408\/504\/524\/598\/599), no un @ECONNREFUSED@, así que __cada reintento cuesta
-- un techo entero__.
--
-- No cambia qué excepciones atrapa el @try@ de cada @Context@: solo llegan antes.
publicApiConfig :: HttpConfig
publicApiConfig =
  defaultHttpConfig
    { httpConfigRetryPolicy = constantDelay 50000 <> limitRetries publicApiRetries
    }

-- | Techo de duración de __un__ intento, en segundos (@req@ lo toma en
-- microsegundos). Monomorfizada a @'Https'@ para que el esquema case con el de las
-- bases de URL de los dos clientes, igual que 'Handler.FastF1.Manager.fastf1Timeout'
-- lo está a @'Http'@.
--
-- Es configurable (@PUBLIC_API_TIMEOUT@, 5 s por defecto) para poder aflojarlo sin
-- recompilar el día que una de las dos APIs vaya lenta. El default sale del camino
-- feliz medido —@\/api\/live@ 0.48–3.4 s, @\/api\/historical@ 0.43–2.0 s,
-- @\/api\/tyre-strategy@ 0.15–0.31 s—, así que deja 1.6× de margen sobre el peor
-- caso bueno visto.
--
-- __Bajarlo de más es el error simétrico al de los 180 s, y es peor__: convierte
-- una red lenta pero __viva__ en un degradado al dummy, o sea sirve dato falso en
-- vez de tardar.
publicApiTimeout :: Int -> Option 'Https
publicApiTimeout seconds = responseTimeout (seconds * 1000000)

-- | Las 'Option' que todo GET a una API pública necesita, ya resueltas desde la
-- 'Config'. Los clientes añaden las suyas con @\<\>@ (por ejemplo el
-- @session_key=latest@ de OpenF1).
publicApiOptions :: Config -> Option 'Https
publicApiOptions cfg = publicApiTimeout (cfgPublicApiTimeout cfg)
