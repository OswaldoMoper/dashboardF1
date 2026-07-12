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

Módulos:

- `Backend.Server`
- `Backend.API`
- `Backend.Types`
- `Backend.OpenF1`
- `Backend.Jolpica`
- `Backend.FastF1`
- `Backend.Cache`

---

### 2.2 Frontend (Haskell + Reflex-DOM)

Responsabilidades:

- Renderizar widgets.
- Manejar layouts.
- Suscribirse a WebSockets.
- Integrar gráficos (Plotly, Chart.js vía FFI).
- Permitir personalización.

Módulos:

- `Frontend.Main`
- `Frontend.Widgets.*`
- `Frontend.Layout`
- `Frontend.State`
- `Frontend.Render`

---

### 2.3 Microservicio FastF1 (Python)

Responsabilidades:

- Exponer telemetría avanzada.
- Comparación de vueltas.
- Cachear resultados.
- Mantener interfaz estable.

Endpoints:

- `/fastf1/telemetry/{session_key}/{driver}`
- `/fastf1/laps/{session_key}`
- `/fastf1/comparison/{session_key}?drivers=VER,LEC`

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
    - Los widgets renderizan la información.
5. Analysis Module → Backend → Widgets
    - KPIs avanzados derivados del repositorio Mathematical_Data_Analysis.
    - Se integran en widgets especializados.

Resumen textual:

- OpenF1 → Backend → Widgets (live timing, stints, laps)
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
