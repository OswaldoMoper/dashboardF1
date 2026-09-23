# telemetry-service

Microservicio Python que encapsula FastF1 para exponer telemetría avanzada y comparación de vueltas mediante una interfaz HTTP estable consumida por el backend Haskell. Ver [`docs/ARCHITECTURE.md §2.3`](../docs/ARCHITECTURE.md#23-microservicio-fastf1-python).

> **Estado (Fase 4):** los **cuatro** endpoints del contrato están implementados en [`main.py`](main.py) desde el 2026-08-13. El empaquetado Nix está hecho desde el 2026-08-12.

## Cómo levantarlo

Las dependencias las declara y las pinea `flake.nix`, que es la **única** fuente de verdad: no hay `requirements.txt` ni venv que reconstruir.

```sh
nix run .#telemetry              # http://127.0.0.1:8000
nix run .#telemetry -- --port 8010    # los argumentos pasan a uvicorn
```

Para iterar sobre `main.py` sin un rebuild por edición, el dev shell trae el mismo intérprete con las mismas dependencias:

```sh
nix develop .#telemetry
cd telemetry-service && uvicorn main:app
```

En los dos casos conviene arrancar con `telemetry-service/` como directorio de trabajo: la cache de FastF1 es **relativa** a él (ver `FASTF1_CACHE` abajo), así que desde otro sitio se descarga entera de nuevo.

El backend Haskell lo localiza con `TELEMETRY_HOST` (default `127.0.0.1`) y `TELEMETRY_PORT` (default `8000`).

## Variables de entorno

| Variable | Default | Qué hace |
| --- | --- | --- |
| `FASTF1_CACHE` | `.fastf1-cache` | Directorio de cache de FastF1 (se crea si no existe). **La primera llamada a una sesión nueva descarga datos y tarda segundos** (16,6 s una carrera, medido el 2026-09-23); tras arrancar, una sesión ya descargada se lee de disco en unos 3 s, y ya cargada responde al instante. |
| `TELEMETRY_MAX_POINTS` | `60` | Muestras por piloto tras el submuestreo de `/fastf1/telemetry`. Una vuelta a 10 Hz son miles de muestras y el widget pinta una tabla. **No afecta a `/fastf1/comparison`** desde el 2026-08-11: su delta son cuatro fronteras de sector, no una serie submuestreada. |

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

Contrato con el lado Haskell (decidido el 2026-07-31):

- **El servicio normaliza las unidades del DTO.** FastF1 publica `Throttle` en 0–100 y `Brake` como booleano; aquí salen `tpThrottle` en 0.0–1.0 y `tpBrake` como `0.0`/`1.0`.
- **Nunca `NaN`.** `json.dumps` lo emitiría y **aeson rechaza el arreglo completo**. Un valor no numérico sale como `null` si el campo es prescindible (`tpThrottle`, `tpBrake`, `tpGear`, `tpRpm`) y descarta la muestra si es obligatorio (`tpDriver`, `tpSessionTime`, `tpDistance`, `tpSpeed`).
- **Degradar es del backend.** Una sesión sin telemetría devuelve `[]`, no un error: `Handler.Telemetry.Context` es quien cae a su cache STM o al dummy. Un piloto sin vuelta válida se omite y los demás se sirven igual.
- Sesión irresoluble → `404`; `session_key` o `driver` mal formados → `400`.

Nota operativa: las sesiones cargadas se memorizan en proceso, así que **`latest` se congela mientras `uvicorn` viva**. Reiniciarlo para volver a resolverlo.

### `GET /fastf1/comparison/{session_key}?drivers=1,16` — implementado

- **`session_key`**: igual que en telemetría.
- **`drivers`**: **exactamente dos** números de coche. Obligatorio. `all`, uno solo o tres son **`400`**: `LapComparison` tiene A y B, no una lista, así que no hay respuesta parcial que dar.
- **Vuelta**: la **más rápida** de cada coche, igual que en telemetría.

Devuelve **un objeto** (no un arreglo) con las siete claves de `Common.Types.LapComparison`:

```sh
curl 'localhost:8000/fastf1/comparison/latest?drivers=1,16'
```

```json
{"lcDriverA":"NOR","lcDriverB":"LEC","lcCarA":"1","lcCarB":"16",
 "lcLapA":"1:22.491","lcLapB":"1:22.000","lcDelta":[0.0,0.051,0.484,0.491]}
```

- **`lcDelta` son cuatro valores en las cuatro fronteras de sector** —línea de meta, fin de S1, fin de S2, fin de vuelta—: el tiempo acumulado de A menos el de B en cada una. Positivo = A va por detrás. **Son sectores y no una curva de vuelta a propósito** (2026-08-11): un delta por distancia exige un eje que diga «el mismo punto de la pista» en los dos coches, y FastF1 no publica ninguno — los tiempos de sector, en cambio, los publica en vez de integrarlos.
- **Los cuatro valores son exactos**, y con ellos los dos invariantes: `lcDelta[0] == 0.0` (los dos coches en la línea) y `lcDelta[-1] == lcLapA - lcLapB` al milisegundo. El precio es que **son cuatro puntos y no sesenta**, así que el gráfico es una quebrada de tres tramos: dentro de un sector no se dice nada, que es exactamente lo que se sabe. `TELEMETRY_MAX_POINTS` **no** afecta a este endpoint desde el 2026-08-11.
- Saneado con el mismo criterio de `NaN` que la telemetría (un solo `NaN` tumbaría el decode del objeto **completo**).
- **El servicio formatea los tiempos** (`M:SS.mmm`): `lcLapA`/`lcLapB` son `Text` en el DTO, y un `Timedelta` por `str()` daría `0 days 00:01:29.345000`.
- **Entra número de coche, sale acrónimo**: la traducción la sabe hacer solo este servicio (`session.get_driver`). Mismo vocabulario que `/fastf1/telemetry`. `lcCarA`/`lcCarB` devuelven los números tal como entraron, que es lo que permite al widget pedir **otra** comparación (2026-08-05).
- **Degradar es del backend.** Una sesión sin vueltas comparables devuelve `lcDelta: []` y los tiempos en `""`, no un error: `Handler.Comparison.Context` es quien cae a su cache o al dummy. Las siete claves están siempre.

### `GET /fastf1/drivers/{session_key}` — implementado

- **`session_key`**: igual que en telemetría.

Devuelve la **parrilla de la sesión** como lista de objetos con las claves de `Common.Types.DriverEntry`:

```json
[{"deNumber":"1","deCode":"NOR","deTeam":"McLaren"}]
```

- Es el único endpoint que **publica** la traducción número↔acrónimo que los otros dos aplican por dentro, y por eso es lo que permite a un consumidor que habla acrónimos construir un query que pide números (2026-08-01 y 2026-08-06).
- **La parrilla es la de la sesión, no la del campeonato**: un sustituto o un tercer coche en libres la cambian, y por eso el backend cachea por `session_key`. El orden es el que da FastF1 y no se reordena.
- Un coche cuyo acrónimo no resuelve sale igual, con `deCode` repetido del número; un equipo ausente sale como `""`. Una sesión sin parrilla devuelve `[]`, **no** un error.

### `GET /fastf1/laps/{session_key}?driver=all` — implementado

- **`session_key`**: igual que en telemetría.
- **`driver`**: **opcional** (default `all`). `all` o una lista de números de coche: `1,16`. Mismo vocabulario que `/fastf1/telemetry`.
- **Vueltas**: **todas** las de la sesión, no la rápida. Es el único endpoint que devuelve la sesión entera (~1400 objetos en una carrera), y por eso `driver` filtra en el servicio: hacerlo después obligaría a mover la sesión completa para tirar el 95 %.

Devuelve una lista de objetos, uno por vuelta:

```sh
curl 'localhost:8000/fastf1/laps/latest?driver=1' | head -c 220
```

```json
[{"leDriver":"NOR","leNumber":"1","leLap":1,"leTime":"1:31.211","leSector1":null,
  "leSector2":32.05,"leSector3":24.383,"leCompound":"MEDIUM","leTyreLife":1}]
```

- **Es el único de los cuatro sin DTO en `common`**, y el prefijo `le` es el que un futuro `LapEntry` usaría (2026-08-13). Hoy ningún `/api/*` lo consume: el DTO fija el contrato para quien decodifica, y el precedente es `/fastf1/drivers`, que esperó al widget.
- **Una vuelta sin tiempo se emite**, con `leTime` en `""`: las de entrada a boxes, de salida y las cortadas por bandera roja son vueltas reales, y filtrarlas sería decidir por el consumidor cuáles cuentan. Igual con los sectores ausentes (`null`) y el compuesto que FastF1 no publica (`""`, incluida la cadena `'None'` que escribe en esa columna). **Degradar es del backend.**
- **`leTime` y los sectores son coherentes**: sobre `latest`, `leTime == leSector1 + leSector2 + leSector3` en las 1407 vueltas que traen los tres, al milisegundo — y el `leTime` de la vuelta rápida de un coche coincide con el `lcLapA`/`lcLapB` que publica `/fastf1/comparison`.
- **El orden es el de FastF1**: vueltas de cada coche contiguas y en orden de vuelta, coches en el orden de `driver` (o de la parrilla con `all`). No se reordena.
- `TELEMETRY_MAX_POINTS` **no** aplica: una vuelta es una fila, no una serie. Un coche que no está en la sesión devuelve `[]` con **200**; una sesión sin vueltas, `[]`. `driver` vacío → `400`.
