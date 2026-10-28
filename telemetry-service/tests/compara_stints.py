"""Compara los stints que ``feed._feed_stints`` saca de una grabación con los de OpenF1 de
la misma sesión.

Pliega la grabación entera con ``fotos.plegar``, pide a OpenF1 ``/v1/stints`` y
``/v1/laps``, empareja por coche e índice y le pone tipo a cada pareja
(``clasificar``). Imprime el total por tipo y cada diferencia. Un coche que no corre la
sesión (``fuera_de_la_sesion``) no se compara: se nombra aparte.

Uso, desde la raíz del repositorio y **fuera de sesión** (con una en marcha, OpenF1 da
401)::

    nix develop .#telemetry -c python telemetry-service/tests/compara_stints.py <grabación> <session_key>
"""

from __future__ import annotations

import json
import sys
import time
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, List, Set, Tuple

AQUI = Path(__file__).resolve().parent

sys.path.insert(0, str(AQUI.parent))

from feed import _feed_stints
from fotos import mensajes, plegar

OPENF1 = "https://api.openf1.org/v1"
TEMAS = ("DriverList", "TimingAppData", "TimingData", "SessionStatus")

IGUAL = "igual"
FALTA_OPENF1 = "falta en OpenF1"
FALTA_FEED = "falta en el feed"
OTRO_COMPUESTO = "otro compuesto"
CORTADA = "grabación cortada"
NO_COMPLETADA = "vuelta no completada"
LONGITUD_1 = "longitud ±1"
LONGITUD = "longitud distinta"
ARRASTRE = "arrastre"
INICIO = "inicio corrido"

# En el orden en que `clasificar` los prueba: gana el primero que se cumple.
TIPOS = [
    IGUAL, FALTA_OPENF1, FALTA_FEED, OTRO_COMPUESTO, CORTADA, NO_COMPLETADA, LONGITUD_1, LONGITUD, ARRASTRE, INICIO
]


def clasificar(
    feed: List[Dict[str, Any]], openf1: List[Dict[str, Any]], sin_tiempo: Set[int], cortada: bool
) -> List[str]:
    """El tipo de cada pareja de stints de **un** coche, emparejados por índice: una
    entrada por índice hasta el más largo de los dos lados.

    ``feed`` son sus stints de ``_feed_stints``; ``openf1``, los de ``/v1/stints`` en orden
    de ``stint_number``; ``sin_tiempo``, sus vueltas de ``/v1/laps`` sin tiempo ni S3; y
    ``cortada``, que la grabación no llegó a ``Finished``. Gana el primer tipo que se cumple,
    en el orden de ``TIPOS``:

    * **vuelta no completada**: OpenF1 una vuelta más largo y su última, en ``sin_tiempo``.
    * **grabación cortada**: el último stint del feed, si ``cortada``.
    * La longitud se compara antes que el inicio. Con la misma longitud, **arrastre** es un
      inicio corrido exactamente lo que suman las diferencias de longitud de los stints
      anteriores del coche; si no, **inicio corrido**.
    """
    tipos: List[str] = []
    arrastre = 0
    for i in range(max(len(feed), len(openf1))):
        if i >= len(openf1):
            tipos.append(FALTA_OPENF1)
            continue
        if i >= len(feed):
            tipos.append(FALTA_FEED)
            continue
        cf, af, bf = feed[i]["tsCompound"], feed[i]["tsStartLap"], feed[i]["tsEndLap"]
        co, ao, bo = openf1[i]["compound"], openf1[i]["lap_start"], openf1[i]["lap_end"]
        diferencia = (bo - ao) - (bf - af)
        if (cf, af, bf) == (co, ao, bo):
            tipos.append(IGUAL)
        elif cf != co:
            tipos.append(OTRO_COMPUESTO)
        elif cortada and i == len(feed) - 1:
            tipos.append(CORTADA)
        elif diferencia == 1 and bo in sin_tiempo:
            tipos.append(NO_COMPLETADA)
        elif abs(diferencia) == 1:
            tipos.append(LONGITUD_1)
        elif diferencia != 0:
            tipos.append(LONGITUD)
        elif ao - af == arrastre:
            tipos.append(ARRASTRE)
        else:
            tipos.append(INICIO)
        arrastre += diferencia
    return tipos


def leer(grabacion: Path) -> Tuple[Dict[str, Any], bool, Set[str]]:
    """El estado final de la grabación, si quedó cortada —sin ``Finished`` en las
    actualizaciones de ``SessionStatus`` (la foto inicial trae el de la sesión anterior)— y
    los coches que recibieron el reinicio ``Stints: []`` en una actualización de
    ``TimingAppData`` (el de la foto inicial no cuenta)."""
    estado: Dict[str, Any] = {}
    cortada = True
    reiniciados: Set[str] = set()
    for topic, cuerpo, marca in mensajes(grabacion, TEMAS):
        if topic == "SessionStatus":
            if marca and isinstance(cuerpo, dict) and cuerpo.get("Status") == "Finished":
                cortada = False
            continue
        if topic == "TimingAppData" and marca and isinstance(cuerpo, dict):
            for coche, linea in (cuerpo.get("Lines") or {}).items():
                if isinstance(linea, dict) and linea.get("Stints") == []:
                    reiniciados.add(coche)
        estado[topic] = plegar(estado[topic], cuerpo) if topic in estado else cuerpo
    return estado, cortada, reiniciados


def fuera_de_la_sesion(coches: Set[str], reiniciados: Set[str]) -> Set[str]:
    """Los ``coches`` que no recibieron el reinicio de la sesión: el plegado los arrastra de
    la anterior y la foto del servidor no. Sin ningún reinicio (la grabación empezó con la
    sesión en marcha), ninguno."""
    return coches - reiniciados if reiniciados else set()


def pedir(ruta: str, session_key: str) -> List[Dict[str, Any]]:
    with urllib.request.urlopen(f"{OPENF1}/{ruta}?session_key={session_key}", timeout=60) as respuesta:
        return json.load(respuesta)


def tramo(compuesto: Any, inicio: Any, fin: Any) -> str:
    return f"{compuesto} {inicio}–{fin}"


def comparar(grabacion: Path, session_key: str) -> None:
    estado, cortada, reiniciados = leer(grabacion)
    del_feed: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for stint in _feed_stints(estado):
        del_feed[stint["tsCar"]].append(stint)
    fuera = fuera_de_la_sesion(set(del_feed), reiniciados)
    for coche in fuera:
        del del_feed[coche]

    stints = pedir("stints", session_key)
    time.sleep(1)
    vueltas = pedir("laps", session_key)
    de_openf1: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for stint in sorted(stints, key=lambda s: s["stint_number"]):
        de_openf1[str(stint["driver_number"])].append(stint)
    sin_tiempo: Dict[str, Set[int]] = defaultdict(set)
    for vuelta in vueltas:
        if vuelta.get("lap_duration") is None and vuelta.get("duration_sector_3") is None:
            sin_tiempo[str(vuelta["driver_number"])].add(vuelta["lap_number"])

    total: Counter = Counter()
    for coche in sorted(set(del_feed) | set(de_openf1), key=int):
        suyos, ajenos = del_feed[coche], de_openf1[coche]
        for i, tipo in enumerate(clasificar(suyos, ajenos, sin_tiempo[coche], cortada)):
            total[tipo] += 1
            if tipo == IGUAL:
                continue
            s = suyos[i] if i < len(suyos) else None
            o = ajenos[i] if i < len(ajenos) else None
            lado_feed = tramo(s["tsCompound"], s["tsStartLap"], s["tsEndLap"]) if s else "—"
            lado_openf1 = tramo(o["compound"], o["lap_start"], o["lap_end"]) if o else "—"
            print(f"#{coche} stint {i + 1}: feed {lado_feed} | OpenF1 {lado_openf1} → {tipo}")

    for coche in sorted(fuera, key=int):
        print(f"fuera de la sesión: #{coche} (sin el reinicio de Stints)")
    print(f"{grabacion.name} ({session_key}): {'cortada' if cortada else 'con Finished'}")
    print(f"iguales {total[IGUAL]}, distintos {sum(total.values()) - total[IGUAL]}")
    for tipo in TIPOS[1:]:
        if total[tipo]:
            print(f"  {tipo}: {total[tipo]}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    comparar(Path(sys.argv[1]), sys.argv[2])
