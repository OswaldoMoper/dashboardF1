"""telemetry-service — FastF1 detrás de una interfaz HTTP estable.

Microservicio que encapsula FastF1 para que el backend Haskell no tenga que
hablar Python ni pandas. Cuatro endpoints sobre datos archivados, más uno sobre
el feed en vivo:

* ``GET /fastf1/live`` — la tabla de live timing de la sesión **en marcha**, con
  las claves de ``Common.Types.LiveTimingRow``. No sale de FastF1 sino del feed
  que alimenta la web de la F1, y es la única fuente que responde durante una
  sesión: OpenF1 devuelve 401 en todo mientras hay una en directo. Ver
  ``_live_snapshot``.

Los cuatro de FastF1:

* ``GET /fastf1/telemetry/{session_key}/{driver}`` — arreglo JSON plano de
  muestras de telemetría, cada una **etiquetada con el acrónimo del piloto**
  (``tpDriver``), con exactamente las claves de
  ``Common.Types.TelemetryPoint``.
* ``GET /fastf1/comparison/{session_key}?drivers=16,1&samples=0`` — **un objeto**
  (no una lista) con las claves de ``Common.Types.LapComparison``: la vuelta
  rápida de **1 a 5** coches, en el orden pedido, con sus sectores y, si
  ``samples`` no es 0, sus fronteras y su traza.
* ``GET /fastf1/drivers/{session_key}`` — la **parrilla** de la sesión como
  lista de pares número↔acrónimo, con las claves de
  ``Common.Types.DriverEntry``. Es el único endpoint que **publica** la
  traducción que los otros dos aplican por dentro (``_driver_label``), y por
  eso es lo que permite a un consumidor que habla acrónimos construir un query
  que pide números.
* ``GET /fastf1/laps/{session_key}?driver=all`` — **todas las vueltas** de la
  sesión, una por objeto, con las claves prefijadas ``le``. Es el único de los
  cuatro **sin DTO en** ``common``: nada en Haskell lo decodifica todavía (ver
  el Haddock de ``laps``).

En los tres primeros las claves son las del DTO de Haskell, para que el decode
del backend sea directo; el cuarto usa el prefijo que su DTO usaría.

Contrato con el lado Haskell (decidido el 2026-07-31):

* **Las unidades las fija el DTO, y las normaliza este servicio.** FastF1
  publica ``Throttle`` en 0-100 y ``Brake`` como booleano; aquí salen como
  ``tpThrottle`` en 0.0-1.0 y ``tpBrake`` como ``0.0``/``1.0``, que es lo que
  el ``Double`` de Haskell espera.
* **Nunca ``NaN`` en el JSON.** ``json.dumps`` emite ``NaN`` y **aeson lo
  rechaza**, tumbando el arreglo completo. Aquí un no-numérico se convierte a
  ``null`` si el campo es prescindible, y descarta la muestra si es
  obligatorio (``tpDriver``/``tpSessionTime``/``tpDistance``/``tpSpeed``).
* **Degradar es trabajo del backend.** Una sesión sin telemetría devuelve
  ``[]`` (no un error): el ``Handler.Telemetry.Context`` es quien decide caer a
  su cache o al dummy. Vale igual para la parrilla vacía y para las vueltas —y
  por lo mismo, una vuelta sin tiempo **se emite** en vez de filtrarse.
* **El orden se preserva, no se impone.** Una vuelta es una serie, y la parrilla
  y las vueltas llegan en el orden que FastF1 les da (en una carrera cargada, el
  de clasificación). Ordenar para presentar es del consumidor; aquí reordenar
  solo destruiría información que el backend no puede reconstruir.

**Al arrancar carga la última carrera** antes de abrir el socket, y reintenta si
falla (``_lifespan``).

Variables de entorno: ``FASTF1_CACHE`` (default ``.fastf1-cache``) y
``TELEMETRY_MAX_POINTS`` (default ``60``, muestras por piloto). Desde el
2026-08-11 **no** afecta al delta de comparación: son cuatro fronteras de
sector y no una serie submuestreada (2026-08-11).
"""

from __future__ import annotations

import ctypes
import os
import sys
import threading
import time
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any, AsyncIterator, Dict, List, Optional, Tuple

import fastf1
from fastapi import FastAPI, HTTPException

from convert import _num, _text
from feed import _LIVE_TOPICS, _feed_rows, _feed_session

CACHE_DIR = os.environ.get("FASTF1_CACHE", ".fastf1-cache")
MAX_POINTS = max(1, int(os.environ.get("TELEMETRY_MAX_POINTS", "60")))

os.makedirs(CACHE_DIR, exist_ok=True)
fastf1.Cache.enable_cache(CACHE_DIR)


# ── Arranque ──────────────────────────────────────────────────────────────────

# Intentos de cargar `latest` antes de abrir el socket, y los que siguen en
# segundo plano si esos fallan (2026-09-24 (e)).
WARM_TRIES_BEFORE = 3
WARM_PAUSE_BEFORE = 10.0
WARM_TRIES_AFTER = 10
WARM_PAUSE_AFTER = 60.0


@asynccontextmanager
async def _lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Carga la última carrera antes de atender.

    **El socket no se abre hasta que la carga sale bien o fallan sus
    ``WARM_TRIES_BEFORE`` intentos** (~24 s sin red); en ese rato un ``TERM``
    tampoco se atiende. Si fallan, abre igual y sigue intentándolo en segundo
    plano (``_warm_later``). Un fallo nunca impide arrancar: ``/fastf1/live`` no
    depende de esta carga.
    """
    if _malloc_trim is None:
        _say("sin malloc_trim (no hay glibc): la memoria de cada carga no se devuelve")
    for attempt in range(1, WARM_TRIES_BEFORE + 1):
        if _warm(f"intento {attempt} de {WARM_TRIES_BEFORE}"):
            break
        if attempt < WARM_TRIES_BEFORE:
            time.sleep(WARM_PAUSE_BEFORE)
    else:
        _say(
            f"se abre sin la última carrera; se reintenta cada "
            f"{WARM_PAUSE_AFTER:.0f} s, hasta {WARM_TRIES_AFTER} veces"
        )
        threading.Thread(target=_warm_later, daemon=True).start()
    yield


def _warm_later() -> None:
    """Los reintentos en segundo plano. Uno en curso retiene ``_load_lock``, así
    que una petición de FastF1 que llegue entonces espera a que acabe."""
    for attempt in range(1, WARM_TRIES_AFTER + 1):
        time.sleep(WARM_PAUSE_AFTER)
        if _warm(f"reintento {attempt} de {WARM_TRIES_AFTER}"):
            return
    _say("se deja de reintentar; la primera petición que la necesite la cargará")


def _warm(attempt: str) -> bool:
    """Carga ``latest`` en el memo y lo dice en el log. ``True`` si quedó en
    memoria; un fallo se cuenta y no se propaga."""
    started = time.monotonic()
    try:
        session = _resolve_session("latest")
    except Exception as exc:
        _say(f"la última carrera no se pudo cargar ({attempt}): {_why(exc)}")
        return False
    key = f"{session.event.year}-{int(session.event['RoundNumber'])}-R"
    _say(f"última carrera en memoria ({key}, {time.monotonic() - started:.1f} s)")
    return True


def _why(exc: Exception) -> str:
    return str(getattr(exc, "detail", None) or exc)


def _say(line: str) -> None:
    print(line, file=sys.stderr, flush=True)


app = FastAPI(title="telemetry-service", version="0.1.0", lifespan=_lifespan)

# Sesiones ya cargadas, por `session_key`. Sin este memo cada petición vuelve a
# hacer `session.load()`, que descarga y parsea la sesión entera. `latest` y su
# clave `AÑO-RONDA-R` apuntan al mismo objeto: una sola copia, se pida como se
# pida. Consecuencia aceptada: `latest` se congela mientras el proceso viva —
# reiniciar `uvicorn` para volver a resolverlo.
_sessions: Dict[str, Any] = {}

# Todo lo que habla con FastF1 por red va bajo este cerrojo: su cache (SQLite)
# no admite dos hilos a la vez.
_load_lock = threading.Lock()


def _find_malloc_trim() -> Any:
    try:
        return ctypes.CDLL("libc.so.6").malloc_trim
    except (OSError, AttributeError):
        return None


# `malloc_trim` de glibc, o `None` si no la hay. Tras una carga el asignador se
# queda con memoria libre que Python ya no usa; esto se la devuelve al sistema.
_malloc_trim = _find_malloc_trim()


def _give_back() -> None:
    """Devuelve al sistema la memoria libre que retiene el asignador. Sin glibc no
    hace nada; el arranque lo avisa."""
    if _malloc_trim is not None:
        _malloc_trim(0)


# ── Resolución de la sesión ───────────────────────────────────────────────────


def _latest_race() -> Tuple[int, int]:
    """Año y ronda de la última carrera ya disputada.

    Recorre el calendario del año en curso de atrás hacia adelante y devuelve
    el primer evento cuya fecha de carrera (``Session5DateUtc``, en UTC) ya
    pasó; si el año no ha empezado, cae al anterior. Las fechas ausentes llegan
    como ``NaT``, que se detecta con ``date != date`` para no importar pandas.
    """
    now = datetime.utcnow()
    for year in (now.year, now.year - 1):
        try:
            schedule = fastf1.get_event_schedule(year, include_testing=False)
        except Exception:
            continue
        for _, event in schedule.iloc[::-1].iterrows():
            date = event.get("Session5DateUtc")
            if date is None or date != date:
                continue
            if date.to_pydatetime() <= now:
                return year, int(event["RoundNumber"])
    raise HTTPException(
        status_code=404,
        detail="no hay ninguna carrera disputada en el calendario disponible",
    )


def _resolve_session(session_key: str) -> Any:
    """Sesión de FastF1 cargada (con vueltas y telemetría).

    ``session_key`` es ``latest`` (última carrera disputada) o
    ``AÑO-RONDA-SESIÓN`` — con guiones, no barras, porque es **un solo segmento
    de path**: ``2026-13-R``, ``2026-13-Q``, ``2026-13-FP2``.

    Carga una sesión a la vez (``_load_lock``); una sesión ya en memoria no
    espera.
    """
    cached = _sessions.get(session_key)
    if cached is not None:
        return cached
    with _load_lock:
        cached = _sessions.get(session_key)
        if cached is None:
            key = _race_key(session_key)
            cached = _sessions.get(key)
            if cached is None:
                cached = _load_session(key)
                _sessions[key] = cached
                _give_back()
            _sessions[session_key] = cached
        return cached


def _race_key(session_key: str) -> str:
    """La clave del memo para ``session_key``: ``latest`` pasa a ``AÑO-RONDA-R`` y
    lo demás queda igual. Consulta el calendario, así que solo se llama con
    ``_load_lock``."""
    if session_key != "latest":
        return session_key
    year, rnd = _latest_race()
    return f"{year}-{rnd}-R"


def _load_session(session_key: str) -> Any:
    """Carga la sesión sin mirar el memo. Solo se llama con ``_load_lock``, y nunca
    con ``latest``: ``_race_key`` la traduce antes."""
    parts = session_key.split("-")
    if len(parts) != 3:
        raise HTTPException(
            status_code=400,
            detail=(
                "session_key debe ser 'latest' o 'AÑO-RONDA-SESIÓN' "
                "(p. ej. '2026-13-R')"
            ),
        )
    try:
        year, rnd = int(parts[0]), int(parts[1])
    except ValueError:
        raise HTTPException(
            status_code=400, detail="año y ronda deben ser numéricos"
        )
    identifier = parts[2]

    try:
        session = fastf1.get_session(year, rnd, identifier)
        session.load(laps=True, telemetry=True, weather=False, messages=False)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(
            status_code=404,
            detail=f"sesión no resoluble ({year}, {rnd}, {identifier}): {exc}",
        )

    return session


def _resolve_drivers(session: Any, spec: str) -> List[str]:
    """Números de coche a consultar: ``all`` o una lista ``1,4,16``.

    Una parte que no es número pasa por ``_car_number``: un acrónimo que la
    sesión reconoce sale como el número que lleva ese piloto (``NOR`` → ``1``), y
    cualquier otra cosa sigue tal cual.
    """
    if spec == "all":
        return [str(number) for number in session.drivers]
    numbers = [
        _car_number(session, part.strip()) for part in spec.split(",") if part.strip()
    ]
    if not numbers:
        raise HTTPException(
            status_code=400,
            detail="driver debe ser 'all' o una lista de números de coche (p. ej. '1,4')",
        )
    return numbers


def _car_number(session: Any, part: str) -> str:
    """Número de coche de ``part``: tal cual si ya son dígitos; el que lleva ese
    piloto si es un acrónimo que la sesión reconoce; tal cual si no.

    Es la traducción inversa de ``_driver_label``, y por eso quien pide con
    acrónimos recibe números en ``ceCar`` y ``leNumber``.
    """
    if part.isdigit():
        return part
    try:
        return str(session.get_driver(part)["DriverNumber"])
    except Exception:
        return part


def _driver_label(session: Any, number: str) -> str:
    """Acrónimo del piloto que va en ese coche, o el número si no se resuelve.

    Entra número de coche y sale acrónimo: es la traducción que **solo** este
    servicio sabe hacer, y la razón por la que los endpoints toman números
    (``_resolve_drivers``) y devuelven acrónimos.
    """
    try:
        return str(session.get_driver(number)["Abbreviation"])
    except Exception:
        return str(number)


# ── Saneado numérico ──────────────────────────────────────────────────────────


def _seconds(value: Any) -> Optional[float]:
    """Un ``Timedelta`` de FastF1 en segundos (o un número tal cual)."""
    if value is None or value != value:
        return None
    try:
        return _num(value.total_seconds())
    except AttributeError:
        return _num(value)


def _lap_time(value: Any) -> Optional[str]:
    """Un tiempo de vuelta de FastF1 como ``M:SS.mmm``, o ``None``.

    Formatear es trabajo de este servicio y no del ``Helper`` de Haskell
    (2026-07-31): ``ceLap`` es ``Text`` en
    el DTO, y un ``Timedelta`` de pandas pasado por ``str()`` daría
    ``0 days 00:01:29.345000``.
    """
    total = _seconds(value)
    if total is None or total < 0:
        return None
    minutes = int(total // 60)
    # `06.3f` da `09.345`, no `9.345`: los segundos van siempre a dos dígitos.
    return f"{minutes}:{total - minutes * 60:06.3f}"


def _interp(x: float, xs: List[float], ys: List[float]) -> Optional[float]:
    """``y`` en ``x`` por interpolación lineal sobre ``xs``, que debe crecer.

    Fuera del rango devuelve ``None`` — **no satura y no extrapola**: el valor
    del extremo saldría como si fuera una medida. Quien lo llama
    (``_lap_trace``, para las fronteras) deja la frontera vacía.

    A mano y no con ``numpy.interp`` a propósito: este módulo evita las
    dependencias científicas en la superficie (ver ``_latest_race``, que detecta
    ``NaT`` con ``date != date`` para no importar pandas). Además
    ``requirements.txt`` no está pineado, así que cada API de librería que se usa
    es superficie que puede cambiar sola.
    """
    if not xs or x < xs[0] or x > xs[-1]:
        return None
    if x == xs[0]:
        return ys[0]
    if x == xs[-1]:
        return ys[-1]
    lo, hi = 0, len(xs) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if xs[mid] <= x:
            lo = mid
        else:
            hi = mid
    span = xs[hi] - xs[lo]
    if span == 0:
        return ys[lo]
    return ys[lo] + (ys[hi] - ys[lo]) * (x - xs[lo]) / span


def _sample(label: str, row: Any) -> Optional[Dict[str, Any]]:
    """Una muestra de ``get_car_data()`` como objeto JSON, o ``None``.

    Los tres campos **obligatorios** (instante, punto de la vuelta y velocidad)
    descartan la muestra si faltan: sin ellos no se puede situar ni leer. Los
    cuatro canales de coche son **prescindibles** y salen como ``null``; el
    backend descarta esa muestra en ``assemblePoints`` en vez de inventar un
    frenazo o un punto muerto que FastF1 nunca midió.
    """
    session_time = _seconds(row.get("SessionTime"))
    distance = _num(row.get("Distance"))
    speed = _num(row.get("Speed"))
    if session_time is None or distance is None or speed is None:
        return None

    throttle = _num(row.get("Throttle"))
    brake = row.get("Brake")
    gear = _num(row.get("nGear"))
    rpm = _num(row.get("RPM"))

    return {
        "tpDriver": label,
        "tpSessionTime": session_time,
        "tpDistance": distance,
        "tpSpeed": speed,
        # FastF1 publica el acelerador en 0–100; el DTO lo quiere en 0.0–1.0.
        "tpThrottle": None if throttle is None else throttle / 100.0,
        # `Brake` es booleano en FastF1; el DTO lo quiere como Double.
        "tpBrake": None
        if brake is None or brake != brake
        else (1.0 if bool(brake) else 0.0),
        "tpGear": None if gear is None else int(gear),
        "tpRpm": None if rpm is None else int(rpm),
    }


# ── Telemetría por piloto ─────────────────────────────────────────────────────


def _driver_points(session: Any, number: str) -> List[Dict[str, Any]]:
    """Telemetría submuestreada de la **vuelta más rápida** de un piloto.

    La vuelta rápida es la única elección comparable entre coches. Un piloto sin
    vuelta válida (no salió, abandonó en la primera, sin telemetría publicada)
    se **omite en silencio**: la respuesta trae a los demás en vez de fallar
    entera.

    El submuestreo es obligatorio, no cosmético: una vuelta a 10 Hz son miles de
    muestras por piloto y el widget pinta una tabla.
    """
    try:
        lap = session.laps.pick_drivers([number]).pick_fastest()
    except Exception:
        return []
    if lap is None or getattr(lap, "empty", False):
        return []

    try:
        telemetry = lap.get_car_data().add_distance()
    except Exception:
        return []
    if len(telemetry) == 0:
        return []

    label = _driver_label(session, number)

    step = max(1, len(telemetry) // MAX_POINTS)
    points: List[Dict[str, Any]] = []
    for _, row in telemetry.iloc[::step].iterrows():
        sample = _sample(label, row)
        if sample is not None:
            points.append(sample)
    return points


@app.get("/fastf1/telemetry/{session_key}/{driver}")
def telemetry(session_key: str, driver: str) -> List[Dict[str, Any]]:
    """Telemetría de la vuelta rápida de uno, varios o todos los pilotos.

    El arreglo es **plano y etiquetado**: los puntos de cada piloto van
    contiguos y en orden de vuelta (una vuelta es una serie temporal;
    reordenarla la destruiría), y ``tpDriver`` dice de quién es cada uno.
    """
    session = _resolve_session(session_key)
    points: List[Dict[str, Any]] = []
    for number in _resolve_drivers(session, driver):
        points.extend(_driver_points(session, number))
    return points


# ── Comparación de vueltas ────────────────────────────────────────────────────

# Cuántos coches caben en una comparación.
COMPARISON_MAX_CARS = 5

# Las muestras por coche que acepta ``comparison``: 0 (sin trazas) o de 60 a 250
# de 5 en 5. El backend ya las ajusta (``Handler.Comparison.Helper.adjustSamples``);
# aquí se rechaza lo demás.
COMPARISON_SAMPLES = frozenset([0, *range(60, 251, 5)])

# Las partes de una clasificación, en el orden de ``split_qualifying_sessions``.
_QUALIFYING_PARTS = ("Q1", "Q2", "Q3")


def _fastest_lap(session: Any, number: str) -> Any:
    """La vuelta rápida de un coche, o ``None`` si no tiene (no salió, abandonó
    en la primera, la vuelta borrada)."""
    try:
        lap = session.laps.pick_drivers([number]).pick_fastest()
    except Exception:
        return None
    if lap is None or getattr(lap, "empty", False):
        return None
    return lap


def _lap_sectors(lap: Any) -> Optional[Tuple[str, List[float]]]:
    """``(tiempo de vuelta, [s1, s2, s3])`` de una vuelta.

    Los tres sectores los **publica** FastF1 con el resto de la vuelta; no se
    integran desde la telemetría, que es de donde salía todo el error del delta a lo
    largo de la vuelta (2026-08-10 y 2026-08-11).

    ``None`` si falta el ``LapTime`` **o cualquiera de los tres sectores**: una Δ
    con dos de tres no es una Δ más corta, es una mal sumada.
    """
    lap_time = _lap_time(lap["LapTime"])
    if lap_time is None:
        return None
    sectors: List[float] = []
    for column in ("Sector1Time", "Sector2Time", "Sector3Time"):
        try:
            value = _seconds(lap[column])
        except (KeyError, IndexError, TypeError):
            return None
        if value is None:
            return None
        sectors.append(value)
    return lap_time, sectors


def _lap_trace(
    lap: Any, sectors: List[float], samples: int
) -> Tuple[Optional[List[float]], List[Dict[str, float]]]:
    """``(fronteras, traza)`` de una vuelta: dónde cruzó S1 y S2, en metros, y
    ``samples`` muestras repartidas por posición, con la primera y la última.

    Las fronteras salen de la **vuelta completa**, no de las muestras: con 60
    muestras la frontera interpolada se iba hasta 8,5 m y se movería con el
    deslizable (2026-10-01). Son la distancia integrada por FastF1 en el instante
    en que acaba cada sector.

    ``interpolate_edges=True`` hace exactos los dos bordes: la primera muestra está
    en la línea (``Distance`` 0) y la última en el ``LapTime`` publicado.

    Una muestra con algún canal ausente se descarta, y el tiempo tiene que crecer
    estrictamente (lo pide ``_interp``). Sin telemetría, ``(None, [])``.
    """
    try:
        telemetry = lap.get_car_data(interpolate_edges=True).add_distance()
    except Exception:
        return None, []

    rows: List[Dict[str, float]] = []
    for _, row in telemetry.iterrows():
        elapsed = _seconds(row.get("Time"))
        distance = _num(row.get("Distance"))
        speed = _num(row.get("Speed"))
        throttle = _num(row.get("Throttle"))
        brake = row.get("Brake")
        if None in (elapsed, distance, speed, throttle) or brake is None or brake != brake:
            continue
        if rows and elapsed <= rows[-1]["ctTime"]:
            continue
        rows.append(
            {
                "ctTime": elapsed,
                "ctDistance": distance,
                "ctSpeed": speed,
                # FastF1 publica el acelerador en 0–100 y el freno como booleano.
                "ctThrottle": throttle / 100.0,
                "ctBrake": 1.0 if bool(brake) else 0.0,
            }
        )
    if len(rows) < 2:
        return None, []

    times = [r["ctTime"] for r in rows]
    distances = [r["ctDistance"] for r in rows]
    s1 = _interp(sectors[0], times, distances)
    s2 = _interp(sectors[0] + sectors[1], times, distances)
    frontiers = None if s1 is None or s2 is None else [s1, s2]

    if len(rows) <= samples:
        return frontiers, rows
    last = len(rows) - 1
    picked = sorted({round(k * last / (samples - 1)) for k in range(samples)})
    return frontiers, [rows[i] for i in picked]


def _qualifying_parts(session: Any) -> List[Any]:
    """Las vueltas de cada parte de una clasificación (Q1, Q2 y Q3), o ``[]`` si la
    sesión no es una clasificación o FastF1 no la sabe partir."""
    if "Qualifying" not in str(getattr(session, "name", "")) and "Shootout" not in str(
        getattr(session, "name", "")
    ):
        return []
    try:
        return list(session.laps.split_qualifying_sessions())
    except Exception:
        return []


def _part_of(parts: List[Any], lap: Any) -> Optional[str]:
    """En qué parte de la clasificación cae una vuelta, o ``None``. Medido en Bakú
    (2026-10-01): la mejor vuelta de cada piloto cae en exactamente una."""
    for name, laps in zip(_QUALIFYING_PARTS, parts):
        if laps is None or getattr(laps, "empty", True):
            continue
        same = (laps["DriverNumber"] == lap["DriverNumber"]) & (
            laps["LapNumber"] == lap["LapNumber"]
        )
        if bool(same.any()):
            return name
    return None


def _comparison_entry(
    session: Any, number: str, samples: int, parts: List[Any]
) -> Dict[str, Any]:
    """Un coche de la comparación. Sin vuelta comparable sale con ``ceSectors`` a
    ``null``, ``ceLap`` vacío y sin fronteras ni traza: decidir qué hacer con eso es
    del backend y de la página."""
    entry: Dict[str, Any] = {
        "ceCar": number,
        "ceDriver": _driver_label(session, number),
        "ceLap": "",
        "cePart": None,
        "ceSectors": None,
        "ceFrontiers": None,
        "ceTrace": [],
    }
    lap = _fastest_lap(session, number)
    if lap is None:
        return entry
    timed = _lap_sectors(lap)
    if timed is None:
        return entry
    lap_time, sectors = timed
    entry["ceLap"] = lap_time
    entry["ceSectors"] = sectors
    entry["cePart"] = _part_of(parts, lap)
    if samples > 0:
        entry["ceFrontiers"], entry["ceTrace"] = _lap_trace(lap, sectors, samples)
    return entry


@app.get("/fastf1/comparison/{session_key}")
def comparison(session_key: str, drivers: str, samples: int = 0) -> Dict[str, Any]:
    """La vuelta rápida de **1 a 5** coches, en el orden pedido: el primero es la
    referencia.

    Devuelve **un objeto**: ``lcSamples`` y ``lcEntries``, un coche por número
    pedido. La Δ no viaja: la calcula ``common`` desde ``ceSectors``
    (``Common.Comparison.deltasAgainst``), contra la referencia o contra el más
    rápido. Con ``samples`` > 0, cada coche lleva además dónde cruzó S1 y S2
    (``ceFrontiers``) y su traza (``ceTrace``); con 0 no se toca la telemetría.

    ``drivers`` fuera de 1 a 5 coches (``all`` incluido) o ``samples`` que no sea 0
    o de 60 a 250 de 5 en 5 son un **400**. Un coche sin vuelta **no** es un error:
    sale sin sectores (``_comparison_entry``).

    ``ceCar`` es el número de coche tal como entró, junto al acrónimo que sale. Es
    el viaje de vuelta: el consumidor habla acrónimos y el query pide números, y
    solo este servicio conoce la traducción (``_driver_label``, 2026-08-05).
    """
    session = _resolve_session(session_key)
    numbers = _resolve_drivers(session, drivers)
    if not 1 <= len(numbers) <= COMPARISON_MAX_CARS:
        raise HTTPException(
            status_code=400,
            detail=(
                "drivers debe ser de 1 a 5 números de coche (p. ej. '16,1'); "
                "el primero es la referencia"
            ),
        )
    if samples not in COMPARISON_SAMPLES:
        raise HTTPException(
            status_code=400,
            detail="samples debe ser 0 o de 60 a 250 de 5 en 5",
        )
    parts = _qualifying_parts(session)
    return {
        "lcSamples": samples,
        "lcEntries": [_comparison_entry(session, n, samples, parts) for n in numbers],
    }


# ── Parrilla ──────────────────────────────────────────────────────────────────


def _team_name(session: Any, number: str) -> str:
    """Equipo del coche, o ``""`` si FastF1 no lo publica en esta sesión.

    Espejo de ``_driver_label`` y con el mismo criterio de fallo blando: el
    equipo es **decoración** de la parrilla (agrupar, colorear), no identidad,
    así que su ausencia no puede costar la entrada entera. Lo que sí cambia
    respecto del acrónimo es el fallback: allí devolver el número es informativo
    ("este coche existe"), aquí no hay nada informativo que inventar.
    """
    try:
        return str(session.get_driver(number)["TeamName"])
    except Exception:
        return ""


@app.get("/fastf1/drivers/{session_key}")
def drivers(session_key: str) -> List[Dict[str, Any]]:
    """Parrilla de la sesión: un objeto por coche, con número, acrónimo y equipo.

    Es la respuesta a un desajuste de vocabularios, no una comodidad: la API
    habla **números de coche** y los widgets **acrónimos**, y la traducción la
    conoce solo este servicio (2026-08-01 y 2026-08-05).
    Los otros dos endpoints la aplican por dentro y devuelven el acrónimo ya
    resuelto; éste la **publica**, que es lo que permite al consumidor pedir
    datos de un coche que todavía no ha visto.

    **La parrilla es la de la sesión, no la del campeonato.** Un piloto
    sustituto o un tercer coche en libres la cambian, y por eso el backend
    cachea por ``session_key``.

    **Un coche cuyo acrónimo no resuelve sale igual**, con ``deCode`` repetido
    del número (es el fallback de ``_driver_label``): produce pares como
    ``("44", "44")``, que el consumidor presentará como un piloto llamado
    ``44``. Se deja pasar a propósito — el coche está en la sesión aunque no
    sepamos quién lo lleva, y esconderlo daría una parrilla incompleta sin
    decirlo. El equipo ausente, en cambio, sale como ``""``
    (ver ``_team_name``).

    Una sesión sin parrilla devuelve ``[]``, **no un error**: degradar es
    trabajo del backend (2026-07-31).
    """
    session = _resolve_session(session_key)
    try:
        numbers = list(session.drivers)
    except Exception:
        return []

    # `session.drivers` ya son cadenas en FastF1 3.8, pero `requirements.txt` no
    # está pineado y el `str()` de `_resolve_drivers` existe por lo mismo: es la
    # clave del par que el consumidor va a mandar de vuelta en el query.
    return [
        {
            "deNumber": str(number),
            "deCode": _driver_label(session, str(number)),
            "deTeam": _team_name(session, str(number)),
        }
        for number in numbers
    ]


# ── Vueltas ───────────────────────────────────────────────────────────────────


def _lap_entry(label: str, number: str, row: Any) -> Dict[str, Any]:
    """Una fila de ``session.laps`` como objeto JSON.

    Composición de lo que ya está —``_lap_time``, ``_seconds``, ``_num``— y por
    eso no repite el saneado: ningún valor sale ``NaN`` (aeson lo rechazaría),
    los tiempos van formateados por el servicio y no por el consumidor, y los
    sectores van en segundos como ``ceSectors``.

    **Siempre devuelve un objeto**, nunca ``None``: a diferencia de ``_sample``,
    aquí no hay campo cuya ausencia impida situar la fila. Una vuelta sin
    ``LapTime`` sale con ``leTime`` en ``""`` (ver ``laps``).
    """
    lap_number = _num(row.get("LapNumber"))
    tyre_life = _num(row.get("TyreLife"))

    return {
        "leDriver": label,
        # El número tal como entró, junto al acrónimo que sale: es el mismo
        # viaje de vuelta que `ceCar`
        # (2026-08-05), lo que permite pedir otra vuelta de este coche.
        "leNumber": number,
        "leLap": None if lap_number is None else int(lap_number),
        "leTime": _lap_time(row.get("LapTime")) or "",
        "leSector1": _seconds(row.get("Sector1Time")),
        "leSector2": _seconds(row.get("Sector2Time")),
        "leSector3": _seconds(row.get("Sector3Time")),
        "leCompound": _text(row.get("Compound")),
        "leTyreLife": None if tyre_life is None else int(tyre_life),
    }


@app.get("/fastf1/laps/{session_key}")
def laps(session_key: str, driver: str = "all") -> List[Dict[str, Any]]:
    """Todas las vueltas de la sesión, una por objeto.

    Es el primer endpoint que devuelve la **sesión entera** y no una vuelta: ~20
    coches por ~60 vueltas son ~1200 objetos. De ahí que ``driver`` exista —``all``
    (default) o una lista de números de coche, el mismo vocabulario que
    ``/fastf1/telemetry``—: filtrar en el servicio es barato y hacerlo después
    obligaría a mover la sesión entera por la red para tirar el 95 %. Lo que **no**
    hay es submuestreo: una vuelta es una fila, no una serie, así que
    ``TELEMETRY_MAX_POINTS`` no aplica.

    **Las claves llevan el prefijo ``le`` y no hay DTO en** ``common``.
    ``leDriver``/``leNumber`` (acrónimo y número de coche), ``leLap`` (número de
    vuelta), ``leTime`` (``M:SS.mmm``), ``leSector1``/``2``/``3`` (segundos) y
    ``leCompound``/``leTyreLife`` (compuesto y vueltas hechas con él). El prefijo
    es el que usaría un ``LapEntry``, para que escribirlo el día que haga falta no
    obligue a renombrar nada. Que no exista todavía es deliberado: el DTO fija un
    contrato para **quien decodifica**, y hoy ningún ``/api/*`` consume esto — el
    precedente es ``/fastf1/drivers``, que esperó a que el widget tuviera que
    elegir (2026-08-05 y 2026-08-13).

    **Una vuelta sin ``LapTime`` se emite, con ``leTime`` en ``""``.** Las vueltas
    de entrada a boxes, de salida y las cortadas por bandera roja existen y están
    en ``session.laps``; filtrarlas aquí sería decidir por el consumidor qué
    vueltas cuentan, y **degradar es trabajo del backend**
    (2026-07-31). Lo mismo con los sectores ausentes (``null``) y el compuesto que
    FastF1 no publica en esa sesión (``""``). El criterio de fallo lo elige quien
    lee: ``leTime == ""`` es «esta vuelta no tiene tiempo», no «esta respuesta
    falló».

    **El orden es el de FastF1, agrupado por coche**: las vueltas de cada coche van
    contiguas y en orden de vuelta, y los coches en el orden en que llegan en
    ``driver`` (o el de la parrilla con ``all``). No se reordena.

    Una sesión sin vueltas devuelve ``[]``, **no un error**, igual que los otros
    tres.
    """
    session = _resolve_session(session_key)
    entries: List[Dict[str, Any]] = []
    for number in _resolve_drivers(session, driver):
        try:
            picked = session.laps.pick_drivers([number])
        except Exception:
            continue
        label = _driver_label(session, number)
        for _, row in picked.iterrows():
            entries.append(_lap_entry(label, number, row))
    return entries


# --- Feed de timing en vivo ---------------------------------------------------
#
# Lo de arriba sale de FastF1 sobre datos ya archivados. Esto sale del feed que
# alimenta la web de la F1, y es la única fuente que responde **durante** una
# sesión: OpenF1 devuelve 401 en todos sus endpoints mientras hay una en marcha
# —«including past sessions»— y abrirlo es de pago.

_LIVE_FEED_URL = "wss://livetiming.formula1.com/signalrcore"
_LIVE_NEGOTIATE_URL = "https://livetiming.formula1.com/signalrcore/negotiate"


def _live_snapshot(timeout: float = 15.0) -> Dict[str, Any]:
    """El estado completo de la sesión en marcha, de un solo tiro.

    **No acumula estado, y por eso cabe en una petición.** El feed manda deltas
    —un mensaje es un coche, un sector, un segmento—, pero la respuesta a
    ``Subscribe`` es un ``CompletionMessage`` cuyo ``result`` trae **cada topic
    completo**. Se captura ése y se corta la conexión.

    La contrapartida, y hay que tenerla presente antes de confiar en esto: cada
    llamada abre y cierra una conexión, así que refrescar cada diez segundos son
    seis conexiones por minuto. Sostener una conexión viva y acumular los deltas
    es otra forma, más barata en red y más cara en diseño, y se decide con una
    sesión entera grabada delante.

    La conexión es **anónima**: ``access_token_factory`` devuelve la cadena
    vacía. ``signalrcore`` rechaza el ``None`` que ``no_auth=True`` de FastF1 le
    pasa, así que se le da una función que devuelve el token vacío, que es lo
    que el modo anónimo quiere mandar.
    """
    # Importados aquí y no arriba para que el microservicio arranque igual si el
    # cliente de SignalR falta: los cuatro endpoints de FastF1 no lo necesitan.
    import threading

    import requests
    from signalrcore.hub_connection_builder import HubConnectionBuilder
    from signalrcore.messages.completion_message import CompletionMessage

    # Pre-negociación: el feed exige la cookie que devuelve este OPTIONS.
    negotiated = requests.options(_LIVE_NEGOTIATE_URL, timeout=timeout)
    headers = {"Cookie": f"AWSALBCORS={negotiated.cookies['AWSALBCORS']}"}

    connection = (
        HubConnectionBuilder()
        .with_url(
            _LIVE_FEED_URL,
            options={
                "verify_ssl": True,
                "access_token_factory": lambda: "",
                "headers": headers,
            },
        )
        .build()
    )

    opened = threading.Event()
    captured: Dict[str, Any] = {}
    arrived = threading.Event()

    def _on_subscribed(msg: Any) -> None:
        if isinstance(msg, CompletionMessage) and isinstance(msg.result, dict):
            captured.update(msg.result)
            arrived.set()

    connection.on_open(opened.set)
    # Un manejador vacío para los deltas: llegan de todas formas mientras la
    # conexión vive, y sin él el cliente los trata como mensaje sin destino.
    connection.on("feed", lambda _msg: None)

    connection.start()
    try:
        if not opened.wait(timeout):
            raise TimeoutError("el feed no aceptó la conexión")
        connection.send("Subscribe", [_LIVE_TOPICS], on_invocation=_on_subscribed)
        if not arrived.wait(timeout):
            raise TimeoutError("el feed aceptó la conexión pero no mandó el estado")
    finally:
        connection.stop()

    return captured


@app.get("/fastf1/live")
def live() -> Dict[str, Any]:
    """La sesión en marcha y su tabla de live timing, desde el feed oficial.

    Devuelve ``{"session": …, "rows": [ … ]}``. **La tabla vacía es la señal de
    que no hay sesión en directo**, por el mismo criterio que los otros cuatro
    endpoints: degradar es trabajo del backend, así que aquí una sesión sin
    datos no es un error. ``session`` puede ser ``null`` aunque haya filas, y al
    revés.

    Las dos mitades salen de la **misma** foto, así que hablan del mismo
    instante: pedirlas por separado daría dos que pueden discrepar.

    Solo se traduce a ``503`` el fallo del propio feed —conexión rechazada o
    estado que no llega—, que es lo que ``Handler.Live.Context`` necesita
    distinguir para caer a su cache.
    """
    try:
        snapshot = _live_snapshot()
    except Exception as error:
        raise HTTPException(status_code=503, detail=f"feed no disponible: {error}")
    return {"session": _feed_session(snapshot), "rows": _feed_rows(snapshot)}
