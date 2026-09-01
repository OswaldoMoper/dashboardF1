# ROADMAP DashboardF1

## Fase 0 – Infraestructura mínima (Nix + skeleton)

**Objetivo:** tener un repo que compila con:

- `flake.nix` con:
  - `devShell` (GHC, cabal, hlint, ormolu, nodejs si se requiere).
  - paquetes para Servant, Reflex, Lucid.
- Estructura de directorios:
  - `/backend`
  - `/frontend`
  - `/telemetry-service`
  - `/analysis` (código importado de `Mathematical_Data_Analysis`)
  - `/docs` (arquitectura, decisiones, roadmap, glosario y notas de análisis)

**Entregables:**

- `flake.nix` funcional.
- `backend` con un servidor Servant que expone `/home`.
- `frontend` con una app Reflex que muestra “F1 Dashboard skeleton”.
- `telemetry-service` con README y entorno Python definido (sin lógica aún).

## Fase 1 – Backend base (Servant + Lucid + modelos)

**Objetivo:** tener:

- HTML base generado con Lucid:
  - `<div id="app"></div>` donde se monta Reflex.
- API Servant con endpoints stub:
  - `/api/live`
  - `/api/telemetry`
  - `/api/comparison`
  - `/api/tyre-strategy`
  - `/api/historical`
- Tipos compartidos en `/common`:
  - `LiveTimingRow`
  - `TelemetryPoint`
  - `LapComparison`
  - `TyreStint`
  - `HistoricalStat`
  - `WidgetType`, `WidgetConfig`, `Layout`.

**Entregables:**

- Módulos Haskell con tipos y APIs definidos.
- Respuestas dummy (datos estáticos) para poder probar el frontend.

## Fase 2 – Frontend widgets (Reflex)

**Objetivo:** construir el sistema de widgets:

- Modelo:
  - `data WidgetType = LiveTiming | Telemetry | LapComparison | TyreStrategy | HistoricalStats | Custom`
  - `data WidgetConfig = WidgetConfig { widgetId :: WidgetId, widgetType :: WidgetType, params :: WidgetParams }`
  - `data Layout = Layout { layoutId :: LayoutId, widgets :: [WidgetConfig] }`
- Reflex:
  - `Dynamic t Layout` para la pantalla actual.
  - `renderWidget :: WidgetConfig -> m ()` para cada tipo.
- Widgets iniciales:
  - Live timing (tabla con datos dummy).
  - Telemetry (gráfico simple con datos dummy).
  - Layout fijo (sin personalización aún).

**Entregables:**

- Frontend que muestra al menos 2 widgets en una pantalla.
- Capacidad de cambiar de layout (ej. botones para “Race Overview” y “Qualy”).

## Fase 3 – Integración OpenF1 + Jolpica

**Objetivo:** conectar el backend con datos reales:

- Clientes HTTP:
  - `OpenF1Client` para live timing, stints, laps, weather, race control.
  - `JolpicaClient` para standings, calendario, resultados históricos.
- Cache:
  - En memoria (STM) o Redis opcional.
- Endpoints Servant:
  - `/api/live` → OpenF1.
  - `/api/tyre-strategy` → OpenF1 stints.
  - `/api/historical` → Jolpica.

**Entregables:**

- Live timing real en el widget.
- Estrategias de neumáticos reales.
- Estadísticas históricas básicas.

## Fase 4 – Microservicio FastF1

**Objetivo:** encapsular Python:

- `telemetry-service`:
  - API:
    - `/fastf1/telemetry/{session_key}/{driver}`
    - `/fastf1/laps/{session_key}`
    - `/fastf1/comparison/{session_key}?drivers=VER,LEC`
  - Internamente:
    - Usa FastF1.
    - Cachea resultados.
- Backend Haskell:
  - Cliente HTTP para el microservicio.
  - Endpoints:
    - `/api/telemetry` → FastF1.
    - `/api/comparison` → FastF1.

**Entregables:**

- Telemetría avanzada en widgets.
- Comparación de vueltas funcional.
- Contrato de degradado: la escalera `try` → cache → dummy distingue un **400** del cliente de un
  **503** del servicio. Cierra la fase.
  - **En las tres áreas que hablan con el microservicio** (`telemetry`, `comparison`, `drivers`), y no
    en las seis: `live`, `historical` y `tyre-strategy` no tienen parámetros, así que no admiten query
    malo. Corregido con la medición del 2026-08-14, que es cuando se comprobó por primera vez.

## Fase 5 – Diseño y estilos — COMPLETADA (2026-08-21)

**Objetivo:** que el dashboard deje de ser HTML crudo:

- Hoja de estilos propia, servida junto al `.jsexe` por `packages.frontend`.
- Sistema de tokens: paleta, escala tipográfica, espaciado, radios.
  - Tipografía monoespaciada para tiempos y deltas, que es donde el alineado comunica.
- Rejilla de layout para los widgets, en vez del apilado por defecto del navegador.
- Estados visibles y no solo textuales: carga, degradado (dato de cache o dummy), vacío y error.
- Comportamiento responsive básico.

**Nota:** no es un refactor del frontend. Los widgets ya emiten un vocabulario de clases coherente
—bloque, elemento y modificador: `comparison__delta`, `historical__row--driver`,
`car-selector__btn`— y `frontend/index.html` no tiene hoy ni una línea de CSS. La fase consiste en
**escribir la hoja de estilos que esas clases ya implican**, y en corregir los nombres que se hayan
desviado (`labelButton` → `switcherButton`, deuda desde el 2026-08-01).

Va **antes** de las dos fases siguientes a propósito: las dos añaden widgets, y con el sistema de
estilos puesto cada widget nuevo nace vestido en vez de generar deuda visual.

**Entregables:**

- [x] Dashboard con estilos propios y layout en rejilla — `frontend/dashboard.css`, servida junto al
      `.jsexe` por `packages.frontend`. El `<link>` lo emite `App.headW` y no `index.html`
      (2026-08-21).
- [x] Sistema de tokens: paleta, escala tipográfica, espaciado y radios en `:root`.
- [x] Monoespaciada con `tabular-nums` en tiempos, deltas y columnas numéricas, elegidas por
      `nth-child` porque las celdas no llevan clase.
- [x] Los cinco estados distinguibles de un vistazo — sobre `p.status` con seis modificadores
      (`--loading`, `--busy`, `--stale`, `--error`, `--empty`, `--placeholder`), que los widgets ya
      emitían desde antes de que la hoja existiera.
- [x] Responsive básico — **un** breakpoint (`52rem`) derivado de la propia rejilla, con el
      `<meta viewport>` que `headW` emite (2026-08-21 (c)).
- [x] **Extra no previsto:** el renombrado `labelButton` → `switcherButton` / `switcher__btn` en los
      tres switchers, que la hoja convirtió de deuda cosmética en deuda visible, y `overflow-x` en
      `.widget` — la tabla de telemetría se pintaba fuera de su tarjeta y la vecina la tapaba.

**Lo que la fase deja señalado y no arregla** (son de contenido, no de estilo): `HistoricalStats`
publica una fila **por métrica** y no por piloto, así que un piloto sale en dos renglones y los
constructores comparten tabla con ellos; y no hay forma de **elegir la sesión** que se está viendo.
Los dos salieron de mirar la página ya estilada, que es lo que la fase existía para permitir.

**El primero quedó cerrado el 2026-08-24**, entre fases: una fila por entidad y dos
tablas (2026-08-24). **El segundo sigue abierto** y no cabe entre fases — pide un
`Dynamic t SessionKey` compartido por la página, que es estado de la **Fase 6**: «elegir qué se está
viendo» y «persistir el layout» son el mismo problema.

**Y la cuenta de lo que la fase destapó no se cerró en dos: llegan cuatro reportes más**, tres de ellos
del mismo tipo — salen de **mirar** la página, no de leer el código. Uno es continuación del primero (las dos tablas pasan a dos widgets independientes, con
nombre completo y clave siempre); uno es de dato que falta (Live Timing no marca los DNF); y **el más
grande, el rediseño de Telemetry a un renglón por piloto con los microsectores como columnas, es un
cambio de contrato del DTO disfrazado de widget mal puesto** — `TelemetryPoint` publica una muestra y lo
que se pide es un agregado por piloto y sector. Ese **roza la Fase 6** por lo mismo que el punto 13:
«qué vuelta se está viendo» es estado de página, no de widget.

**El primero de los cuatro quedó cerrado el 2026-08-26**: `WidgetType` gana
`ConstructorStats` y cada clasificación es su propio widget (2026-08-26). **Y deja a la
Fase 6 una pieza montada y una decisión ya tomada.** La pieza: la rejilla recibe por primera vez dos
widgets que son **el mismo tipo de contenido colocado por separado**, que es el caso que «agregar/quitar
widgets» tiene que soportar. La decisión: se descartó a propósito usar `WidgetParams` como discriminador
—habría sido su primer consumidor— para **no fijar su forma antes de que esta fase decida cuál es**. Sigue
en `mempty` en todas las `WidgetConfig`, y eso es deliberado, no un olvido.

Es el argumento de esta fase cobrando por tercera vez, y conviene dejarlo escrito para las que vienen:
la hoja de estilos no arregló el contenido, lo hizo **visible**. Los widgets que la Fase 6 añada nacen
vestidos, pero eso no los hace correctos — nacen **auditables**, que es distinto y más útil.

## Fase 6 – Widgets personalizables + sincronización conceptual con F1TV

**Objetivo:** hacer el sistema “tipo F1TV Premium”:

- Persistencia de layouts:
  - Guardar `Layout` en DB (PostgreSQL) o archivos JSON.
  - Cargar layouts por usuario/perfil.
- Personalización:
  - UI para:
    - agregar/quitar widgets.
    - cambiar parámetros (driver, sesión, métrica).
- Sincronización con F1TV:
  - Modelo de tiempo:
    - `SessionTime` basado en OpenF1/FastF1.
  - Modo “sync”:
    - el usuario indica el tiempo de la transmisión (ej. minuto 23:45).
    - el dashboard muestra datos correspondientes a ese `SessionTime`.

**Ampliación del 2026-08-27.** Los cuatro puntos de arriba son de 2026-07 y no cubren la manipulación del
layout, que es la mitad de lo que «tipo F1TV Premium» significa. Se añaden como entregables propios:

- Widgets **movibles** por el layout: colocar la tabla de constructores encima de Lap Comparison, o Lap
  Comparison encima de Live Timing y Telemetry — arriba en el layout, no encimados.
- Widgets **redimensionables**.
- **Ocultar y volver a mostrar** widgets, con un menú desplegable que liste todas las opciones.
- **Varias instancias del mismo widget** —varios Telemetry, varios Lap Comparison en paralelo—, porque un
  análisis puede ser de varias peleas a la vez.
- **Agrupar** los Telemetry y los Lap Comparison.
- **Elegir la sesión** que se está viendo: un `Dynamic t SessionKey` compartido por la página, pendiente
  desde el 2026-08-21.

**La fase arranca con diseño y no con código, y el motivo es una sola línea de `Pages.Dashboard`.** `cfg`
fabrica `WidgetId (T.pack (show wt))`, o sea que **la identidad de un widget es su tipo**: dos Telemetry
colisionan de id, y sin id no hay nada que mover, ocultar, colocar ni agrupar por separado. Los otros cinco
entregables son **imposibles** hasta que eso cambie, así que el orden lo fija la dependencia y no la
visibilidad.

Encaja con una decisión ya tomada: **`WidgetParams` sigue en `mempty` en todas las `WidgetConfig` a
propósito** desde el 2026-08-26, que descartó usarlo como discriminador para no fijar su forma antes de que
esta fase decida cuál es. El entregable de las varias instancias es el consumidor que aquella decisión
estaba esperando.

**El diseño se cerró el 2026-09-01, y son tres decisiones de ese día.** Fija la identidad
del widget, la forma de `WidgetParams` y qué guarda `Layout` —que resulta ser lo mismo que guardaba—, así
que el código de la fase arranca sobre tipos ya decididos y los siete entregables de abajo tienen cada uno
respondido qué tipo tocan.

**Dos cosas medidas el 2026-08-27 que acotan el coste, para que la fase no las descubra en marcha:**

- **Redimensionar y mover no cuestan lo mismo.** `resize: both` sobre `.widget` es CSS y cero Haskell —la
  tarjeta ya lleva `overflow-x: auto`, así que la propiedad le aplica—; mover pide Haskell. **Lo que sí
  cuesta menos de lo que decía este punto es arrastrar**, y lo corrige el 2026-09-01 (c): el `EventName` de
  la `reflex-dom` del pin trae `Dragstart`, `Dragover`, `Drop` y `Dragend` con `EventResultType` `()`, y
  `Reflex.Dom.Builder.Class` expone `preventDefault` y `addEventSpecFlags`, así que el *drag and drop*
  nativo reordena **sin coordenadas, sin `wrapDomEvent` y sin dependencia nueva**. Que no haya `jsaddle`,
  ni `ghcjs-dom`, ni un solo `foreign import javascript` —todo el DOM va por `reflex-dom`— sigue siendo
  cierto y deja de ser un obstáculo. Lo que no cambia: `Pages.Dashboard` solo compila bajo GHCJS, donde el
  error no aparece hasta el build completo.
- **La rejilla no guarda posiciones.** Es `repeat(auto-fit, minmax(24rem, 1fr))` con los widgets como
  hermanos directos de `.page--dashboard`: la posición la decide el navegador y `Layout` solo tiene orden de
  lista. **El diseño del 2026-09-01 (c) lo deja así**: el orden **es** la colocación, mover es reordenar la
  lista y el tamaño no se persiste, así que la colocación no pasa a ser dato y el breakpoint de 2026-08-21
  (c) sigue mandando sobre el número de columnas.

**Entregables:**

- [ ] Layouts guardables/cargables.
- [ ] Modo “sync” básico (input manual de tiempo).
- [ ] `WidgetId` como identidad real, no derivada del tipo, y `WidgetParams` con forma decidida.
      **Forma cerrada el 2026-09-01:** id explícito que pone quien construye el `Layout` (entrada del día),
      y `WidgetParams` como récord de `wpSession`/`wpDriver`/`wpDrivers` —los tres parámetros que
      `Common.Route` ya acepta— con `noParams` (entrada (b)).
- [ ] Widgets movibles y redimensionables. Mover = reordenar `[WidgetConfig]` por *drag and drop* nativo;
      redimensionar = `resize: both`, solo CSS y sin persistir (2026-09-01 (c)).
- [ ] Ocultar/mostrar con menú desplegable, sobre `widgetVisible :: Bool` en `WidgetConfig` (2026-09-01 (c)).
- [ ] Varias instancias del mismo tipo de widget. **No pide tipo propio**: sale del id explícito.
- [ ] Agrupación de widgets: adyacencia en el orden más `widgetGroup :: Maybe Text`, que emite clase y
      encabezado. Sin anidamiento en `Layout` (2026-09-01 (c)).
- [ ] Selector de sesión compartido por la página. Estado de **página**, no de `Layout`.

**Lo que NO es de esta fase**, aunque se pida junto con lo de arriba y se le parezca:

- **Comparar N pilotos en Lap Comparison.** El microservicio compara **exactamente dos** coches por
  contrato (ver 2026-08-03 y 2026-08-05) y `LapComparison` tiene `lcCarA`/`lcCarB` fijos, así que toca
  Python, DTO, `Handler.Comparison.Helper` y `Common.Chart` —de una serie a N—. **Fase propia**, y con
  diseño previo: con tres coches «el delta contra el otro» no existe, y hay que elegir contra qué se mide.
- **Evolución de los dos campeonatos.** El dato no existe hoy: Jolpica publica los standings de **una**
  ronda y `/api/historical` sirve la clasificación actual. La evolución pide las 24 rondas, o sea agregado
  o endpoint nuevo, más **cache por ronda** — sería el primer dato del proyecto que **no cambia nunca**, lo
  que altera el argumento con que hoy se justifica no podar las caches.
- **Evolución de la carrera seleccionada.** El dato sí existe —`/position` da 608 muestras con los 22
  coches, medido el 2026-08-27— pero depende del selector de sesión de esta fase. Va después.
- **El resto de KPI's.** Fase 7, y pide **catálogo antes que sesión**: por cada KPI, de qué endpoint sale y
  quién agrega. El rediseño pendiente de Telemetry es la advertencia escrita de lo que pasa sin él — un KPI
  pedido como widget que resulta ser un cambio de contrato del DTO.

## Fase 7 – Analítica con `Mathematical_Data_Analysis`

**Objetivo:** reutilizar tu código de análisis:

- Importar módulos relevantes a `/analysis`.
- Exponer funciones como:
  - normalización de datos.
  - detección de outliers.
  - métricas avanzadas (ej. consistencia de vueltas, degradación, etc.).
- Integrar estas funciones en widgets:
  - KPIs personalizados.
  - dashboards de performance.

**Entregables:**

- Al menos un widget que use directamente funciones del repositorio de análisis.
- Documentación en `/docs/ANALYSIS.md` explicando qué se reutiliza.
