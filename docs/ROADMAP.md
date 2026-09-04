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
    - **Esta línea estaba incompleta desde que se escribió, y no se descubrió hasta el 2026-09-03.**
      Es lo que la Fase 2 construyó de verdad y por eso se conserva, pero una **lista plana** no tiene
      dónde guardar la colocación, y el requisito real —cada widget con su posición y su tamaño
      propios— nunca llegó a ningún documento. De esta línea salieron encadenadas la rejilla
      `auto-fit`, el «el orden es la colocación» del 2026-09-01 (c) y el `resize` de la
      sesión 33. La forma correcta se decide el 2026-09-03 y los requisitos que
      faltaban quedan escritos en la **Fase 6**.
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

**El diseño del 2026-09-01 son tres decisiones, y solo dos siguen en pie.** La identidad
del widget y la forma de `WidgetParams` quedan **firmes** y el código de la sesión 33 las ejercita. La
tercera —qué guarda `Layout`, que concluía que no cambiaba— **queda superada el 2026-09-03**: se apoyaba
en la lista plana de la L56, y la lista plana era la premisa incompleta. Ver la ampliación de abajo.

**Ampliación del 2026-09-03 — tres requisitos que nunca estuvieron escritos, y de ahí el fallo.** No son
nuevos: se dijeron al principio del proyecto y **no llegaron a ningún documento**, así que las decisiones
de las sesiones 32 y 33 se tomaron sobre una premisa incompleta. Se escriben aquí para que no se pierdan
por tercera vez, y su forma se decide el 2026-09-03 y en sus tres decisiones hermanas:

- **El layout es un lienzo libre.** Cada widget tiene **posición y tamaño propios, independientes de los
  demás**: uno a medio layout, dos apilados junto a uno alto, uno a un tercio de alto y a la mitad de
  ancho. Se permiten **huecos vacíos**. El criterio que lo distingue de todo lo que se había escrito es
  que **la proporción de cada widget es suya y no depende de una proporción general** — que es lo que
  descarta tanto la lista plana como el árbol de particiones. En enteros de **1/120 del contenedor**,
  con imán a 24×24 — la unidad la fija el 2026-09-04, porque 120/24 = 5 es exacto y 100/24 no.
- **Los grupos los declara el autor, y acoplan el tamaño.** Membresía **arbitraria** —por piloto, por
  tipo, o por juntar una clasificación con una telemetría—, no derivada del tipo de widget ni de la
  adyacencia. Dentro del grupo el borde entre dos miembros es un separador arrastrable y el grupo se
  mueve y escala como un bloque.
- **Una caja conmuta de contenido.** El mismo sitio del layout alberga varias vistas —la clasificación
  con gap al líder, con gap al inmediato anterior o con los puntos que sumaría esa posición; o la
  telemetría de un piloto y la comparación de otros dos— con una **lista de favoritos por caja** más un
  «otro…» al catálogo completo. **Al conmutar la caja no cambia de tamaño**: un contenido más chaparro
  deja el hueco de abajo reservado.

**Dos preguntas abiertas a propósito**, anotadas como tales y no como deuda: **si dos widgets pueden
encimarse** como las ventanas de un escritorio, y **qué hace el lienzo en pantalla estrecha** —la rejilla
`auto-fit` daba el responsive gratis y un lienzo de posiciones libres no—. Las dos se deciden al ver el
lienzo funcionando, no antes.

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
- **~~La rejilla no guarda posiciones~~ — SUPERADO el 2026-09-03.** El hecho medido sigue siendo cierto:
  `repeat(auto-fit, minmax(24rem, 1fr))` con los widgets como hermanos directos de `.page--dashboard`, la
  posición la decide el navegador y `Layout` solo tiene orden de lista. Lo que ya no vale es la conclusión
  que el 2026-09-01 (c) sacó de ahí —«el orden **es** la colocación», mover es reordenar y el tamaño no se
  persiste—: con el lienzo libre la **colocación sí pasa a ser dato**, en 1/120 por widget. El
  descarte de guardar **coordenadas en píxeles** sobrevive intacto; lo que se descartaba con él y no debía
  era guardar la colocación en absoluto. Y el breakpoint de 2026-08-21 (c) deja de mandar sobre el número
  de columnas, porque deja de haber columnas: ver la pregunta abierta del responsive, arriba.

- **Y la medición del arrastre se completa el 2026-09-03, sobre `reflex-dom-core 0.8.1.3`** —el pin real,
  verificado sobre el cierre de `.#frontend`—. `Mousedown`, `Mousemove` y `Mouseup` **sí** están en el
  `EventName`, y su `EventResultType` es **`(Int, Int)`**, que es `(clientX, clientY)`: mover por
  coordenadas **no** pide `wrapDomEvent` ni `ghcjs-dom`, al contrario de lo que este punto daba por hecho
  desde el 2026-08-27. Lo que sí cuesta: `clientX` es de viewport, así que convertirlo a 1/120
  necesita el ancho del contenedor —lo da `resizeDetector`, re-exportado hasta `Reflex.Dom` y por tanto
  **sin import nuevo**—; y `domEvent Mousemove` solo dispara mientras el puntero está **encima** del
  elemento, así que el seguimiento a nivel de documento sigue pidiendo `wrapDomEvent`, o sea `ghcjs-dom`
  declarado. **El lienzo no depende de esto**: con posiciones escritas a mano funciona igual, y arrastrar
  es una capa encima.

**Entregables:**

- [ ] Layouts guardables/cargables.
- [ ] Modo “sync” básico (input manual de tiempo).
- [ ] `WidgetId` como identidad real, no derivada del tipo, y `WidgetParams` con forma decidida.
      **Forma cerrada el 2026-09-01:** id explícito que pone quien construye el `Layout` (entrada del día),
      y `WidgetParams` como récord de `wpSession`/`wpDriver`/`wpDrivers` —los tres parámetros que
      `Common.Route` ya acepta— con `noParams` (entrada (b)).
- [ ] **Lienzo libre**: posición y tamaño propios por widget, en enteros de 1/120, con huecos vacíos
      permitidos (2026-09-03). Sustituye a la rejilla `auto-fit` como mecanismo de colocación.
      **Los cuatro campos están puestos desde la sesión 35**, y los dos layouts fijos llevan ya sus
      coordenadas; falta el render, que es quien las lee.
- [ ] Widgets movibles y redimensionables. **Reescrito el 2026-09-03**: mover y redimensionar son los dos
      lo mismo —cambiar las coordenadas de ese widget— y no dos entregables de coste distinto. Ni reordenar
      la lista ni `resize: both`, que quedan superados.
- [ ] **Imán a la rejilla de 24×24** al arrastrar, activo por defecto, con interruptor visible y una tecla
      que lo invierte mientras dura el arrastre (2026-09-03). **La aritmética está en `Common.Layout.snapTo`
      desde la sesión 35**, con el imán apagado como caso normal y no como error; falta el arrastre.
- [ ] **Ancho mínimo por widget**, en `Common.Layout.minWidthFor` y no en el código de cada uno
      (2026-09-04 (b)), por debajo del cual el lienzo no deja encoger; el alto solo con mínimo de título y
      control (2026-09-03 (d)). **Los siete números están escritos desde la sesión 35, y siguen siendo a
      ojo** hasta medirlos en navegador.
- [ ] **La marca de «aquí no cabe»**, sobre `Common.Layout.fitsAt`: nada se recoloca solo, y lo que no cabe
      se avisa (2026-09-04 (c)). El predicado existe desde la sesión 35; falta pintarla.
- [ ] **Recomposición por zonas** en los seis widgets: identidad envuelve, cifras mantienen línea, y se
      escala donde no cabe. **A lo ancho no debe existir barra**, salvo el último recurso de la barra de
      **página** cuando ni el mínimo del widget más ancho quepa (2026-09-03 (d), ampliado el 2026-09-04 (c)).
- [ ] Ocultar/mostrar con menú desplegable, sobre `widgetVisible :: Bool` en `WidgetConfig` (2026-09-01 (c)).
      **Va detrás del lienzo**: escrito contra la lista plana se tiraba.
- [ ] Varias instancias del mismo tipo de widget. **No pide tipo propio**: sale del id explícito.
- [ ] Agrupación de widgets. **Reescrita el 2026-09-03 (b)**: el grupo lo **declara el autor** con
      membresía arbitraria sobre `widgetGroup :: Maybe Text`, y **acopla el tamaño** —separador compartido
      entre miembros, y el grupo se mueve y escala como bloque—. Ni adyacencia ni derivación por tipo.
- [ ] **Conmutación de contenido por caja**: lista de favoritos configurada más «otro…» al catálogo
      completo, con control híbrido —pestañas, desplegable al estrecharse, ciclado por el título—, y la
      caja conservando su rectángulo al conmutar (2026-09-03 (c)).
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
