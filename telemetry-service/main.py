"""telemetry-service — FastF1 detrás de una interfaz HTTP estable.

Microservicio que encapsula FastF1 para que el backend Haskell no tenga que
hablar Python ni pandas. Fase 4, tres endpoints:

* ``GET /fastf1/telemetry/{session_key}/{driver}`` — arreglo JSON plano de
  muestras de telemetría, cada una **etiquetada con el acrónimo del piloto**
  (``tpDriver``), con exactamente las claves de
  ``Common.Types.TelemetryPoint``.
* ``GET /fastf1/comparison/{session_key}?drivers=1,16`` — **un objeto** (no una
  lista) con las siete claves de ``Common.Types.LapComparison``, comparando la
  vuelta rápida de exactamente **dos** coches.
* ``GET /fastf1/drivers/{session_key}`` — la **parrilla** de la sesión como
  lista de pares número↔acrónimo, con las claves de
  ``Common.Types.DriverEntry``. Es el único endpoint que **publica** la
  traducción que los otros dos aplican por dentro (``_driver_label``), y por
  eso es lo que permite a un consumidor que habla acrónimos construir un query
  que pide números.

En los dos casos las claves son las del DTO de Haskell, para que el decode del
backend sea directo.

Contrato con el lado Haskell (ver 2026-07-31):

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
  su cache o al dummy. Vale igual para la parrilla vacía.
* **El orden se preserva, no se impone.** Una vuelta es una serie y la parrilla
  llega en el orden que FastF1 le da (en una carrera cargada, el de
  clasificación). Ordenar para presentar es del consumidor; aquí reordenar solo
  destruiría información que el backend no puede reconstruir.

Endpoint del contrato **todavía no implementado**
(``docs/ARCHITECTURE.md §2.3``): ``GET /fastf1/laps/{session_key}``.

Variables de entorno: ``FASTF1_CACHE`` (default ``.fastf1-cache``) y
``TELEMETRY_MAX_POINTS`` (default ``60``, muestras por piloto y puntos del
delta de comparación).
"""

from __future__ import annotations

import math
import os
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import fastf1
from fastapi import FastAPI, HTTPException

CACHE_DIR = os.environ.get("FASTF1_CACHE", ".fastf1-cache")
MAX_POINTS = max(1, int(os.environ.get("TELEMETRY_MAX_POINTS", "60")))

os.makedirs(CACHE_DIR, exist_ok=True)
fastf1.Cache.enable_cache(CACHE_DIR)

app = FastAPI(title="telemetry-service", version="0.1.0")

# Sesiones ya cargadas, por `session_key`. Sin este memo cada petición vuelve a
# hacer `session.load()`, que descarga y parsea la sesión entera. Consecuencia
# aceptada: `latest` se congela mientras el proceso viva — reiniciar `uvicorn`
# para volver a resolverlo.
_sessions: Dict[str, Any] = {}


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
    """
    cached = _sessions.get(session_key)
    if cached is not None:
        return cached

    if session_key == "latest":
        year, rnd = _latest_race()
        identifier: Any = "R"
    else:
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

    _sessions[session_key] = session
    return session


def _resolve_drivers(session: Any, spec: str) -> List[str]:
    """Números de coche a consultar: ``all`` o una lista ``1,4,16``."""
    if spec == "all":
        return [str(number) for number in session.drivers]
    numbers = [part.strip() for part in spec.split(",") if part.strip()]
    if not numbers:
        raise HTTPException(
            status_code=400,
            detail="driver debe ser 'all' o una lista de números de coche (p. ej. '1,4')",
        )
    return numbers


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


def _num(value: Any) -> Optional[float]:
    """Valor como ``float`` finito, o ``None``.

    Absorbe ``NaN``, ``inf``, ``NaT``, ``None`` y cualquier cosa no convertible
    en un único punto: es lo que garantiza que el JSON emitido sea decodificable
    por aeson.
    """
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    if math.isnan(out) or math.isinf(out):
        return None
    return out


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
    (2026-07-31): ``lcLapA``\\ /``lcLapB`` son ``Text`` en
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

    Fuera del rango **satura** en el extremo en vez de extrapolar: las dos
    vueltas no cubren exactamente la misma distancia, y extrapolar inventaría
    tiempo donde no hay traza.

    A mano y no con ``numpy.interp`` a propósito: este módulo evita las
    dependencias científicas en la superficie (ver ``_latest_race``, que detecta
    ``NaT`` con ``date != date`` para no importar pandas), y con ≤60 puntos la
    bisección es gratis. Además ``requirements.txt`` no está pineado, así que
    cada API de librería que se usa es superficie que puede cambiar sola.
    """
    if not xs:
        return None
    if x <= xs[0]:
        return ys[0]
    if x >= xs[-1]:
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


def _lap_trace(
    session: Any, number: str
) -> Optional[Tuple[str, str, List[float], List[float]]]:
    """``(acrónimo, tiempo de vuelta, distancias, tiempos)`` de la vuelta rápida.

    Espejo estructural de ``_driver_points``, pero devuelve la vuelta como **dos
    series paralelas** en vez de muestras: es la forma que necesita ``_interp``
    para leer el tiempo de un coche a la distancia del otro.

    ``None`` si el coche no tiene vuelta comparable (no salió, sin telemetría,
    ``LapTime`` ausente, o menos de dos puntos útiles). Quien decide qué hacer
    con eso es el endpoint, no esta función.
    """
    try:
        lap = session.laps.pick_drivers([number]).pick_fastest()
    except Exception:
        return None
    if lap is None or getattr(lap, "empty", False):
        return None

    lap_time = _lap_time(lap["LapTime"])
    if lap_time is None:
        return None

    try:
        telemetry = lap.get_car_data().add_distance()
    except Exception:
        return None

    distances: List[float] = []
    times: List[float] = []
    for _, row in telemetry.iterrows():
        distance = _num(row.get("Distance"))
        elapsed = _seconds(row.get("Time"))
        if distance is None or elapsed is None:
            continue
        # `Distance` tiene que ser estrictamente creciente: `_interp` busca por
        # bisección y un retroceso (ruido de GPS, muestra repetida) rompería el
        # invariante en silencio.
        if distances and distance <= distances[-1]:
            continue
        distances.append(distance)
        times.append(elapsed)

    if len(distances) < 2:
        return None
    return _driver_label(session, number), lap_time, distances, times


@app.get("/fastf1/comparison/{session_key}")
def comparison(session_key: str, drivers: str) -> Dict[str, Any]:
    """Comparación de la vuelta rápida de **exactamente dos** coches.

    Devuelve **un objeto**, no una lista: ``LapComparison`` tiene A y B, así que
    ``?drivers=1`` o ``?drivers=1,4,16`` (y ``all``) son un **400**, no una
    respuesta parcial.

    ``lcDelta`` es el delta acumulado **A−B** sobre la rejilla de distancias de
    A: en cada punto, el tiempo que A llevaba menos el que B llevaba a esa misma
    distancia. Positivo = A va por detrás. Submuestreado con el mismo
    ``TELEMETRY_MAX_POINTS`` que la telemetría, y saneado con ``_num``, porque un
    solo ``NaN`` tumba el decode del objeto **completo** en aeson.

    Una sesión sin vueltas comparables devuelve ``lcDelta: []`` y los tiempos en
    ``""``, **no un error**: degradar es trabajo del backend
    (2026-07-31), y las siete claves están siempre.

    ``lcCarA``/``lcCarB`` son los **números de coche** tal como entraron, junto a
    los acrónimos que salen. Es el viaje de vuelta: el consumidor habla acrónimos
    y el query pide números, y solo este servicio conoce la traducción
    (``_driver_label``), así que devolver el número es lo que permite al widget
    pedir **otra** comparación (2026-08-05).
    """
    session = _resolve_session(session_key)
    numbers = _resolve_drivers(session, drivers)
    if len(numbers) != 2:
        raise HTTPException(
            status_code=400,
            detail=(
                "drivers debe ser exactamente dos números de coche "
                "(p. ej. '1,16'); la comparación es de A contra B"
            ),
        )

    trace_a = _lap_trace(session, numbers[0])
    trace_b = _lap_trace(session, numbers[1])
    if trace_a is None or trace_b is None:
        return {
            "lcDriverA": _driver_label(session, numbers[0]),
            "lcDriverB": _driver_label(session, numbers[1]),
            "lcCarA": numbers[0],
            "lcCarB": numbers[1],
            "lcLapA": "",
            "lcLapB": "",
            "lcDelta": [],
        }

    label_a, lap_a, distances_a, times_a = trace_a
    label_b, lap_b, distances_b, times_b = trace_b

    step = max(1, len(distances_a) // MAX_POINTS)
    delta: List[float] = []
    for index in range(0, len(distances_a), step):
        reference = _interp(distances_a[index], distances_b, times_b)
        if reference is None:
            continue
        value = _num(times_a[index] - reference)
        if value is not None:
            delta.append(value)

    return {
        "lcDriverA": label_a,
        "lcDriverB": label_b,
        "lcCarA": numbers[0],
        "lcCarB": numbers[1],
        "lcLapA": lap_a,
        "lcLapB": lap_b,
        "lcDelta": delta,
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
