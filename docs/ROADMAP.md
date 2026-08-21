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

**Entregables:**

- Layouts guardables/cargables.
- Modo “sync” básico (input manual de tiempo).

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
