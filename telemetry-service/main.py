"""telemetry-service — FastF1 detrás de una interfaz HTTP estable.

Microservicio que encapsula FastF1 para que el backend Haskell no tenga que
hablar Python ni pandas. Fase 4: un solo endpoint,
``GET /fastf1/telemetry/{session_key}/{driver}``, que devuelve un arreglo JSON
plano de muestras de telemetría, cada una **etiquetada con el acrónimo del
piloto** (``tpDriver``), con exactamente las claves de
``Common.Types.TelemetryPoint`` para que el decode del backend sea directo.

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
  su cache o al dummy.

Endpoints del contrato **todavía no implementados**
(``docs/ARCHITECTURE.md §2.3``): ``GET /fastf1/laps/{session_key}`` y
``GET /fastf1/comparison/{session_key}?drivers=VER,LEC``. El segundo alimenta
``/api/comparison``, que es otra área de negocio y otra sesión.

Variables de entorno: ``FASTF1_CACHE`` (default ``.fastf1-cache``) y
``TELEMETRY_MAX_POINTS`` (default ``60``, muestras por piloto).
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

    try:
        label = str(session.get_driver(number)["Abbreviation"])
    except Exception:
        label = str(number)

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
