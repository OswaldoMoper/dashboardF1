"""Imprime la tabla de live timing de la sesión en marcha — herramienta de desarrollo.

No forma parte del microservicio: `telemetrySrc` del flake solo empaqueta `main.py`,
así que este fichero no entra en la derivación. Existe para **ver el dato del feed sin
levantar el servicio**, que es la forma más corta de comprobar que una sesión en
directo llega completa.

Es el mismo camino que sirve ``GET /fastf1/live``: importa ``_live_snapshot`` y
``_feed_rows`` de ``main`` en vez de reimplementarlos, así que lo que se ve aquí es
exactamente lo que el backend recibiría.

Uso, desde ``telemetry-service/``::

    python live_table.py                         # la tabla
    python live_table.py --json                  # las filas, como viajarían al backend
    python live_table.py --snapshot              # qué topics trae la foto, con peso y coste
    python live_table.py --snapshot SessionInfo  # un topic entero, en JSON

**Lo que ``--snapshot`` contesta y la tabla no:** ``_feed_rows`` lee ``DriverList`` y
``TimingData`` y descarta el resto, así que por la tabla no se ve qué más llegó, si
llegó actualizado, ni cuánto costó traerlo.

**Su límite, y conviene tenerlo escrito:** mide **una** foto. El coste del feed tiene
dos regímenes —con la sesión rodando y con la sesión terminada— así que un número
suelto no caracteriza nada; hace falta una tanda, y del mismo régimen a los dos lados
de cualquier comparación.
"""

import json
import sys
import time

from main import _LIVE_TOPICS, _feed_rows, _live_snapshot


def _dump_topic(snapshot, topic: str) -> int:
    """Un topic de la foto, entero. Devuelve 1 si el feed no lo mandó."""
    if topic not in snapshot:
        print(f"La foto no trae '{topic}'. Trae: {', '.join(sorted(snapshot))}")
        return 1
    print(json.dumps(snapshot[topic], indent=2, ensure_ascii=False))
    return 0


def _dump_inventory(snapshot, elapsed: float) -> int:
    """Qué topics trae la foto, cuánto pesa cada uno y cuánto costó traerla.

    Los pedidos que no aparecen se listan aparte: un topic ausente no es un fallo
    —``LapCount`` solo existe en carrera— pero es justo lo que hay que saber antes
    de construir algo encima.
    """
    sizes = {
        name: len(json.dumps(value, ensure_ascii=False).encode("utf-8"))
        for name, value in snapshot.items()
    }

    print(f"Foto en {elapsed:.2f} s.\n")
    for name, size in sorted(sizes.items(), key=lambda kv: -kv[1]):
        print(f"  {name:<24}{size / 1024:>8.1f} KB")
    print(f"  {'TOTAL':<24}{sum(sizes.values()) / 1024:>8.1f} KB")

    ausentes = [t for t in _LIVE_TOPICS if t not in snapshot]
    if ausentes:
        print(f"\nPedidos y no recibidos: {', '.join(ausentes)}")
    return 0


def main() -> int:
    args = sys.argv[1:]

    started = time.perf_counter()
    snapshot = _live_snapshot()
    elapsed = time.perf_counter() - started

    if "--snapshot" in args:
        rest = args[args.index("--snapshot") + 1:]
        return _dump_topic(snapshot, rest[0]) if rest else _dump_inventory(snapshot, elapsed)

    rows = _feed_rows(snapshot)

    if not rows:
        print("Sin filas: el feed conectó pero no hay sesión en marcha.")
        return 1

    if "--json" in args:
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
