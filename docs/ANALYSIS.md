# ANALYSIS – F1 Functional Dashboard

Este documento explica cómo se integra el módulo de analítica, todavía por integrar.

Se ajustará al llegar a la fase que le compete.

## 1. Objetivo

Añadir análisis matemático para:

- KPIs avanzados.
- Normalización de datos.
- Detección de outliers.
- Métricas de degradación.
- Consistencia de vueltas.
- Comparación estadística entre pilotos.

## 2. Módulos

El módulo tendrá:

- `Normalization.hs`
- `Outliers.hs`
- `Regression.hs`
- `Transforms.hs`
- `Metrics.hs`

## 3. Integración con Backend

El backend tendrá un módulo:

`Analysis.Integration`

Responsabilidades:

- Convertir datos de OpenF1/FastF1 a estructuras matemáticas.
- Aplicar funciones de análisis.
- Exponer KPIs vía Servant.

Ejemplo de endpoint:

`/api/kpi/consistency/{session_key}/{driver}`

## 4. Integración con Widgets

Widgets que usarán analítica:

- KPI Widget
- Degradation Widget
- Consistency Widget
- Outlier Detection Widget

## 5. Invariantes

- La analítica nunca bloquea el live timing.
- Los KPIs se calculan sobre datos cacheados.
- Las funciones matemáticas deben ser puras.

## 6. Riesgos

- Costo computacional de análisis profundo.
- Necesidad de cachear resultados.

## 7. Dependencias

Este módulo depende de:

- OpenF1 (datos base)
- FastF1 (telemetría avanzada)
- Las funciones matemáticas de `/analysis`
