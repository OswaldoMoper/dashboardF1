# telemetry-service

Microservicio Python que encapsula FastF1 para exponer telemetría avanzada y comparación de vueltas mediante una interfaz HTTP estable consumida por el backend Haskell. Ver [`docs/ARCHITECTURE.md §2.3`](../docs/ARCHITECTURE.md#23-microservicio-fastf1-python).

> **Estado (Fase 4):** los endpoints de telemetría y comparación están implementados en [`main.py`](main.py). El de vueltas sigue pendiente. El empaquetado como derivación Nix también está pendiente: `fastf1` arrastra pandas/numpy/matplotlib y no bloquea nada hoy (2026-07-31).

## Cómo levantarlo

Las dependencias se declaran en `requirements.txt` y se instalan **fuera de Nix**, en un venv:

```sh
nix develop .#telemetry          # python3 + pip + virtualenv
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app                 # http://127.0.0.1:8000
```

El backend Haskell lo localiza con `TELEMETRY_HOST` (default `127.0.0.1`) y `TELEMETRY_PORT` (default `8000`).

## Variables de entorno

| Variable | Default | Qué hace |
| --- | --- | --- |
| `FASTF1_CACHE` | `.fastf1-cache` | Directorio de cache de FastF1 (se crea si no existe). **La primera llamada a una sesión nueva descarga datos y tarda minutos**; con la cache caliente responde al instante. |
| `TELEMETRY_MAX_POINTS` | `60` | Muestras por piloto tras el submuestreo, y puntos del delta de `/fastf1/comparison`. Una vuelta a 10 Hz son miles de muestras y el widget pinta una tabla. |

## Endpoints

### `GET /fastf1/telemetry/{session_key}/{driver}` — implementado

- **`session_key`**: `latest` (última carrera ya disputada) o `AÑO-RONDA-SESIÓN` con **guiones**, porque es un solo segmento de path: `2026-13-R`, `2026-13-Q`, `2026-13-FP2`.
- **`driver`**: `all` (todos los pilotos de la sesión) o una lista de **números de coche** separados por comas: `1,4,16`.
- **Vuelta**: la **más rápida** de cada piloto — la única elección comparable entre coches.

Devuelve un arreglo JSON **plano y etiquetado**, con las mismas claves que `Common.Types.TelemetryPoint`:

```sh
curl 'localhost:8000/fastf1/telemetry/latest/all' | head -c 300
```

```json
[{"tpDriver":"VER","tpSessionTime":3512.418,"tpDistance":0.0,"tpSpeed":312.0,
  "tpThrottle":1.0,"tpBrake":0.0,"tpGear":8,"tpRpm":11800}]
```

Contrato con el lado Haskell (2026-07-31):

- **El servicio normaliza las unidades del DTO.** FastF1 publica `Throttle` en 0–100 y `Brake` como booleano; aquí salen `tpThrottle` en 0.0–1.0 y `tpBrake` como `0.0`/`1.0`.
- **Nunca `NaN`.** `json.dumps` lo emitiría y **aeson rechaza el arreglo completo**. Un valor no numérico sale como `null` si el campo es prescindible (`tpThrottle`, `tpBrake`, `tpGear`, `tpRpm`) y descarta la muestra si es obligatorio (`tpDriver`, `tpSessionTime`, `tpDistance`, `tpSpeed`).
- **Degradar es del backend.** Una sesión sin telemetría devuelve `[]`, no un error: `Handler.Telemetry.Context` es quien cae a su cache STM o al dummy. Un piloto sin vuelta válida se omite y los demás se sirven igual.
- Sesión irresoluble → `404`; `session_key` o `driver` mal formados → `400`.

Nota operativa: las sesiones cargadas se memorizan en proceso, así que **`latest` se congela mientras `uvicorn` viva**. Reiniciarlo para volver a resolverlo.

### `GET /fastf1/comparison/{session_key}?drivers=1,16` — implementado

- **`session_key`**: igual que en telemetría.
- **`drivers`**: **exactamente dos** números de coche. Obligatorio. `all`, uno solo o tres son **`400`**: `LapComparison` tiene A y B, no una lista, así que no hay respuesta parcial que dar.
- **Vuelta**: la **más rápida** de cada coche, igual que en telemetría.

Devuelve **un objeto** (no un arreglo) con las cinco claves de `Common.Types.LapComparison`:

```sh
curl 'localhost:8000/fastf1/comparison/latest?drivers=1,16'
```

```json
{"lcDriverA":"VER","lcDriverB":"LEC","lcLapA":"1:29.345","lcLapB":"1:29.512",
 "lcDelta":[0.0,-0.048,0.081,0.124,0.167]}
```

- **`lcDelta` es el delta acumulado A−B** sobre la rejilla de distancias de A: en cada punto, el tiempo que A llevaba menos el que B llevaba **a esa misma distancia**, interpolado linealmente. Positivo = A va por detrás. Submuestreado con `TELEMETRY_MAX_POINTS` y saneado con el mismo criterio de `NaN` (un solo `NaN` tumbaría el decode del objeto **completo**).
- **El servicio formatea los tiempos** (`M:SS.mmm`): `lcLapA`/`lcLapB` son `Text` en el DTO, y un `Timedelta` por `str()` daría `0 days 00:01:29.345000`.
- **Entra número de coche, sale acrónimo**: la traducción la sabe hacer solo este servicio (`session.get_driver`). Mismo vocabulario que `/fastf1/telemetry`.
- **Degradar es del backend.** Una sesión sin vueltas comparables devuelve `lcDelta: []` y los tiempos en `""`, no un error: `Handler.Comparison.Context` es quien cae a su cache o al dummy. Las cinco claves están siempre.

### Pendientes

- `GET /fastf1/laps/{session_key}`
