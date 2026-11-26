"""La clasificación de una sesión de FastF1 con la forma de OpenF1 ``/session_result``.

Lo que se traduce y desde dónde, medido con São Paulo 2026 (carrera, Q y FP1) contra
OpenF1:

* **Carrera y sprint:** la posición y las banderas salen de ``ClassifiedPosition``
  (``R`` y ``N`` abandono, ``W`` no salida, ``D`` y ``E`` descalificación). ``duration``
  es el tiempo total de quien acaba en la vuelta del líder (el ``Time`` del líder más
  el suyo, que es su hueco); un doblado no tiene ``duration`` y su hueco es
  ``"+N LAP"`` o ``"+N LAPS"``.
* **Clasificación y sprint quali:** ``Position``; ``duration`` y ``gap_to_leader`` son
  arreglos de tres (Q1, Q2, Q3), el hueco contra el mejor de **cada** parte.
* **Libres:** FastF1 no las ordena sin los mensajes de dirección de carrera, así que se
  ordenan por la mejor vuelta. No descuenta las vueltas borradas.

Pura: recibe filas ya sacadas de FastF1 (``results_rows``) y no importa FastF1.
"""

from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional

from stints import reached_end

RACES = {"Race", "Sprint"}
QUALIFYINGS = {"Qualifying", "Sprint Qualifying", "Sprint Shootout"}


def session_results(kind: str, rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Una entrada por piloto, en el orden de la clasificación y los no clasificados al
    final en el orden en que llegan.

    Cada fila de ``rows``: ``number`` (texto), ``position`` y ``classified`` (lo de
    FastF1), ``time`` (segundos o ``None``), ``laps`` (las de la clasificación o
    ``None``), ``q`` (Q1, Q2 y Q3 en segundos o ``None``), ``best`` (la mejor vuelta) y
    ``lap_count`` (las vueltas que tiene en la sesión).
    """
    if kind in RACES:
        out = _race(rows)
    elif kind in QUALIFYINGS:
        out = _qualifying(rows)
    else:
        out = _practice(rows)
    return sorted(out, key=lambda r: (r["position"] is None, r["position"] or 0))


def session_summary(event_name: Any, name: Any, statuses: Iterable[Any]) -> Dict[str, Any]:
    """De qué sesión se habla: ``meeting`` (el nombre del gran premio de FastF1), ``name``
    (``Race``, ``Practice 1``) y ``finished``, si el estado llegó al final del archivo
    (``stints.reached_end``, la misma regla que los stints). Sin dato, ``""`` y
    ``False``: una sesión aún no corrida sale con sus nombres y sin ``finished``.
    """
    return {
        "meeting": _name(event_name),
        "name": _name(name),
        "finished": reached_end(statuses),
    }


def _name(value: Any) -> str:
    """Un nombre como texto, o ``""`` sin dato (``None``, ``NaN``, ``"nan"``)."""
    if value is None:
        return ""
    text = str(value).strip()
    return "" if text.lower() in {"nan", "none", "nat"} else text


def _entry(row: Dict[str, Any], position: Optional[int], laps: Optional[int], duration: Any,
           gap: Any, dnf: bool = False, dns: bool = False, dsq: bool = False) -> Dict[str, Any]:
    return {
        "position": position,
        "driver_number": int(row["number"]),
        "number_of_laps": laps,
        "dnf": dnf,
        "dns": dns,
        "dsq": dsq,
        "duration": duration,
        "gap_to_leader": gap,
    }


def _race(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    classified = [r for r in rows if _digits(r["classified"]) is not None]
    leader = min(classified, key=lambda r: _digits(r["classified"]), default=None)
    total = leader["time"] if leader else None
    leader_laps = leader["laps"] if leader else None
    out = []
    for r in rows:
        mark = str(r["classified"] or "")
        position = _digits(mark)
        laps = r["laps"]
        if position is None:
            out.append(_entry(r, None, laps, None, None,
                              dnf=mark in ("R", "N"), dns=mark == "W", dsq=mark in ("D", "E")))
        elif r is leader:
            out.append(_entry(r, position, laps, total, 0))
        elif leader_laps is not None and laps is not None and laps < leader_laps:
            down = leader_laps - laps
            out.append(_entry(r, position, laps, None, f"+{down} LAP" + ("S" if down > 1 else "")))
        else:
            duration = None if total is None or r["time"] is None else round(total + r["time"], 3)
            out.append(_entry(r, position, laps, duration, r["time"]))
    return out


def _qualifying(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    best = [min((q[i] for q in (r["q"] for r in rows) if q[i] is not None), default=None)
            for i in range(3)]
    out = []
    for r in rows:
        q = r["q"]
        gap = [None if q[i] is None or best[i] is None else round(q[i] - best[i], 3) for i in range(3)]
        out.append(_entry(r, _int(r["position"]), r["lap_count"], list(q), gap))
    return out


def _practice(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    timed = sorted((r for r in rows if r["best"] is not None), key=lambda r: r["best"])
    fastest = timed[0]["best"] if timed else None
    place = {r["number"]: i for i, r in enumerate(timed, 1)}
    return [
        _entry(r, place.get(r["number"]), r["lap_count"], r["best"],
               None if r["best"] is None else round(r["best"] - fastest, 3))
        for r in rows
    ]


def _digits(value: Any) -> Optional[int]:
    """``"12"`` → 12; las letras de FastF1, la cadena vacía o ``None`` → ``None``."""
    text = str(value or "")
    return int(text) if text.isdigit() else None


def _int(value: Any) -> Optional[int]:
    """Un ``Position`` de FastF1 (``1.0``, ``NaN``) como entero, o ``None``."""
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    return None if out != out else int(out)
