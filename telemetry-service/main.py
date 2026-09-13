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
* ``GET /fastf1/comparison/{session_key}?drivers=1,16`` — **un objeto** (no una
  lista) con las siete claves de ``Common.Types.LapComparison``, comparando la
  vuelta rápida de exactamente **dos** coches.
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

Variables de entorno: ``FASTF1_CACHE`` (default ``.fastf1-cache``) y
``TELEMETRY_MAX_POINTS`` (default ``60``, muestras por piloto). Desde el
2026-08-11 **no** afecta al delta de comparación: son cuatro fronteras de
sector y no una serie submuestreada (2026-08-11).
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

    **Sin uso desde el 2026-08-11**: el delta lo construye ``_lap_sectors`` y no
    hay eje que interpolar. Se conserva —con ``_lap_trace``, su único llamador—
    para la rama que publique los sectores en el DTO
    (2026-08-11). Lo que sigue describe el mecanismo tal como quedó.

    Fuera del rango devuelve ``None`` — **no satura y no extrapola**. Saturar
    era peor que no contestar: devolvía el valor del extremo como si fuera una
    medida, así que un delta mal alineado salía **correcto justo en los dos
    puntos que se miran primero** y el fallo quedaba plausible en vez de
    visible. Quien recibe ``None`` (el bucle de ``comparison``) deja el punto
    fuera del delta, que es lo honesto: de ese tramo de pista no hay traza del
    otro coche.

    A mano y no con ``numpy.interp`` a propósito: este módulo evita las
    dependencias científicas en la superficie (ver ``_latest_race``, que detecta
    ``NaT`` con ``date != date`` para no importar pandas), y con ≤60 puntos la
    bisección es gratis. Además ``requirements.txt`` no está pineado, así que
    cada API de librería que se usa es superficie que puede cambiar sola.
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


def _lap_trace(
    session: Any, number: str
) -> Optional[Tuple[str, str, List[float], List[float]]]:
    """``(acrónimo, tiempo de vuelta, fracciones de vuelta, tiempos)`` de la rápida.

    **Sin uso desde el 2026-08-11**: ``comparison`` construye el delta con
    ``_lap_sectors``, que no necesita telemetría. Se conserva para la rama que
    publique los sectores en el DTO (2026-08-11); lo que
    sigue describe el eje por fracción de vuelta tal como quedó medido, que es la
    razón por la que se guarda y no se borra.

    Espejo estructural de ``_driver_points``, pero devuelve la vuelta como **dos
    series paralelas** en vez de muestras: es la forma que necesita ``_interp``
    para leer el tiempo de un coche al mismo punto de pista que el otro.

    **El eje es la fracción de vuelta en ``[0, 1]``, no el metro**, y eso es
    correctitud y no comodidad (2026-08-10). ``Distance``
    no lo mide FastF1: lo **integra** ``add_distance()`` a partir de ``Speed``
    muestreada de forma irregular, así que el metro que sale es una estimación
    con error acumulado. Medido en Hungría 2026 con ``fastf1`` 3.8.3, la misma
    vuelta del mismo circuito (~4381 m reales) da **4721 m** para un coche y
    **4089 m** para el otro: los dos ejes están mal en absoluto y, lo que
    arruina la comparación, están mal **en distinta escala**. Dividir cada serie
    por su propio total no normaliza a ciegas — descarta la única parte del
    número que es falsa y conserva la que no lo es, la posición relativa a lo
    largo de la vuelta.

    **``interpolate_edges=True`` es lo que hace exactos los dos bordes.** Sin
    él, la primera muestra cae ya pasada la línea y ``Distance[0]`` arranca en el
    rectángulo ``Speed[0]/3.6 · Time[0]`` que FastF1 usa para estimar el tramo
    que no midió (3.7 m y 7.8 m en la medición de arriba, despreciable aquí pero
    no si hay un hueco de telemetría). Con él, ``Distance[0]`` es ``0.0``,
    ``Time`` recorre la vuelta entera y ``times[-1]`` coincide con el ``LapTime``
    publicado — que es lo que convierte el último punto del delta en una
    comprobación y no en una casualidad.

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
        telemetry = lap.get_car_data(interpolate_edges=True).add_distance()
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
        # invariante en silencio. En la medición del 2026-08-10 no descartó
        # ninguna muestra en ninguno de los dos coches, así que es un seguro, no
        # el filtro que estaba deformando el delta.
        if distances and distance <= distances[-1]:
            continue
        distances.append(distance)
        times.append(elapsed)

    if len(distances) < 2:
        return None

    # A fracción de vuelta. El total es positivo: la serie es estrictamente
    # creciente y arranca en 0.0 (`interpolate_edges=True`), así que el último
    # elemento es mayor que el primero.
    total = distances[-1]
    if total <= 0:
        return None
    fractions = [distance / total for distance in distances]

    return _driver_label(session, number), lap_time, fractions, times


def _lap_sectors(
    session: Any, number: str
) -> Optional[Tuple[str, str, List[float]]]:
    """``(acrónimo, tiempo de vuelta, [s1, s2, s3])`` de la vuelta rápida.

    Es lo que sustituye a ``_lap_trace`` como fuente del delta desde el
    2026-08-11, y la diferencia que importa es que **no
    toca telemetría**: los tres sectores los **publica** FastF1 con el resto de
    la vuelta, mientras que el eje de distancia había que integrarlo a partir de
    ``Speed`` — que es de donde salía todo el error. De paso, la comparación deja
    de descargar y recorrer dos vueltas de canales de coche.

    ``None`` si el coche no tiene vuelta comparable (no salió, ``LapTime``
    ausente) **o si le falta cualquiera de los tres sectores**: un delta con dos
    de tres no es un delta acumulado más corto, es uno mal sumado. Quien decide
    qué hacer con ese ``None`` es el endpoint, no esta función.
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

    sectors: List[float] = []
    for column in ("Sector1Time", "Sector2Time", "Sector3Time"):
        try:
            value = _seconds(lap[column])
        except (KeyError, IndexError, TypeError):
            return None
        if value is None:
            return None
        sectors.append(value)

    return _driver_label(session, number), lap_time, sectors


@app.get("/fastf1/comparison/{session_key}")
def comparison(session_key: str, drivers: str) -> Dict[str, Any]:
    """Comparación de la vuelta rápida de **exactamente dos** coches.

    Devuelve **un objeto**, no una lista: ``LapComparison`` tiene A y B, así que
    ``?drivers=1`` o ``?drivers=1,4,16`` (y ``all``) son un **400**, no una
    respuesta parcial.

    ``lcDelta`` son **cuatro valores en las cuatro fronteras de sector** —línea
    de meta, fin de S1, fin de S2, fin de vuelta—: el tiempo acumulado de A menos
    el de B en cada una. Positivo = A va por detrás. Saneado con ``_num``, porque
    un solo ``NaN`` tumba el decode del objeto **completo** en aeson.

    **Son sectores y no una curva de vuelta a propósito**
    (2026-08-11). Un delta por distancia exige un eje que diga "el mismo punto de
    la pista" en los dos coches, y FastF1 no publica ninguno: se midieron cinco
    —el metro integrado, la fracción de vuelta, el trapecio, la telemetría
    fusionada y el camino GPS— y **ninguno** deja el delta dentro de lo
    físicamente posible, porque el canal ``Speed`` del que todos derivan trae un
    sesgo de +8 % en un coche y −6.5 % en el otro (ver 2026-08-10). Los tiempos
    de sector, en cambio, FastF1 los **publica** en vez de integrarlos.

    Los cuatro valores son **exactos**, y con ellos los dos invariantes que antes
    solo se cumplían en las puntas: el primero es ``0.0`` (los dos coches en la
    línea) y el último es ``lcLapA - lcLapB`` — ya no "del orden de", sino la
    misma diferencia al milisegundo, porque los tres sectores suman el
    ``LapTime``. Para el par medido el 2026-08-10 en Hungría:
    ``[0.0, +0.051, +0.484, +0.491]``.

    El precio, dicho aquí porque el consumidor lo va a ver: **son cuatro puntos y
    no sesenta**, así que el gráfico es una línea quebrada de tres tramos y no
    una curva. Dentro de un sector no se dice nada, que es exactamente lo que se
    sabe.

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

    lap_a_data = _lap_sectors(session, numbers[0])
    lap_b_data = _lap_sectors(session, numbers[1])
    if lap_a_data is None or lap_b_data is None:
        return {
            "lcDriverA": _driver_label(session, numbers[0]),
            "lcDriverB": _driver_label(session, numbers[1]),
            "lcCarA": numbers[0],
            "lcCarB": numbers[1],
            "lcLapA": "",
            "lcLapB": "",
            "lcDelta": [],
        }

    label_a, lap_a, sectors_a = lap_a_data
    label_b, lap_b, sectors_b = lap_b_data

    # El `0.0` de la línea de meta no sale de ningún sector: es la frontera
    # cero, donde los dos coches están empatados por definición. Va delante para
    # que el delta tenga las **cuatro** fronteras y no solo los tres finales, y
    # es lo que hace que el gráfico arranque en la línea del cero en vez de en el
    # primer parcial.
    delta: List[float] = [0.0]
    accumulated_a, accumulated_b = 0.0, 0.0
    for sector_a, sector_b in zip(sectors_a, sectors_b):
        accumulated_a += sector_a
        accumulated_b += sector_b
        value = _num(accumulated_a - accumulated_b)
        # Un `None` aquí no puede recortar la serie como hacía `_interp`: los
        # cuatro valores son fronteras y saltarse una desplazaría las de detrás.
        # `_lap_sectors` ya garantiza tres sectores finitos, así que esto es un
        # seguro contra el desbordamiento de la suma, no un camino esperado.
        if value is None:
            delta = []
            break
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


# ── Vueltas ───────────────────────────────────────────────────────────────────


def _text(value: Any) -> str:
    """Un campo de texto de FastF1 como ``str``, o ``""`` si no hay dato.

    Tres formas del hueco, y las tres tienen que salir vacías porque las tres
    salvo la última **parecen un dato** una vez pasadas por ``str()``:

    * ``None`` y ``NaN`` — una columna de objetos de pandas usa el segundo donde
      falta el valor, y ``str()`` daría ``"nan"``.
    * la **cadena** ``"None"``, que es la que de verdad aparece: FastF1 rellena
      así ``Compound`` cuando no conoce el neumático (25 de 1431 vueltas en
      Hungría 2026, exactamente las mismas que traen ``TyreLife`` ausente — dos
      señales independientes del mismo hueco). Es ``str(None)`` escrito en la
      columna, no un compuesto llamado *None*.

    Mismo criterio blando que ``_team_name``: el compuesto es información sobre
    la vuelta, no su identidad, así que su ausencia no cuesta la entrada entera.
    """
    if value is None or value != value:
        return ""
    text = str(value)
    return "" if text == "None" else text


def _lap_entry(label: str, number: str, row: Any) -> Dict[str, Any]:
    """Una fila de ``session.laps`` como objeto JSON.

    Composición de lo que ya está —``_lap_time``, ``_seconds``, ``_num``— y por
    eso no repite el saneado: ningún valor sale ``NaN`` (aeson lo rechazaría),
    los tiempos van formateados por el servicio y no por el consumidor, y los
    sectores van en segundos como ``lcDelta``.

    **Siempre devuelve un objeto**, nunca ``None``: a diferencia de ``_sample``,
    aquí no hay campo cuya ausencia impida situar la fila. Una vuelta sin
    ``LapTime`` sale con ``leTime`` en ``""`` (ver ``laps``).
    """
    lap_number = _num(row.get("LapNumber"))
    tyre_life = _num(row.get("TyreLife"))

    return {
        "leDriver": label,
        # El número tal como entró, junto al acrónimo que sale: es el mismo
        # viaje de vuelta que `lcCarA`/`lcCarB`
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

# Solo los tres topics que la tabla necesita, de los veinte que el feed publica.
# Pedir menos hace la respuesta de `Subscribe` más pequeña y más rápida.
_LIVE_TOPICS = ["DriverList", "SessionInfo", "TimingData"]


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


def _feed_text(value: Any) -> str:
    """Un campo del feed como texto, desenvolviendo la forma ``{"Value": …}``.

    El feed publica unos campos como cadena y otros como objeto con ``Value``
    dentro (``LastLapTime``, ``BestLapTime``). Lo que queda vacío sale ``"-"``,
    que es lo que ``Common.Types.LiveTimingRow`` usa para el hueco.
    """
    if isinstance(value, dict):
        value = value.get("Value")
    text = _text(value).strip()
    return text or "-"


def _feed_gaps(line: Dict[str, Any], part: Any) -> Tuple[str, str]:
    """Diferencia al mejor y al de delante de un coche, del feed.

    **Medido en la Qualy 11365 (2026-09-12):** las dos viven en ``Stats``, que es
    una lista **por segmento** (Q1, Q2, Q3), y ``SessionPart`` de ``TimingData``
    dice cuál mirar. Un piloto eliminado conserva las de su último segmento.

    **Medido en la carrera 11369 (2026-09-13):** no hay ``Stats`` ni
    ``SessionPart``, y las dos viven en la propia línea. ``GapToLeader`` llega
    siempre como cadena; ``IntervalToPositionAhead``, siempre como dict con
    ``Value``, que ``_feed_text`` desenvuelve.

    **Lo devuelto no siempre es una duración, y las dos no comparten unidad:**
    ``"LAP n"`` marca al coche que acaba de empezar la vuelta ``n`` —en la
    primera lo llevan varios y después solo el líder—; ``"3 L"`` es una
    diferencia en vueltas, y **cualquiera de las dos la toma** cuando el rival
    va doblado; y una línea sin diferencia las manda vacías, que salen como
    ``"-"``. Quien llame no puede parsearlas como tiempo sin mirar.
    """
    stats = line.get("Stats")
    if isinstance(stats, list) and stats:
        index = part - 1 if isinstance(part, int) and 1 <= part <= len(stats) else 0
        entry = stats[index] if isinstance(stats[index], dict) else {}
        return (
            _feed_text(entry.get("TimeDiffToFastest")),
            _feed_text(entry.get("TimeDifftoPositionAhead")),
        )
    return (
        _feed_text(line.get("GapToLeader")),
        _feed_text(line.get("IntervalToPositionAhead")),
    )


def _feed_rows(snapshot: Dict[str, Any]) -> List[Dict[str, Any]]:
    """El snapshot del feed como las filas de ``Common.Types.LiveTimingRow``.

    Las claves son las del DTO de Haskell, igual que en los otros cuatro
    endpoints, para que el decode del backend sea directo.

    Tres decisiones de mapeo que conviene conocer:

    * **El líder lleva ``"LEADER"`` y ``"-"``**, como ya hace
      ``Handler.Live.Helper.assembleRows``: la tabla no puede decir dos cosas
      distintas según de dónde venga el dato.
    * **``KnockedOut`` no es un abandono.** Un eliminado de Q1 terminó su
      sesión; marcarlo haría creer en un incidente. Solo ``Retired`` y
      ``Stopped`` dan ``Dnf``, y el feed no publica nada que distinga ``Dns`` de
      ``Dsq``.
    * **Un coche sin ``Position`` se omite**, por lo mismo que en
      ``assembleRows``: sin posición no hay fila que ordenar.
    """
    drivers = snapshot.get("DriverList") or {}
    timing = snapshot.get("TimingData") or {}
    lines = timing.get("Lines") or {}
    part = timing.get("SessionPart")

    rows: List[Dict[str, Any]] = []
    for number, line in lines.items():
        if not isinstance(line, dict):
            continue
        position = _num(line.get("Position"))
        if position is None:
            continue
        info = drivers.get(number) if isinstance(drivers, dict) else None
        info = info if isinstance(info, dict) else {}
        gap, interval = _feed_gaps(line, part)
        leader = int(position) == 1
        rows.append(
            {
                "ltPosition": int(position),
                "ltDriver": _text(info.get("Tla")) or str(number),
                "ltTeam": _text(info.get("TeamName")),
                "ltGap": "LEADER" if leader else gap,
                "ltInterval": "-" if leader else interval,
                "ltLastLap": _feed_text(line.get("LastLapTime")),
                "ltStatus": (
                    "Dnf" if line.get("Retired") or line.get("Stopped") else "Running"
                ),
            }
        )

    rows.sort(key=lambda row: row["ltPosition"])
    return rows


@app.get("/fastf1/live")
def live() -> List[Dict[str, Any]]:
    """La tabla de live timing de la sesión **en marcha**, desde el feed oficial.

    Devuelve ``[]`` si no hay sesión en directo, por el mismo criterio que los
    otros cuatro: **degradar es trabajo del backend**, así que aquí una sesión
    sin datos no es un error.

    Solo se traduce a ``503`` el fallo del propio feed —conexión rechazada o
    estado que no llega—, que es lo que ``Handler.Live.Context`` necesita
    distinguir para caer a su cache.
    """
    try:
        snapshot = _live_snapshot()
    except Exception as error:
        raise HTTPException(status_code=503, detail=f"feed no disponible: {error}")
    return _feed_rows(snapshot)
