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
      `auto-fit`, el «el orden es la colocación» del 2026-09-01 (c) y el `resize: both` del
      2026-09-02. La forma correcta se decide el 2026-09-03 y los requisitos que
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
- [x] **Pruebas del microservicio** (2026-10-08 (f) y (g)): lo puro del feed vive en `feed.py`, sin FastF1, y
      `dashboardF1-pytest` lo prueba con fotos reales del feed y su salida guardada, más propiedades con hypothesis;
      `dashboardF1-test` lo corre antes que hspec. **Falta:** el resto de `/fastf1/live` (`_feed_session`), sin
      fecha.

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
del widget y la forma de `WidgetParams` quedan **firmes** y el código del 2026-09-02 las ejercita. La
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

**La primera se contestó el 2026-09-29 (h): dos widgets no se enciman.** Al soltar uno encima de otro, el pisado se
aparta, en cadena, y lo que no cabe encoge hasta su mínimo o no se deja. La segunda sigue abierta.

**Desde el 2026-09-07 la segunda ya se puede responder mirando, y ha crecido.** El lienzo existe, así
que la pregunta deja de ser hipotética; y ahora arrastra tres cosas concretas que antes no tenía:

- La **cabecera flotante** (2026-09-07 b) tapa lienzo, y en pantalla estrecha tapa proporcionalmente
  más. El botón que la pliega tapa una esquina siempre.
- Dentro del `@media (max-width: 52rem)`, `.app` baja su padding a `--sp-3` mientras `.canvas` resta
  `--sp-5 * 2` fijo: el lienzo queda **1,5 rem corto** en estrecho. Es un defecto conocido y se arregla
  **con** esta respuesta, no antes y no de paso.
- Las dos `grid-column` de `.widget--comparison` siguen en la hoja, **inertes**, esperando a saber si el
  estrecho vuelve a tener columnas o no.

**Lo que hoy NO se hizo, y es deliberado:** ni un `@media` escrito a ojo. Cerrar el responsive por
accidente mientras se encendía el lienzo era el riesgo, y se evitó no tocando el bloque.

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

**Ampliación del 2026-09-12 — un requisito que se había perdido y una fuente que no se sostiene.**

- **Nada es fijo, y es en dos niveles.** Lo que los widgets enseñan hoy es **un ejemplo** y no el
  producto: las siete columnas de Live Timing son una lista fija en el código, o sea andamio. Lo pedido
  es elegir **qué contenido va en cada rectángulo y con qué parámetros** —telemetría de dos pilotos
  concretos, o de uno contra su propia referencia— **y qué KPIs enseña ese contenido**. Los dos niveles
  son del usuario y **el tipo de sesión no los decide**: el mismo tipo de sesión puede querer unos KPIs
  un día y otros al siguiente.
  **Reabre los catálogos, y ninguno existe todavía:** la lista de contenidos disponibles está implícita
  en el `case` de `renderWidget`, y **un catálogo de KPIs no existe en ninguna parte**. El alcance
  elegido el 2026-09-12 es **todo lo que la fuente cubra**, lo que mete dentro los mejores sectores y
  las velocidades punta por piloto, que hoy ningún widget enseña.
- **La referencia es por tarjeta, con defecto global.** Comparar con las sesiones anteriores del gran
  premio es propiedad de **cada** tarjeta: una contra la primera práctica y la de al lado contra la
  segunda, a la vez. Un mando general fija el valor por omisión y cada tarjeta puede apartarse.
  **Ese defecto global es el selector de sesión** que esta fase ya tenía como entregable: son la misma
  pieza y no dos.
- **El directo no puede salir de OpenF1.** Medido el 2026-09-12: devuelve **401 en todos sus
  endpoints mientras hay una sesión en marcha** —incluidas las sesiones pasadas— y el acceso
  autenticado es de pago, descartado por propósito el 2026-09-06. Y `/intervals` da 404 en las tres
  prácticas **y en la clasificación**: solo la carrera lo publica, o sea **cuatro de las cinco sesiones
  del fin de semana**. Sin el feed oficial el dashboard no enseña dato real **durante** ninguna sesión,
  que es justo cuando se mira.
  **Medido también que el estado de sesión del feed no sirve para decidir:** cicla por segmento, y marcó
  «terminada» con veinticuatro minutos de clasificación por delante.
  **Afinado con la clasificación grabada:** ese tema emite «terminada» **tres veces** —el final de cada
  segmento, a las 14:18, 14:40 y 15:00— y «finalizada» **una sola vez**, a las 15:04:15. O sea que el valor
  que sí distingue el final de la sesión existe, y es otro. Medido sobre **una** clasificación, así que una
  carrera con bandera roja puede no emitirlo igual.

**Concretado el 2026-09-12 — los modos por tipo de sesión y el análisis entre sesiones del mismo gran
premio dejan de ser un requisito suelto y pasan a tener forma.** Once decisiones, registradas como
2026-09-12 (l) a (r). El resumen:

- **Un modo es un layout guardado del usuario, uno por tipo de sesión**, y el tipo que anuncia el feed solo
  **elige entre los que ya guardó**: es una llave de búsqueda y no una autoridad, así que no toca el «nada es
  fijo» de arriba. Un tipo sin layout propio arranca con un **ejemplo** de fábrica —y se llama «ejemplo» en la
  interfaz, nunca «modo»—, que es exactamente lo que los dos layouts escritos en el código ya son.
- **El tránsito pregunta y no bloquea.** Al cambiar de tipo, lo movido a mano en el modo que se deja se
  pregunta —guardar o descartar—, pero el modo nuevo carga **ya** y el aviso viaja en la cabecera: el instante
  del cambio es el arranque de la sesión, que es lo irrepetible.
- **La referencia entre sesiones vive en la tarjeta y admite varias a la vez** —el caso pedido es la tercera
  práctica contra la primera **y** la segunda—, como una columna por sesión. **El ancho se paga comparando
  menos cosas:** una tarjeta con referencias enseña **un** KPI y no la tabla entera, que es lo ya medido sobre
  el scroll horizontal y respeta que a lo ancho no exista barra nunca.
- **Comparar entre sesiones es propiedad del KPI, no de la tarjeta.** Lo admiten los tiempos de vuelta, la
  telemetría y las velocidades; no el hueco al líder ni el intervalo, que son relaciones **dentro** de una
  sesión. Por eso el selector solo ofrece referencias donde tienen sentido, y no hay que avisar de un dato que
  nadie pudo pedir.
- **Una sesión de referencia se pide una vez y se congela.** Con tres referencias y el refresco de diez
  segundos serían veinticuatro peticiones por minuto y tarjeta, y el primer acceso a una sesión del
  microservicio tarda segundos (de 3 a 17 s medidos el 2026-09-23).
- **Los parámetros tienen tres ámbitos: página, grupo y tarjeta, y manda el más cercano**, con un interruptor
  visible en la tarjeta que dice a quién obedece. «Seguir a un piloto sesión a sesión» **no es una pieza**: es
  un parámetro más, y puede vivir en los tres sitios porque quien elige es el usuario.
- **El orden de construcción**, y el primero es prerequisito de los otros dos: (1) la página sabe y dice qué
  sesión es, (2) los modos, (3) la referencia entre sesiones.

**Y el primer paso ya está pagado por el feed.** Su tema de información de sesión trae el tipo, el nombre, la
clave, el gran premio con su número, las fechas con su desfase y el estado; el microservicio **ya lo pide** en
la suscripción y el endpoint del directo lo **descarta** sin leerlo. Es una clave del diccionario que ya está
en memoria.

**Comprobado sobre la foto real el 2026-09-14, y no solo sobre el flujo de deltas:** la respuesta a la
suscripción trae ese tema con el estado **actualizado** —una carrera del día anterior llegó ya como
finalizada—, así que el estado se puede leer sin sostener la conexión. El número de reunión vale 14 para el
decimocuarto gran premio del año, lo que **es compatible** con la ronda que la gramática `AÑO-RONDA-SESIÓN`
del microservicio espera, pero contrastarlo contra el calendario sigue **sin hacerse**: de ese encaje depende
poder nombrar las sesiones anteriores del gran premio.

**Y el estado que sirve no es el del tema de estado de sesión, que es otro.** Medido sobre una clasificación
y una carrera: el tema propio cicla por segmento —marca «terminada» tres veces en una clasificación— mientras
el campo que viaja **dentro** del tema de información de sesión no pasa nunca por ese valor, y va de «en
marcha» a «finalizada» directamente. Son dos señales distintas con el mismo nombre, y la útil es la segunda.

**Entregables:**

- [ ] **La página sabe y dice qué sesión es** (2026-09-12): tipo, gran premio y estado, leídos del tema de
      información de sesión del feed. **Prerequisito de los dos siguientes** y el más pequeño de los tres: los
      modos necesitan el tipo y la referencia necesita la identidad del gran premio.
      **Forma cerrada el 2026-09-14, y son siete campos y no tres:** al tipo, el gran premio y el estado se
      suman el nombre de la sesión, la vuelta actual, el total y el reloj. Los cuatro primeros son texto del
      propio tema; los tres últimos vienen de otros dos temas del feed y **ninguno está siempre**.
      - **El dato de sesión envuelve las filas** en la respuesta del directo, en vez de viajar en cabeceras:
        es contenido y no metadato, y no cabe en una fila. Las cabeceras de procedencia siguen siendo lo que
        eran, que sí es metadato.
      - **La vuelta y el total van juntos o no van.** Solo la carrera los publica —medido: ningún mensaje en
        una clasificación—, así que cuatro de las cinco sesiones de un fin de semana llegan sin ellos, y eso
        es el caso normal. Separarlos dejaría representable un total sin vuelta actual, que el feed no emite.
      - **El reloj se sirve resuelto al instante de responder, no como el feed lo publicó.** Medido: en una
        carrera entera el feed publicó su reloj **dos veces**, la última a los seis minutos de empezar, así
        que servirlo crudo diría «quedan casi dos horas» hasta el final. Viaja en **segundos** y con la marca
        de si corre, de modo que quien lo pinta pueda seguir descontando entre refrescos en vez de verlo
        saltar cada diez segundos; sin esa marca se trata como parado, que es lo observado.
      - **Un estado que no se reconozca conserva su texto.** El emisor es el feed, que puede estrenar un valor
        sin avisar, así que tirarlo dejaría el aviso sin poder decir cuál llegó.
      **La mitad de backend está completa desde el 2026-09-15, y lo único que queda es pintarla.** El directo
      responde con la sesión envolviendo las filas, y la conocen **las dos fuentes**: el feed la anuncia
      entera, y OpenF1 da el tipo, el nombre y el gran premio con dos peticiones más. La cache la conserva.
      Solo el dato de ejemplo sigue sin sesión, porque no salió de ninguna.
      - **Lo que OpenF1 no puede dar, y hay que pintarlo igual:** no publica estado, ni vuelta, ni reloj, así
        que los tres llegan vacíos siempre que el dato no venga del feed — que fuera de un fin de semana es
        casi siempre. Deducir el estado de las horas previstas está descartado por medición: la sesión
        arrancó cuatro minutos después de la suya y acabó trece antes de la de fin.
      - **Falta la mitad del reloj que vive en el navegador:** el backend sirve los segundos que quedan
        resueltos al instante de responder, y quien los pinta tiene que descontarlos entre refrescos o el
        valor salta cada diez segundos.
      **La página empieza a decirlo el 2026-09-15, y lo dice en una banda propia** entre la cabecera y el
      lienzo, no dentro de la tarjeta del directo: la sesión nombra lo que enseñan todas las tarjetas a la
      vez. Enseña **gran premio y nombre**; el tipo se deja fuera porque coincide con el nombre en 50 de las
      131 sesiones del calendario —carrera y clasificación, justo las dos que más se miran— y el nombre ya
      distingue por sí solo las diez formas publicadas, sprint incluido.
      - **La petición del directo pasa a ser de la página**, porque la banda vive fuera de la tarjeta y dos
        peticiones simultáneas al mismo endpoint hacen que la segunda caiga a la cache. De paso, conmutar de
        layout deja de repetirla y la tabla ya no parpadea a «cargando» al volver.
      - **La banda no desaparece nunca**, ni sin sesión: el lienzo descuenta su alto, así que una banda
        intermitente movería las seis tarjetas arriba y abajo en cada refresco.
      - **El estado se pinta desde el 2026-09-17**, con su marca de deducido y su aviso. **Lo que queda de
        este entregable es la vuelta y el reloj**, que solo llegan del feed y por tanto solo se ven en un
        fin de semana.
- [ ] **La banda de sesión como pieza colocable** (2026-09-15): se ancla a un **borde** —arriba o abajo en
      horizontal, y los laterales con el texto en vertical—, se **mueve pero no se puede ocultar**, y vale
      tanto para el lienzo de escritorio como para la pantalla de teléfono, que todavía no existe. Hoy es un
      rectángulo fijo arriba. **Pide diseño antes que código**: un ancla a un borde no es un rectángulo en
      1/120, que es lo único que el lienzo sabe colocar, y el arrastre tampoco existe aún.
      - **Los botones que conmutan de layout se mudan a ella** con ese diseño, no antes: si los layouts van a
        ser modos atados a un tipo de sesión, su mando va con la sesión. Tiene un precio ya medido —hoy
        plegar la cabecera se los lleva a propósito, y desde la banda dejarían de esconderse—.
      - **El aspecto ya es conmutable** desde el 2026-09-15 —tarjeta o barra de pared a pared, con un mando
        en la propia banda—, pero **la elección no sobrevive a recargar**: eso llega con los layouts
        guardables.
- [x] **El estado de la sesión cuando la fuente no lo publica** (2026-09-15, **hecho el 2026-09-17**): se
      dice el que **publica** la fuente, y si no lo publica se **deduce del calendario**, pero solo cuando la
      hora de fin quedó claramente atrás; en el borde no se dice nada.
      No contradice a la medición que descartó deducirlo de las horas —una carrera arrancó cuatro minutos
      tarde y acabó trece pronto—, porque esa medición habla justo del borde que aquí se evita.
      - **El margen ya no es una lista de constantes por tipo**: sale de `duración prevista × factor`, y los
        dos números que estaban decididos —3 h en carrera, 45 min en el resto— salen solos de `1,5 ×` y
        `0,75 ×`. Lo cambió una medición: **el Sprint tiene `session_type` «Race»** y por tipo se habría
        llevado 3 h siendo de 60 min. El factor lo elige el **nombre**. Suelo 30 min y techo 4 h.
      - **Lo deducido viaja marcado** y se pinta distinto: `Finalizada*` atenuado, con un aviso que se abre
        al pulsar **y** al pasar por encima — en un teléfono no hay puntero. Sin la marca se perdería en
        silencio la propiedad de que lo que viaja es lo que la fuente dijo.
      - **La palabra va en español** —`Por empezar` / `En marcha` / `Finalizada`— y el valor de cable no
        cambia. Un estado que el feed estrene sale **crudo y sin marca**: llegó de la fuente.
- [x] **Cuál es la próxima sesión y cuánto falta** (2026-09-15, **hecho el 2026-09-17**), en la banda. «No
      hay sesión» deja de ser un estado: se enseña la última y, al lado, la siguiente con su cuenta atrás.
      - **Son cuatro casos con nombre y no un valor ausente**: con la sesión rodando la derecha **calla** y
        le deja el ancho; sin calendario dice que **aún no lo sabe**; con la sesión anunciada y sin empezar
        cuenta a **ella misma** y sin nombrarla; y acabada, a la siguiente.
      - **La etiqueta es el gran premio, salvo dentro de su propio fin de semana**, donde es el nombre de la
        sesión: en Bakú las cinco comparten gran premio y circuito.
      - **Los segundos viajan resueltos al instante de responder** y el navegador los descuenta, con un tic
        de un segundo sobre el refresco de diez.
      - **Queda vivo:** con un calendario no vacío y ninguna sesión futura —fin de temporada— dice «aún no
        se sabe», que se leería como un cargando eterno. Sin decidir; no puede darse antes de diciembre.
- [ ] **Las cifras de la banda tienen varias formas y se elige la que quepa** (2026-09-15): el reloj en tres
      —`15:00`, `0:15:00` y `00:15:00`—, la vuelta en dos —`L 12/57` y `Vuelta 12 / 57`— y, desde el
      2026-09-17, **la cuenta atrás en tres** —lo que falta, la fecha y hora, o las dos cosas—. Manda el ancho
      disponible, y la elección del usuario por encima de él. Las formas del reloj y una de la cuenta atrás
      ya existen como funciones puras con pruebas; **falta quién elige, y se construye una sola vez para las
      tres familias**. Lo que **recuerde** lo elegido llega con los layouts guardables.
      - Lo que se pinta hoy es **lo que falta, en sus tres magnitudes mayores no nulas** (`3 d 50 min 36 s`),
        que es la única forma que permite comprobar mirando que la cuenta atrás cuenta.
- [x] **El límite de peticiones de OpenF1, medido y absorbido** (2026-09-17, **hecho el 2026-09-18**). La banda
      se quedaba sin título y volvía, en ciclos, y la causa era aritmética: **la página gastaba 42 peticiones
      por minuto contra un presupuesto de 30**, y el presupuesto es de la máquina, no de la pestaña.
      - **El presupuesto no se infiere: lo publica el servicio** en su propio rechazo —`429` con
        `retry-after: 60` y el cuerpo «Max 30 requests/minute»—. Medido contra él: una ráfaga de 30 entra
        entera y la 31 se rechaza; a ≈19/min pasan 12 de 12; con el patrón real de la página, 7 GET cada
        10 s, se rechazan **12 de 84** en dos minutos; con 7 GET cada 15 s, **0 de 84** en tres.
      - **Corrige cómo se había explicado el defecto.** No son las dos peticiones que nombran la sesión las
        que se comen el rechazo: la cuota se acaba **donde pilla** —los 12 rechazos cayeron sobre las siete
        posiciones—. La banda solo pierde el título en el corte concreto en que entran las cinco filas y no
        las dos del nombre, porque entonces se guarda una tabla sin sesión; en los demás cortes cae la
        tabla entera y se sirve de lo guardado, que conserva el nombre.
      - **Lo construido, en este orden:** el rechazo deja rastro en el log; el nombre del gran premio se
        pregunta una vez por gran premio y se recuerda, de 7 peticiones a 6; un cuarto sello de
        procedencia, `recent`, para lo guardado que se sirve porque aún vale y no porque la fuente calle;
        y un freno **solo a OpenF1**: si lo guardado tiene menos de 15 s no se vuelve a bajar.
      - **El freno produce 20 s, no 15**, y es aritmética de la página: pregunta cada 10 s y el freno solo
        puede saltarse preguntas enteras, así que OpenF1 se consulta cada 20 s y el gasto queda en **18
        por minuto**. Cualquier valor entre 11 y 20 da lo mismo.
      - **El directo no se frena**: con una sesión rodando sirve el feed, que es propio y no tiene
        presupuesto, y OpenF1 contesta `401`. Los 20 s solo afectan a la clasificación de una sesión
        terminada, que no cambia.
      - **El reloj de la sesión se pone al día** al servir lo reciente —se descuenta lo transcurrido— salvo
        con la sesión detenida, donde descontar inventaría que el tiempo corre.
      - **Descartado:** espaciar desde la página, porque dos pestañas vuelven a rebasar el techo y el freno
        del backend es común a todas; y reconfirmar menos a menudo de qué sesión se habla, que compra
        margen a cambio de enterarse tarde de un cambio de sesión cuando el margen ya sobra.
      - **Queda vivo:** dos peticiones que lleguen a la vez antes de que la primera guarde salen las dos a
        la red. Con 18 por minuto de gasto no rebasan el techo, pero el freno no las junta.
- [x] **La etiqueta `Live` deja de decir «en vivo» fuera de sesión** (2026-09-18, **hecho el 2026-09-21**).
      Sin sesión rodando lo que se lee es la clasificación final de la anterior; el punto parpadeaba y el
      aviso decía «en vivo: se actualiza cada 10 s», y las dos cosas eran falsas en el estado normal entre
      grandes premios. Ahora el punto va **quieto y a medio apagar**, y el aviso dice **«Sin sesión en
      marcha: se actualiza cada 10 s»** — el periodo se conserva porque es el de la página y sí es cierto.
      - **El parpadeo afirma algo sobre la sesión, no sobre el refresco**, así que si hay sesión rodando es
        una tercera pregunta y entra en el indicador por argumento, sin deducirse de la procedencia.
      - **El criterio de «rodando» es uno solo para toda la aplicación**: `Common.Types.sessionInProgress`,
        que enciende con la sesión en marcha y con un estado que el feed estrene, y apaga con la finalizada,
        la anunciada sin empezar y la que no trae estado. Lo comparte con la mitad derecha de la banda, que
        ya decidía lo mismo por su cuenta.
      - **El punto apagado lo llevan los dos sellos de refresco bueno, `fresh` y `recent`, y eso salió de
        medir**: fuera de sesión el freno hace que la respuesta llegue con uno y con otro un ciclo sí y otro
        no, así que un punto por sello habría dejado un latido de diez segundos. Los sellos que avisan de un
        fallo —guardado, de ejemplo, refresco caído— **no** se apagan: taparlos sería esconder lo único que
        el punto existe para decir.
      - **El aviso de lo reciente sí conserva el suyo**, con su hora: el punto se ve sin querer y tiene que
        estar quieto, y el aviso solo sale al apuntarlo.
- [x] **La banda conserva el último título bueno, y lo avisa** (2026-09-18, **hecho el 2026-09-22**). La banda
      enseña la última sesión que llegó con nombre, y no la de la última respuesta: una respuesta correcta
      puede no nombrar su sesión, y vaciar la banda por eso es peor que enseñar la anterior diciendo de
      cuándo es.
      - **El hueco está medido de punta a punta** (2026-09-22): dura **19 segundos y son ocho respuestas
        consecutivas** sin sesión, y la causa la publica el propio servicio de datos al rechazar la petición
        del nombre por ritmo. Deja de ser inferencia.
      - **Y la frecuencia baja al remedirla:** dos huecos en **121 bajadas reales**, un **1,7 %**. La cifra
        anterior salía de dividir una observación única por catorce.
      - **La marca se cuenta y no se suma**, sobre el estado: una marca es un estado previsto por el
        calendario, dos es una sesión conservada, y cuando concurren manda la segunda. Sin estado las dos
        salen solas, para que el aviso tenga dónde colgarse. Quién responde al dedo lo decide **si hay
        aviso** y no qué estado es.
      - **El aviso dice la edad del nombre, no la del corte**, y la cuenta la página con el mismo tic de un
        segundo que la cuenta atrás: el instante que viaja en las respuestas del hueco es el de la bajada
        mala, así que fecharlo con él diría un número exacto sobre el hecho equivocado.
      - **Falta verlo en pantalla, y no se puede forzar:** el caso conservado aparece en el 1,7 % de las
        bajadas y dura 19 segundos, así que provocarlo exigiría agotar a propósito el presupuesto de la
        fuente. Lo cubierto sin mirar son nueve casos de prueba: las cuatro combinaciones de marca, la marca
        sola sin estado, y las cuatro formas del aviso incluidos el cero y el corte largo.
- [x] **Una sola copia del directo, refrescada por el backend** (2026-09-18, **hecho el 2026-09-22**). El
      endpoint ya no baja a la red: lee una caja que refresca un reloj propio, así que el gasto lo fija el
      periodo del reloj y no cuántas pantallas miren.
      - **El problema estaba medido antes de tocar nada** (2026-09-22): con el endpoint bajando, los intentos
        por minuto eran **3,10 con una pantalla, 7,01 con dos y 11,55 con tres**, contra un presupuesto de
        **30 peticiones por minuto** que la fuente publica en su propio rechazo. Crecía casi lineal.
      - **Y con la misma medición salió un defecto que no estaba en ningún documento:** el freno estaba
        anclado al último **acierto**, así que un rechazo por ritmo no lo movía, se soltaba, y cada petición
        volvía a salir — se realimentaba justo cuando el presupuesto ya estaba agotado. En la serie de tres
        pantallas, **46 de 81 respuestas** eran bajadas fallidas.
      - **Lo entregado, remedido con el reloj puesto:** **cero** bajadas del endpoint con una, dos y tres
        pantallas (30, 60 y 90 respuestas), y **cero rechazos** en el log sobre la misma ventana.
      - **Lo que cuesta el reloj, medido aparte porque es otra pregunta:** 15 huecos entre bajadas dan una
        mediana de **23 s** y un ritmo de **2,48 bajadas por minuto**, o sea **14,9 peticiones por minuto**,
        la mitad del presupuesto. El ciclo es «esperar el periodo **más** lo que tarde la bajada», no una
        bajada cada periodo, y de ahí que salga por debajo de lo presupuestado.
      - **El reloj se para cuando nadie mira**, para que un backend levantado y sin pantalla delante cueste
        cero, como costaba antes; se apaga durante una sesión, donde manda el feed y la fuente rechaza; y se
        reinicia solo dejando línea, porque un hilo de fondo muerto congelaría la caja en silencio.
      - **La caja vieja se cuenta sola en pantalla:** pasados dos periodos, la respuesta deja de llamarse
        reciente. Es el mismo aviso que ya salía cuando la fuente no contesta, y cubre los tres caminos que
        dejan la caja vieja — el reposo, el reloj muerto y el rechazo.
      - **Contrapartida aceptada a sabiendas** (2026-09-22): una bajada lenta empuja la caja por encima del
        umbral y el aviso sale unos diez segundos. Medido: **1 de 15 huecos**, o sea el **1,4 % de las
        respuestas**, y cuando sale dice la verdad. Subir el umbral lo taparía a cambio de que un reloj
        realmente muerto tardase un minuto en delatarse, que es justo para lo que el aviso existe.
      - **Lo construido para el freno no se tiró:** el nombre recordado sigue, el sello de lo reciente pasa a
        ser el de todas las respuestas servidas de la caja, y el hueco del freno quedó como el mínimo entre
        dos intentos de llenar una caja vacía.
- [ ] **La página entera en un idioma, con detección** (2026-09-17). Hoy está mezclada: la cabecera de Live
      Timing dice `Pos / Driver / Team / Gap / Interval / Last Lap / Estado` en la misma fila. Medido: **≈48
      cadenas visibles en 5 módulos** de `frontend/` más `common`, y `frontend.cabal` **sin ninguna
      dependencia** de internacionalización. Español por defecto, y detectar de dónde miran la página.
      - **Se decide entero antes de escribir código, y se empieza por el mecanismo**, que es lo único sin
        medir: leer `navigator.language` exige una dependencia nueva o un `foreign import javascript`,
        o sea **código ciego**.
      - `Common.Types.sessionStateWord` es la semilla: nació en `common`, pura y con prueba.
- [x] **El circuito en la banda** (2026-09-17, **hecho el 2026-09-23**). El título dice «gran premio ·
      circuito · sesión» (`Common.Types.sessionTitle`). Del feed sale de `SessionInfo.Meeting.Circuit.ShortName`,
      el mismo tema que da el gran premio; de OpenF1, de `circuit_short_name` en `/sessions`. Así no aparece y
      desaparece según la fuente.
      - **Medido:** las dos fuentes dicen «Madring» para Madrid, y OpenF1 lo trae en las 131 sesiones de 2026.
      - **Los campos de sitio de OpenF1 no se contradicen:** `circuit_short_name = "Kuala Lumpur"` con
        `country_name = "Bahrain"` es el Gran Premio de Baréin disputado en Malasia (`meeting_official_name`:
        «FORMULA 1 GULF AIR BAHRAIN GRAND PRIX IN MALAYSIA 2026»).
- [x] **El feed oficial como fuente del directo, por delante de OpenF1 en la escalera** (2026-09-12):
      si trae filas **de una sesión en marcha**, son el directo; si no trae ninguna, se cae a OpenF1; y si
      **falla**, se sirve desde la cache sin intentar OpenF1, para que un feed roto durante una sesión no
      pague además los rechazos de OpenF1 antes de enseñar algo.
      **Ampliado el 2026-09-14 con un tercer caso:** si trae filas pero de una sesión **ya finalizada**,
      tampoco son el directo y se baja a OpenF1. Hizo falta porque el feed sigue contestando con la sesión
      acabada y sirve la clasificación final durante horas, así que «hay filas» no significaba «hay
      directo». El nombre de esa sesión **no se hereda** a las filas de OpenF1: no hay forma de comprobar
      que hablen de la misma. El orden lo decide **qué contesta** y no qué hora es
      — decidir por la ventana oficial se descartó porque el correr acaba antes que la hora: el
      2026-09-12 se dejó de rodar dieciocho minutos antes del final publicado, y OpenF1 no abrió hasta
      ese final.
      **La respuesta dice de qué fuente salió**, en cabecera propia y en el texto del indicador, porque
      con dos fuentes el dato de la sesión en marcha y el de la terminada no son el mismo dato.
      **Y el peldaño del feed lleva su propio techo de espera**: una foto cuesta unos diecisiete
      segundos medidos —el coste está en la conversación con el feed, no en la red—, así que el techo
      que comparten los otros clientes del microservicio leería como fallo toda respuesta buena.
      **Medido después, y pendiente de resolver:** el feed **sigue publicando la sesión terminada**
      —ocho horas después de una clasificación seguía dando su tabla final—, así que el peldaño de
      OpenF1 no se alcanza en la práctica. Se corrige con lo que mida una carrera completa.
- [ ] **Conexión permanente al feed con estado acumulado**, en el microservicio (2026-09-12). El feed
      manda deltas —un coche, un sector, un segmento— y llega a **323 mensajes por minuto** en el pico
      de una clasificación, con tres minutos casi mudos en cada corte. La respuesta a la suscripción
      trae **cada tema completo**, así que una foto por petición ya funciona; lo que la foto pierde son
      las transiciones, no el estado.
- [ ] **Cliente de SignalR en Haskell**, para mover la conexión y el acumulador al backend
      (2026-09-12). **Arranca cuando el feed sea el único camino de más de dos áreas**, y no antes: la
      condición es contable y evita convertir por plan en vez de por necesidad. No existe cliente para
      ese protocolo en el ecosistema, así que entran negociación, socket y acumulador. **Se prueba
      contra una sesión grabada** y no contra una en vivo, que es lo que lo hace abordable.
- [ ] **Catálogo de contenidos y catálogo de KPIs**, los dos niveles de «nada es fijo» (2026-09-12).
      El primero saca a un valor la lista que hoy vive en el `case` de `renderWidget`; el segundo hay
      que escribirlo entero, y arrastra la advertencia del KPI pedido que resulta ser otra cosa: por
      cada uno, de qué endpoint sale y quién agrega.
- [ ] Layouts guardables/cargables. **Ampliado el 2026-09-12:** son **los modos**, así que el layout gana
      **nombre** y queda asociado a un tipo de sesión, el feed decide cuál se carga, y el cambio arrastra el
      aviso de lo no guardado. La forma de la persistencia —disco o navegador— sigue **sin decidir**, y es lo
      que hace de éste el entregable más grande de la fase.
- [ ] **La referencia entre sesiones del gran premio, por tarjeta** (2026-09-12): varias sesiones a la vez
      como columnas, **un solo KPI** por tarjeta, el dato de cada referencia **congelado** al cargarlo, y el
      selector ofreciendo solo las que ese KPI admite. Va **después** del catálogo de KPIs, que es de donde
      sale la marca de qué se puede comparar.
- [ ] Modo “sync” básico (input manual de tiempo).
- [ ] `WidgetId` como identidad real, no derivada del tipo, y `WidgetParams` con forma decidida.
      **Forma cerrada el 2026-09-01:** id explícito que pone quien construye el `Layout` (entrada del día),
      y `WidgetParams` como récord de `wpSession`/`wpDriver`/`wpDrivers` —los tres parámetros que
      `Common.Route` ya acepta— con `noParams` (entrada (b)).
- [x] **Lienzo libre**: posición y tamaño propios por widget, en enteros de 1/120, con huecos vacíos
      permitidos (2026-09-03). Sustituye a la rejilla `auto-fit` como mecanismo de colocación.
      **Los cuatro campos están puestos desde el 2026-09-04**, y el render los lee desde el 2026-09-07
      (`Common.Layout.slotStyle`, aplicado por el slot de `Pages.Dashboard`). Lo que falta para moverlos
      es el arrastre, en el entregable siguiente.
- [ ] Widgets movibles y redimensionables. **Reescrito el 2026-09-03**: mover y redimensionar son los dos
      lo mismo —cambiar las coordenadas de ese widget— y no dos entregables de coste distinto. Ni reordenar
      la lista ni `resize: both`, que quedan superados. **Decidido entero el 2026-09-29 (g) y (h)**: en modo
      edición, se coge por el título y se estira por la esquina; soltar encima empuja. **El empuje, puro, está en
      `Common.Push.applyDrag` desde ese día**. **Desde el 2026-09-30 (b) los layouts se ocultan en vez de
      reconstruirse.** **Hecho:** el modo edición pintado (2026-10-07 (e)), mover por el título con lo empujado
      deslizándose (2026-10-07 (f)) y estirar por la esquina ◢ (2026-10-07 (g)), con el gesto puro en
      `Common.Carry`. **Lo movido se recuerda** en el navegador al terminar la edición, cada layout lo suyo, con
      «↺ Restablecer» y un aviso si lo guardado ya no encaja (2026-10-07 (h) e (i); `Common.Saved`), **con el lado de
      «⇄»** (2026-10-08 (a)). **Sumado después, en este orden:** que «↺ Restablecer» pida confirmar si hay algo que
      perder; «✗ Cancelar», que devuelve los dos layouts a como estaban al entrar y también pide confirmar
      (2026-10-08 (h)); recordar la banda de Lap Comparison con su modo (2026-10-08 (i)); la proporción del tipo 3 al
      estirar; y, sin fecha, mover columnas, resaltar pilotos, el tipo 4 y el aire repartido.
- [x] **Imán a la rejilla de 24×24** al arrastrar, activo por defecto, con interruptor visible y una tecla
      que lo invierte mientras dura el arrastre (2026-09-03). **La aritmética está en `Common.Layout.snapTo`
      desde el 2026-09-04**, con el imán apagado como caso normal y no como error. La tecla es **Alt** y el
      interruptor «⊞ Imán» va junto al del modo edición (2026-09-29 (g)), pintado el 2026-10-07 (e).
- [x] **Tamaño mínimo por widget**, en `Common.Layout.minWidthFor` y `minHeightFor` y no en el código de cada
      uno (2026-09-04 (b)). **Medidos en Edge el 2026-09-29 (i)**: el ancho más estrecho sin barra y el alto
      con una fila de datos, en múltiplos de 5. Medirlos desde la propia página queda para después.
- [ ] **La marca de «aquí no cabe»**, sobre `Common.Layout.fitsAt`: nada se recoloca solo, y lo que no cabe
      se avisa (2026-09-04 (c)). El predicado existe desde ese mismo día. **Al arrastrar, hecha:** el «no se deja» en
      rojo y, al soltar, la tarjeta vuelve (2026-10-07 (f)). **Al cargar ya no tiene a quién pintarse:** lo guardado que
      no encaja vuelve al de fábrica con aviso (2026-10-07 (h)). Sigue abierta y sin fecha, y se revisa con la
      recomposición por zonas.
- [ ] **Recomposición por zonas** en los seis widgets: identidad envuelve, cifras mantienen línea, y se
      escala donde no cabe. **A lo ancho no debe existir barra**, salvo el último recurso de la barra de
      **página** cuando ni el mínimo del widget más ancho quepa (2026-09-03 (d), ampliado el 2026-09-04 (c)).
- [ ] Ocultar/mostrar con menú desplegable, sobre `widgetVisible :: Bool` en `WidgetConfig` (2026-09-01 (c)).
      **Va detrás del lienzo**: escrito contra la lista plana se tiraba.
- [ ] Varias instancias del mismo tipo de widget. **No pide tipo propio**: sale del id explícito.
- [ ] Agrupación de widgets. **Reescrita el 2026-09-03 (b)**: el grupo lo **declara el autor** con
      membresía arbitraria sobre `widgetGroup :: Maybe Text`, y **acopla el tamaño** —separador compartido
      entre miembros, y el grupo se mueve y escala como bloque—. Ni adyacencia ni derivación por tipo.
      **Ampliada el 2026-09-12:** el grupo es además el **ámbito intermedio de un parámetro** —página, grupo,
      tarjeta, y manda el más cercano—, así que agrupar deja de ser solo disposición.
- [ ] **Conmutación de contenido por caja**: lista de favoritos configurada más «otro…» al catálogo
      completo, con control híbrido —pestañas, desplegable al estrecharse, ciclado por el título—, y la
      caja conservando su rectángulo al conmutar (2026-09-03 (c)).
- [ ] Selector de sesión compartido por la página. Estado de **página**, no de `Layout`.
      **Ampliado el 2026-09-12:** es el **defecto global** de la referencia por tarjeta, así que el
      selector y comparar con las sesiones anteriores del gran premio son **la misma pieza**. Y la
      lista de dónde elegir ya está medida: el endpoint de sesiones de OpenF1, filtrado por reunión,
      publica las cinco del fin de semana con su tipo y su nombre. Ojo al filtrar por tipo: los valores
      son tres —prácticas, clasificación y carrera— y **el sprint no es uno de ellos**, sino un
      *nombre* dentro de los dos últimos, así que distinguir cuatro modos pide **los dos campos**.
      **Ampliado otra vez el 2026-09-12, entrada (q):** es el ámbito **de página** de la escalera de tres
      —página, grupo, tarjeta—, así que no es el único mando de sesión sino el de arriba. Y la sesión
      **en marcha** no hay que ir a buscarla a OpenF1: el feed la anuncia, que es justo cuando OpenF1
      está cerrado.
- [ ] **Lap Comparison elige el tipo de gráfica y compara hasta cinco** (2026-09-29 (a) y (b), 2026-09-30 (a)).
      Cuatro tipos —Delta por sectores, Lap Speed Trace, Telemetría comparativa (velocidad, acelerador y freno) y
      Lap Delta—, elegidos en el título, con la Δ **solo en las fronteras**, que es lo único exacto. Hasta cinco
      pilotos de una sesión, o un piloto en cinco sesiones; esta segunda forma llega con el selector de sesión.
      **Una sola respuesta** del microservicio elige la vuelta y trae tiempos, sectores, fronteras y curvas
      (2026-10-02 (b)). En los tipos con trazas el usuario elige el eje, las fronteras y las muestras (de 60 a 250,
      en N exactas). Una tarjeta más baja que el mínimo del tipo elegido hace scroll dentro hasta que exista el modo
      edición, y el deslizable pide como mucho una vez cada ~200 ms mientras se arrastra, más la del final
      (2026-10-01). **Hecho:** la respuesta de 1 a 5 coches, «Δ contra» en la leyenda (2026-10-02 (c)), el piloto
      sin vuelta (2026-10-02 (d)), el tipo en el título y la Telemetría comparativa (2026-10-02 (e)), que cabe en
      55 u (2026-10-06 (d)). **Hecho, Lap Speed Trace** (2026-10-06 (e) y (g)): la velocidad sola llena el alto de la
      tarjeta, con mínimo de 150 px; la fila de fronteras se decide con la velocidad en su mínimo. La tarjeta se vuelve
      a medir cuando cambia su tamaño, también al cambiar de tipo (2026-10-06 (f)). **Hecho:** las trazas dejan sitio
      al primer y al último valor de la fila, con cada valor centrado sobre su línea (2026-10-07 (a)), y en todos los
      tipos la fila se turna con una banda de sectores al pulsarla, con el valor dentro de cada tramo y el color de lo
      que pasó en el sector (2026-10-07 (b)). **Falta:** elegir hasta cinco pilotos, con una curva por piloto contra
      la base en Delta por sectores (2026-10-07 (d)), comparar sesiones (con el selector de sesión) y el directo.
      **Decidido:** el color de cada piloto, una pareja (el del equipo y el de su casco), la misma en la telemetría por
      piloto (2026-10-08 (d)). **Sin decidir:** Lap Delta, que sigue sin gráficas hasta que una tarjeta de Lap
      Comparison pueda ser más baja que el mínimo del tipo 2 (2026-10-07 (c)); con varios pilotos, los valores de la
      fila y el color de la banda; y que el usuario elija qué gráficas salen en las trazas.
- [ ] **La telemetría por piloto**: una fila por piloto con los microsectores como columnas, y un widget de hasta
      cinco pilotos con una barra por magnitud y la fila de marchas. **Decidido** (2026-10-08 (e)): cada microsector,
      con el color del feed; en directo lo que haya y de una sesión acabada todo; el microservicio entrega lo mínimo por
      piloto y las reglas son puras en `common`. **Sin decidir:** dónde se acumula lo que no sale de una foto (la
      máxima de la vuelta anterior y la de la carrera), el contrato, el ancho de la tabla, el selector de pilotos y el
      orden de trabajo.
- [x] **Live Timing: la vuelta rápida y las columnas a elegir** (2026-10-02 (f) y (g)). «Best Lap» con la más
      rápida de la sesión en negrita y la de la parte en curso en morado, y un panel «Columnas ▾» que cierra
      cualquier columna salvo «Pos» y «Driver», dejando siempre una de las de tiempo o estado. Por tarjeta y sin
      recordarse hasta el modo edición. Es un adelanto del catálogo de KPIs, que sigue pendiente.
- [ ] **Lap Comparison y las tablas de campeonato, en vivo.** Sin decidir: la comparación con lo que está en
      marcha (los sectores llegan en el directo; las trazas, solo con cuenta de F1TV) y las tablas de pilotos y
      constructores con las posiciones actuales (pide la tabla de puntos del reglamento). **Hecho:** la posición en
      esas tablas, la oficial de Jolpica (2026-10-03 (e)). **Medido el 2026-10-08:** el feed publica su propia
      predicción del campeonato (`ChampionshipPrediction`: posición y puntos actuales y previstos, por piloto y por
      equipo) en carreras y Sprints, y llega con cuenta de F1TV; el grabador la pide (2026-10-08 (c)).
- [x] **El final de una sesión, dicho como es** (2026-10-03 (a) y (b)). Tras cada bandera a cuadros la banda dice
      «Bandera a cuadros» —también entre las partes de una clasificación— y el punto del directo se apaga; con el
      `Finalised`, «Finalizada», también mientras se sirve la última tabla del feed y cuando vuelve OpenF1. La
      bandera sale de los avisos de control de carrera, contados desde la hora de inicio de la sesión.
- [ ] **Todo lo que el feed sabe de una clasificación** (2026-10-03 (c) y (d)). Decidido: la parte en la banda,
      los descansos con la cuenta atrás que anuncia control de carrera, los eliminados aparte y en gris, la zona de
      eliminación con una raya roja, el 107 % en Q1, la bandera roja y el estado de pista en la banda, y Best Lap
      como la menor de todas las partes. **Hecho, la banda** (2026-10-05 (a) y (b)): la parte («Q2», «SQ2»), la
      bandera a cuadros, la roja y la amarilla dibujadas, el estado de pista detrás del estado, y las cuentas hasta
      la parte siguiente, la reanudación y una salida retrasada, que también se dice cuando no llega a su hora.
      **Hecho, la tabla** (2026-10-06 (b) y (c)): los eliminados en gris bajo «fuera en Q1» (y «fuera en Q2»), la
      raya roja hasta que el feed los marca, Best Lap como la menor de todas las partes, y en la Q1 el 107 % junto al
      título y «>107 %» cuando lo dicen el feed y el tiempo. **Falta:** conservarlo cuando vuelve OpenF1 (con la
      dependencia de OpenF1) y verlo en una clasificación de verdad.
- [ ] **Columnas nuevas en Live Timing, Radio, Tiempo, avisos de control de carrera y la dependencia de OpenF1.**
      Cada una con lo medido y sus decisiones por tomar; sin decidir.

**Lo que NO es de esta fase**, aunque se pida junto con lo de arriba y se le parezca:

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
