# ARCHITECTURE – F1 Functional Dashboard

## 1. Visión General

El F1 Functional Dashboard es una plataforma modular construida en Haskell que integra:

- **Backend funcional** con Servant + Nix flakes.
- **Frontend reactivo** con Reflex-DOM.
- **HTML base** generado con Lucid.
- **Microservicio Python** encapsulado para FastF1.
- **Fuentes de datos externas**: OpenF1, Jolpica, FastF1.
- **Módulo de analítica** reutilizando Mathematical_Data_Analysis.

El sistema está diseñado como un conjunto de **widgets configurables**, organizados en **layouts**, similares a F1TV Premium o F1Cosmos, con:

- Live timing.
- Telemetría.
- Comparación de vueltas.
- Estrategias de neumáticos.
- Estadísticas históricas.
- Widgets personalizables.
- Modo sincronizado con transmisión F1TV (live/replay conceptual).

## 2. Componentes Principales

### 2.1 Backend (Haskell + Servant)

Responsabilidades:

- Servir HTML base.
- Exponer API REST para widgets.
- Integrar OpenF1 y Jolpica.
- Integrar microservicio FastF1.
- Cachear datos.
- Proveer WebSockets para live timing.

Módulos (top-level, sin prefijo `Backend.`; convención del 2026-07-16):

- **INFRA (raíz):** `Config` (incl. `cfgStaticDir`/`STATIC_DIR`), `App` (`Env`/`mkEnv`),
  `Server` (`Api` + `app` + `spaApp`), `Outcome` (`Outcome`/`Rejection`, el discriminador
  400/404 contra degradado), `Html` (shell Lucid, **superseded** desde Fase 2 s2).
  `spaApp` (`wai-app-static`) **ya sirve el bundle del frontend** en el mismo puerto que
  `/api/*` (same-origin; `GET /` → `index.html`/`all.js`). Futuros: `Db` (`SqlM`/`runDB`),
  `Model/*` (Persistent), auth.
- **Contrato de fallo de un `Context`:** devuelve `IO (Outcome a)` y no `IO a`, para poder
  distinguir una petición mala del cliente (`400`/`404`, se propagan) de un servicio caído
  (se degrada a cache o dummy). El criterio vive en el `Context`; el handler solo traduce
  con `Outcome.serve` (2026-08-14). **Aplicado hoy solo a `Comparison`**;
  las otras áreas siguen con `IO a` hasta que se cierre la Fase 4.
- **Procedencia del dato:** `/api/live` y `/api/tyre-strategy` emiten `X-Data-Origin`
  (`fresh`/`recent`/`cached`/`sample`; neumáticos no tiene `recent`), `X-Data-Source` (`feed`/`openf1`; falta
  con el dato de ejemplo) y, con los que salen de lo guardado —`recent` y `cached`—, `X-Data-Fetched-At` en
  ISO 8601 UTC; el cuerpo JSON no cambia. Cabeceras en `Provenance`; tipo y valores en `Common.Origin`.
- **Presupuesto de OpenF1:** acepta 30 peticiones por minuto y 3 por segundo, y lo dice en su propio rechazo.
  Toda petición pasa por un freno único (3 salidas por ventana de 1,2 s) en
  `Handler.OpenF1.Manager.fetchListWith`, y con `OPENF1_LOG` deja una línea por petición. El backend no
  vuelve a bajar a OpenF1 si lo que guardó tiene menos de 15 s y lo sirve como `recent`; el feed, que es
  propio, no se frena.
- **NEGOCIO (`Handler/`) por área:** `Handler.<Área>{,.Context,.Helper,.Manager}` (interfaz → orquestación → efectos → pureza). Áreas: `Live`, `Historical`, `Telemetry`, `Comparison`, `TyreStrategy`; luego `OpenF1`/`Jolpica`/`FastF1` como `Manager`s. Cache en memoria (STM) como infra cuando llegue (Fase 3).
- **AUTOMATISMO (`Auto/`):** `Auto.Helper` (puro) y `Auto.Context` (efectos) para el comando `dashboardF1-auto`
  (`backend/auto/`), que programa con temporizadores de `systemd-run --user` las comprobaciones de un día de GP. No es
  INFRA ni un área: no tiene endpoint. Lee `GET /api/calendar`, el calendario que la instancia ya tiene en memoria, y
  si falla (lista vacía, 404 o la página de una instancia sin la ruta), la temporada de Jolpica por
  `Handler.Historical.Manager.fetchSeasonSchedule`. Se lanza desde el store (`nix run .#auto`), así que cada
  temporizador corre la copia del momento de lanzar aunque el árbol se recompile. El vigía pregunta cada minuto a
  `/api/live` y a OpenF1; la grabación lanza `dashboardF1-record` sin cuenta, el del store, cuya ruta pone `apps.auto`
  (`DASHBOARDF1_RECORD`) y viaja en la orden de su temporizador, y lo para con SIGINT (con SIGTERM si a los 30 s sigue
  vivo). Lo relanza si sale solo o si su fichero lleva 3 min sin crecer desde la hora prevista de la sesión; la vez que
  no llega a conectar reusa su número y no cuenta. Las comprobaciones (al lanzar
  y a T−45) miran OpenF1, la caducidad del token de F1TV sin escribirlo, la página (`/`, `all.js`, `/api/live`) y el
  log que se da con `--log`. El observador arranca con el vigía y para cuando su unidad deja de correr: lanza el lector
  `dashboardF1-observa` (`backend/auto/observa.ts`, el Playwright de nixpkgs compilado con `tsc`; su ruta la pone
  `apps.auto` en `DASHBOARDF1_OBSERVA`), que abre la página sin diferido en un Chromium sin ventana y obedece órdenes
  por la entrada estándar; cuándo leer, capturar o cerrar (la foto del reloj de la P1) lo decide Haskell. Un lector que
  no contesta en 30 s se para (se le cierra la entrada, SIGINT y, si a los 20 s sigue vivo, SIGKILL; su Chromium cae con
  él) y se lanza otro.
- **DTOs compartidos:** paquete `common` (`Common.Types`). Un tipo que la página no usa vive en el backend
  (`Handler.Live.Helper.CalendarEntry`): en `common` recompilaría el frontend sin consumidor.
- **DB:** `Database.Esqueleto.Legacy` + `Database.Esqueleto.PostgreSQL`; `Persist` solo modelos.

---

### 2.2 Frontend (Haskell + Reflex-DOM)

Responsabilidades:

- Renderizar widgets.
- Manejar layouts.
- Suscribirse a WebSockets.
- Integrar gráficos (Plotly, Chart.js vía FFI).
- Permitir personalización.

Módulos (top-level, sin prefijo `Frontend.`; convención del 2026-07-16):

- **INFRA (raíz):** `App` (router + `dispatch` ruta→página), `Client` (GET + decode JSON por XHR, y las
  cabeceras de procedencia de `Common.Origin`). Futuros: `Router` (`PageM`, `Nav`, `navigate`, `routeLink`)
  cuando haya una segunda ruta, y XSRF y `location` en `Client` cuando haya mutaciones (POST/PUT) y navegación.
- **`Pages/`:** un módulo por flujo (`Pages.<Flujo>`).
- **`Widgets/`:** widgets compartidos por categoría.
- **Tyre Strategy:** lo puro vive en `common` (`Common.TyreStrategy`: las filas, la escala, la geometría de cada
  barra, el tooltip y la leyenda) y `Widgets.TyreStrategy` lo pinta. Una fila por cada fila de la tabla, por posición,
  con los stints de la **misma** respuesta de `/api/live`; después, los coches con stints y sin fila. Fuera del feed, un
  aviso y ninguna fila. Va en el layout **Strategy** (Live Timing y Tyre Strategy, mitad y mitad), el tercero del
  conmutador junto a Race Overview y Qualy.
- Rutas con un módulo `Route` compartido en `common` (mismas URLs en ambos extremos).

---

### 2.3 Microservicio FastF1 (Python)

Responsabilidades:

- Exponer telemetría avanzada.
- Comparación de vueltas.
- Cachear resultados.
- Mantener interfaz estable.

Endpoints (los **cuatro** implementados desde el 2026-08-13):

- `/fastf1/telemetry/{session_key}/{driver}`
- `/fastf1/laps/{session_key}?driver=all`
- `/fastf1/comparison/{session_key}?drivers=16,1&samples=0`
- `/fastf1/drivers/{session_key}`

`driver`/`drivers` son **números de coche** (o `all` en telemetría), no acrónimos: la traducción
número→acrónimo la conoce solo el microservicio, así que entra número y **sale acrónimo**
(2026-08-01 y 2026-08-03). La comparación es de **1 a 5** coches, **la referencia primero**, y trae los
sectores de cada uno; la Δ la calcula `common`. Con `samples` (0, o de 60 a 250 de 5 en 5) trae también las
fronteras S1/S2 y la traza de la misma vuelta.
Un acrónimo que la sesión reconoce se acepta y **se traduce a número a la entrada**, así que la respuesta
lleva números también en ese caso (2026-09-23); lo que no reconoce pasa tal cual.

Además, `GET /fastf1/live` sirve la foto del feed en directo (`feed._feed_live`): la sesión, las filas y los stints,
los tres de la **misma** foto, para que no hablen de instantes distintos. Los stints (`feed._feed_stints`) salen de
`TimingAppData`, uno por entrada y sin omitir el `UNKNOWN` ni el de 0 vueltas, con las vueltas **completadas**. El
backend los lee en `Handler.Feed.Helper`. `telemetry-service/tests/compara_stints.py` compara los de una grabación con
OpenF1 `/v1/stints`, fuera de sesión (con una en marcha, OpenF1 da 401).

La comparación devuelve **también el número de coche** (`ceCar`) junto al acrónimo: sin él, un consumidor que solo habla acrónimos puede leer la respuesta pero no puede pedir **otra**.

**Se arranca desde el flake** (`nix run .#telemetry`, o `nix develop .#telemetry` para iterar), con las
dependencias de Python pineadas por él y sin venv que reconstruir (2026-08-12). La
cache de FastF1 va donde diga `FASTF1_CACHE`, que por defecto es **relativa al directorio de ejecución**
(`.fastf1-cache`), así que suelto se arranca desde `telemetry-service/`. `nix run .#dev` le pasa una ruta
absoluta: `telemetry-service/.fastf1-cache` bajo el directorio desde el que se lanza.

**Suelto escucha en TCP** (`:8000` por defecto), **o en un socket Unix si se le pasa `--uds`**. `nix run .#dev` lo
lanza por socket, sin puerto propio, en `$XDG_RUNTIME_DIR/dashboardF1/fastf1-<PORT>.sock` (un socket por
puerto del backend, en un directorio `700`), y el backend le habla por ahí con `TELEMETRY_SOCKET`
(2026-09-23 (q) a (s)).

`GET /fastf1/drivers/{session_key}` cierra el desajuste por completo: es el único endpoint que **publica** la traducción en vez de aplicarla por dentro, así que un consumidor puede pedir datos de un coche que aún no ha visto. Devuelve la parrilla **de esa sesión** —sustitutos y terceros coches incluidos—, en el orden que le da FastF1 y sin reordenar.

`GET /fastf1/laps/{session_key}` completa el contrato desde el 2026-08-13, y es el único de los cuatro **sin DTO** en `common`: publica las claves con el prefijo `le` que un futuro `LapEntry` usaría, y el tipo llegará con el consumidor (2026-08-13). Es también el único que devuelve la **sesión entera** —todas las vueltas de todos los coches, ~1400 objetos en una carrera—, y por eso acepta `?driver=` para filtrar en el servicio en vez de en el consumidor.

---

### 2.4 Módulo de Analítica (Haskell)

Responsabilidades:

- Reutilizar el repositorio Mathematical_Data_Analysis.
- Proveer KPIs avanzados.
- Normalización, outliers, degradación, consistencia.

Módulos:

- `Analysis.Core`
- `Analysis.KPI`
- `Analysis.Transform`
- `Analysis.Integration`

## 3. Flujo de datos

El flujo de datos del sistema sigue una arquitectura en capas:

1. OpenF1 → Backend
    - Datos live: posiciones, intervalos, clima, stints, laps, mensajes de race control.
    - El backend los normaliza y cachea.
2. Jolpica → Backend
    - Datos históricos: standings, calendario, resultados.
    - El backend los expone como endpoints REST.
3. FastF1 → Microservicio Python → Backend
    - Telemetría avanzada: speed, throttle, brake, gear, rpm, GPS.
    - Comparación de vueltas.
    - El backend consume el microservicio vía HTTP.
4. Backend → Frontend (Reflex)
    - El frontend obtiene datos vía REST (fetch) y WebSockets (live timing).
    - `/api/live` lleva, junto a las filas, los stints de la misma foto (`liveStints`); con OpenF1 y el dato de
      ejemplo, la lista vacía.
    - Los widgets renderizan la información.
5. Analysis Module → Backend → Widgets
    - KPIs avanzados derivados del repositorio Mathematical_Data_Analysis.
    - Se integran en widgets especializados.

Resumen textual:

- OpenF1 → Backend → Widgets (live timing, stints, laps)
- Feed oficial → Microservicio (`/fastf1/live`) → Backend (`/api/live`) → Widgets (live timing, Tyre Strategy)
- Jolpica → Backend → Widgets (histórico)
- FastF1 → Microservicio → Backend → Widgets (telemetría)
- Mathematical_Data_Analysis → Backend → Widgets (KPIs)

## 4. Invariantes Arquitectónicas

- El backend nunca bloquea el frontend.
- Los widgets son independientes entre sí.
- Los datos externos se cachean.
- El roadmap de fases vive en `ROADMAP.md`

## 5. Tradeoffs Clave

- Reflex-DOM vs Miso → Reflex para FRP puro.
- FastF1 encapsulado → evita mezclar Python con Haskell.
- Persistencia de layouts:
  - Primera etapa: JSON en disco.
  - Etapa posterior: PostgreSQL para multiusuario y versiones.

## 6. Riesgos

- Complejidad del FRP.
- Dependencia en APIs externas.
- Sincronización con F1TV requiere timestamping preciso.

## 7. Diagrama Conceptual (texto)

Representación textual de la arquitectura general:

- OpenF1 y Jolpica alimentan directamente al backend Servant.
- FastF1 está encapsulado en un microservicio Python independiente.
- El módulo de análisis en Haskell se integra en el backend.
- El frontend Reflex consume todo vía REST y WebSockets.
- Los widgets son la capa final de visualización.

Esquema:

- OpenF1 → Backend Servant → Frontend Reflex → Widgets
- Jolpica → Backend Servant → Frontend Reflex → Widgets
- FastF1 → Microservicio Python → Backend Servant → Frontend Reflex → Widgets
- Mathematical_Data_Analysis → Backend Servant → Frontend Reflex → Widgets (KPIs)

## 8. Relación con las fases del roadmap

- Fase 0: prepara infraestructura para backend, frontend y microservicio.
- Fase 1: define API y tipos del backend según esta arquitectura.
- Fase 2: implementa widgets y layouts en el frontend.
- Fase 3: conecta OpenF1 y Jolpica según el flujo de datos.
- Fase 4: integra FastF1 vía microservicio.
- Fase 5: integra analítica avanzada.
- Fase 6: añade personalización de widgets y sincronización conceptual con F1TV.
