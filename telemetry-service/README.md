# telemetry-service

Microservicio Python que encapsula FastF1 para exponer telemetría avanzada y comparación de vueltas mediante una interfaz HTTP estable consumida por el backend Haskell. Ver [`docs/ARCHITECTURE.md §2.3`](../docs/ARCHITECTURE.md#23-microservicio-fastf1-python).

> **Estado (Fase 0):** solo entorno y contrato documentado. **Sin lógica todavía** — se implementa en Fase 4.

## Endpoints objetivo

- `GET /fastf1/telemetry/{session_key}/{driver}`
- `GET /fastf1/laps/{session_key}`
- `GET /fastf1/comparison/{session_key}?drivers=VER,LEC`
