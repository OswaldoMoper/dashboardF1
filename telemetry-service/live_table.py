"""Imprime la tabla de live timing de la sesión en marcha — herramienta de desarrollo.

No forma parte del microservicio: `telemetrySrc` del flake solo empaqueta `main.py`,
así que este fichero no entra en la derivación. Existe para **ver el dato del feed sin
levantar el servicio**, que es la forma más corta de comprobar que una sesión en
directo llega completa.

Es el mismo camino que sirve ``GET /fastf1/live``: importa ``_live_snapshot`` y
``_feed_rows`` de ``main`` en vez de reimplementarlos, así que lo que se ve aquí es
exactamente lo que el backend recibiría.

Uso, desde ``telemetry-service/``::

    python live_table.py

Con ``--json`` escribe las filas tal cual viajarían al backend, en vez de la tabla.
"""

import json
import sys

from main import _feed_rows, _live_snapshot


def main() -> int:
    rows = _feed_rows(_live_snapshot())

    if not rows:
        print("Sin filas: el feed conectó pero no hay sesión en marcha.")
        return 1

    if "--json" in sys.argv[1:]:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return 0

    print(f"{'Pos':>3}  {'Drv':<4} {'Equipo':<22} "
          f"{'Gap':>9} {'Interval':>9} {'Last Lap':>10}  Estado")
    for row in rows:
        print(f"{row['ltPosition']:>3}  {row['ltDriver']:<4} {row['ltTeam']:<22} "
              f"{row['ltGap']:>9} {row['ltInterval']:>9} {row['ltLastLap']:>10}  "
              f"{row['ltStatus']}")
    print(f"\n{len(rows)} filas.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
