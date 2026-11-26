"""Los stints de una sesión de FastF1 con la forma de OpenF1 ``/stints``, y si la sesión
llegó entera.

Pura: recibe filas ya sacadas de FastF1 y no importa FastF1.
"""

from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Tuple

from convert import _num, _text


def session_stints(laps: Iterable[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Un stint por coche y ``Stint`` de FastF1, en orden de coche y de stint.

    Cada fila de ``laps``: ``number`` (texto), ``lap`` (``LapNumber``), ``stint``,
    ``compound`` y ``tyre_life`` (lo de FastF1, con sus huecos). Una vuelta sin número
    o sin stint no entra en ninguno.

    Cada stint: ``driver_number``, ``compound`` (``None`` si FastF1 no lo conoce),
    ``lap_start`` y ``lap_end`` (incluidas) y ``tyre_age_at_start``: el ``TyreLife`` de
    su primera vuelta menos uno, o ``None`` si esa vuelta no lo trae. El compuesto
    también es el de la primera vuelta.
    """
    groups: Dict[Tuple[int, int], List[Tuple[int, Dict[str, Any]]]] = {}
    for row in laps:
        lap, stint = _whole(row.get("lap")), _whole(row.get("stint"))
        number = _whole(row.get("number"))
        if lap is None or stint is None or number is None:
            continue
        groups.setdefault((number, stint), []).append((lap, row))
    out = []
    for (number, _), rows in sorted(groups.items()):
        rows.sort(key=lambda pair: pair[0])
        first = rows[0][1]
        life = _whole(first.get("tyre_life"))
        out.append({
            "driver_number": number,
            "compound": _text(first.get("compound")) or None,
            "lap_start": rows[0][0],
            "lap_end": rows[-1][0],
            "tyre_age_at_start": None if life is None else life - 1,
        })
    return out


def reached_end(statuses: Iterable[Any]) -> bool:
    """Si el estado de la sesión llegó al final del archivo: ``Finalised`` o ``Ends``.

    No mira ``Finished``: en una Q sale al acabar cada parte, y una sesión dada por
    acabada tras una bandera roja no lo trae.
    """
    return bool({"Finalised", "Ends"} & {str(s) for s in statuses})


def complete(statuses: Iterable[Any], last_lap: Optional[int], result_laps: Optional[int]) -> bool:
    """Si la sesión llegó entera: su estado llegó al final del archivo (``reached_end``)
    **y** su última vuelta no queda por debajo de las vueltas de su resultado. Sin vueltas
    del resultado (una Q o unas libres), solo cuenta el estado; sin ninguna vuelta, no
    llegó entera.
    """
    if not reached_end(statuses):
        return False
    if last_lap is None:
        return False
    return result_laps is None or last_lap >= result_laps


def cut(statuses: Iterable[Any], last_lap: Optional[int], result_laps: Optional[int]) -> Optional[Dict[str, Any]]:
    """Dónde acaba una sesión que no llegó entera (``complete``): ``lastLap`` y, si su
    resultado trae más vueltas, ``laps``; si no, ``laps`` es ``None``. Entera, o sin
    ninguna vuelta, ``None``: sin vueltas no hay nada que comparar."""
    if last_lap is None or complete(statuses, last_lap, result_laps):
        return None
    laps = result_laps if result_laps is not None and last_lap < result_laps else None
    return {"lastLap": last_lap, "laps": laps}


def _whole(value: Any) -> Optional[int]:
    """``12``, ``12.0`` o ``"12"`` → 12; ``NaN``, ``None`` o lo no numérico → ``None``."""
    out = _num(value)
    return None if out is None else int(out)
