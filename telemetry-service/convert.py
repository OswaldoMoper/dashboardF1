"""Saneado de valores para el JSON del microservicio: lo que aeson puede leer."""

from __future__ import annotations

import math
from typing import Any, Optional


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
