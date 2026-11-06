# telemetry-service

Microservicio Python que encapsula FastF1 para exponer la comparación de vueltas (con sus trazas), la parrilla y las vueltas mediante una interfaz HTTP estable consumida por el backend Haskell. Ver [`docs/ARCHITECTURE.md §2.3`](../docs/ARCHITECTURE.md#23-microservicio-fastf1-python).

> **Estado (Fase 4):** los **tres** endpoints del contrato están implementados en [`main.py`](main.py) desde el 2026-08-13. El empaquetado Nix está hecho desde el 2026-08-12.

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

El backend Haskell lo localiza con `TELEMETRY_HOST` (default `127.0.0.1`) y `TELEMETRY_PORT` (default `8000`), o por el socket Unix que nombre `TELEMETRY_SOCKET`, que tiene prioridad (vacía cuenta como no definida). Al arrancar escribe por dónde lo busca. Para que escuche en un socket: `--uds <ruta>` en vez de `--port`.

## Pruebas

Las de `tests/` cubren lo puro del feed (`feed.py`): la salida de `_feed_rows` sobre fotos reales del feed, comparada
con la guardada en `tests/esperado/`, y sus reglas como propiedades con hypothesis. Desde la raíz del repositorio:

```sh
dashboardF1-pytest
```

`dashboardF1-test` las corre antes que las de Haskell. Las fotos salen de una grabación de `dashboardF1-record`, y un
cambio intencionado de la salida se regenera, se prueba y se revisa en el diff; los dos usos, en la cabecera de
`tests/fotos.py`. Hypothesis guarda en `.hypothesis/` los ejemplos que fallaron y los repite primero.

## Variables de entorno

| Variable | Default | Qué hace |
| --- | --- | --- |
| `FASTF1_CACHE` | `.fastf1-cache` | Directorio de cache de FastF1 (se crea si no existe). **La primera llamada a una sesión nueva descarga datos y tarda segundos** (16,6 s una carrera, medido el 2026-09-23); tras arrancar, una sesión ya descargada se lee de disco en unos 3 s, y ya cargada responde al instante. |
## Endpoints

Contrato con el lado Haskell (decidido el 2026-07-31), común a los tres:

- **`session_key`**: `latest` (última carrera ya disputada) o `AÑO-RONDA-SESIÓN` con **guiones**, porque es un solo segmento de path: `2026-13-R`, `2026-13-Q`, `2026-13-FP2`.
- **El servicio normaliza las unidades del DTO.** FastF1 publica `Throttle` en 0–100 y `Brake` como booleano; en la traza de la comparación salen `ctThrottle` en 0.0–1.0 y `ctBrake` como `0.0`/`1.0`.
- **Nunca `NaN`.** `json.dumps` lo emitiría y **aeson rechaza la respuesta completa**. Un valor no numérico sale como `null` si el campo es prescindible y descarta la muestra si es obligatorio.
- **Degradar es del backend.** Lo que falta no es un error: el `Context` de cada área es quien cae a su cache STM o al dummy.
- Sesión irresoluble → `404`; parámetros mal formados → `400`.

Nota operativa: las sesiones cargadas se memorizan en proceso, así que **`latest` se congela mientras `uvicorn` viva**. Reiniciarlo para volver a resolverlo. Una sesión que cargó vacía (sin token de F1TV, sin vueltas) no se congela: se vuelve a pedir en cuanto cambia el fichero del token o a los 10 min, lo que pase antes.

### `GET /fastf1/comparison/{session_key}?drivers=16,1&samples=0` — implementado

- **`session_key`**: como arriba.
- **`drivers`**: **de 1 a 5** números de coche, **la referencia primero**. Obligatorio. `all` o más de cinco son **`400`**.
- **`samples`**: muestras por coche de la traza, **0** (sin traza, por defecto) o **de 60 a 250 de 5 en 5**; lo demás es **`400`**. El backend ajusta antes lo que pide el usuario (`Handler.Comparison.Helper.adjustSamples`).
- **Vuelta**: la **más rápida** de cada coche —la única elección comparable entre coches—, y **la misma** para los sectores, las fronteras y la traza.

Devuelve **un objeto** (no un arreglo) con las claves de `Common.Types.LapComparison`:

```sh
curl 'localhost:8000/fastf1/comparison/latest?drivers=16,1'
```

```json
{"lcSamples":0,"lcEntries":[
  {"ceCar":"16","ceDriver":"LEC","ceLap":"1:22.000","cePart":null,
   "ceSectors":[27.1,30.4,24.5],"ceFrontiers":null,"ceTrace":[]},
  {"ceCar":"1","ceDriver":"NOR","ceLap":"1:22.491","cePart":null,
   "ceSectors":[27.151,30.833,24.507],"ceFrontiers":null,"ceTrace":[]}]}
```

- **La Δ no viaja**: la calcula `common` desde `ceSectors` (`Common.Comparison.deltasAgainst`), contra la referencia o contra el más rápido. Los sectores son **exactos** porque FastF1 los **publica** en vez de integrarlos (2026-08-11): un delta a lo largo de la vuelta exige un eje que diga «el mismo punto de la pista» en todos los coches, y FastF1 no publica ninguno.
- **Con `samples` > 0**, cada coche lleva **`ceFrontiers`** —dónde cruzó S1 y S2, en metros, calculado con la vuelta completa— y **`ceTrace`**: `samples` muestras (`ctTime`, `ctDistance`, `ctSpeed`, `ctThrottle` de 0 a 1, `ctBrake` 0 o 1) repartidas por posición, con la primera y la última. Con 0 no se toca la telemetría.
- **`cePart`**: `Q1`, `Q2` o `Q3` en una clasificación (`split_qualifying_sessions`); `null` en lo demás.
- **Un coche sin vuelta no es un error**: sale con `ceSectors: null`, `ceLap: ""` y sin fronteras ni traza. Degradar es del backend: `Handler.Comparison.Context` cae a su cache o al dummy solo si **ninguno** tiene vuelta.
- **El servicio formatea los tiempos** (`M:SS.mmm`), y sanea con el criterio de `NaN` de arriba.
- **Entra número de coche, sale acrónimo**: `ceCar` devuelve el número tal como entró, que es lo que permite al widget pedir **otra** comparación (2026-08-05).

### `GET /fastf1/drivers/{session_key}` — implementado

- **`session_key`**: como arriba.

Devuelve la **parrilla de la sesión** como lista de objetos con las claves de `Common.Types.DriverEntry`:

```json
[{"deNumber":"1","deCode":"NOR","deTeam":"McLaren"}]
```

- Es el único endpoint que **publica** la traducción número↔acrónimo que los otros dos aplican por dentro, y por eso es lo que permite a un consumidor que habla acrónimos construir un query que pide números (2026-08-01 y 2026-08-06).
- **La parrilla es la de la sesión, no la del campeonato**: un sustituto o un tercer coche en libres la cambian, y por eso el backend cachea por `session_key`. El orden es el que da FastF1 y no se reordena.
- Un coche cuyo acrónimo no resuelve sale igual, con `deCode` repetido del número; un equipo ausente sale como `""`. Una sesión sin parrilla devuelve `[]`, **no** un error.

### `GET /fastf1/laps/{session_key}?driver=all` — implementado

- **`session_key`**: como arriba.
- **`driver`**: **opcional** (default `all`). `all` o una lista de números de coche: `1,16`. Mismo vocabulario que `drivers` en la comparación.
- **Vueltas**: **todas** las de la sesión, no la rápida. Es el único endpoint que devuelve la sesión entera (~1400 objetos en una carrera), y por eso `driver` filtra en el servicio: hacerlo después obligaría a mover la sesión completa para tirar el 95 %.

Devuelve una lista de objetos, uno por vuelta:

```sh
curl 'localhost:8000/fastf1/laps/latest?driver=1' | head -c 220
```

```json
[{"leDriver":"NOR","leNumber":"1","leLap":1,"leTime":"1:31.211","leSector1":null,
  "leSector2":32.05,"leSector3":24.383,"leCompound":"MEDIUM","leTyreLife":1}]
```

- **Es el único de los tres sin DTO en `common`**, y el prefijo `le` es el que un futuro `LapEntry` usaría (2026-08-13). Hoy ningún `/api/*` lo consume: el DTO fija el contrato para quien decodifica, y el precedente es `/fastf1/drivers`, que esperó al widget.
- **Una vuelta sin tiempo se emite**, con `leTime` en `""`: las de entrada a boxes, de salida y las cortadas por bandera roja son vueltas reales, y filtrarlas sería decidir por el consumidor cuáles cuentan. Igual con los sectores ausentes (`null`) y el compuesto que FastF1 no publica (`""`, incluida la cadena `'None'` que escribe en esa columna). **Degradar es del backend.**
- **`leTime` y los sectores son coherentes**: sobre `latest`, `leTime == leSector1 + leSector2 + leSector3` en las 1407 vueltas que traen los tres, al milisegundo — y el `leTime` de la vuelta rápida de un coche coincide con el `ceLap` que publica `/fastf1/comparison`.
- **El orden es el de FastF1**: vueltas de cada coche contiguas y en orden de vuelta, coches en el orden de `driver` (o de la parrilla con `all`). No se reordena.
- Sin submuestreo: una vuelta es una fila, no una serie. Un coche que no está en la sesión devuelve `[]` con **200**; una sesión sin vueltas, `[]`. `driver` vacío → `400`.
