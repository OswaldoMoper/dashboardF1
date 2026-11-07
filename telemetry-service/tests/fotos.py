"""Saca las fotos de prueba del feed de una grabación, y la salida esperada de ``_feed_rows``.

Una grabación es la que deja ``dashboardF1-record``: la foto inicial (cada topic como
cadena JSON y marca vacía) y después cada mensaje con su marca. De cada grabación salen
tres fotos con los temas que pide el servicio (``feed._LIVE_TOPICS``):

* ``<nombre>-inicial.json`` — la foto tal como llega al conectarse.
* ``<nombre>-plegada.json`` — la foto inicial con los mensajes aplicados hasta el
  instante con más formas distintas en ``TimingData`` (``formas``), muestreado cada
  ``CADA`` mensajes de ese topic.
* ``<nombre>-final.json`` — la foto inicial con todos los mensajes aplicados.

Las dos últimas son la foto que el servicio habría recibido al conectarse en ese
instante, **con el plegado de aquí** (``plegar``), que puede no coincidir del todo con
el del servidor.

Las tres se escriben **transformadas** (``transformar``): la forma es la del feed, pero
los tiempos, el reparto de los datos entre coches y los stints ya no son los de la sesión.

Uso, desde la raíz del repositorio::

    nix develop .#telemetry -c python telemetry-service/tests/fotos.py <grabación> <nombre>
    nix develop .#telemetry -c python telemetry-service/tests/fotos.py --esperado

``--esperado`` reescribe ``esperado/`` con la salida de ``_feed_rows`` del código de hoy
sobre cada foto de ``fotos/``. Es para un cambio de comportamiento **intencionado**: se
corre, se pasa la suite y se mira el diff antes de commitear.
"""

from __future__ import annotations

import ast
import copy
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Collection, Dict, Iterator, Tuple

AQUI = Path(__file__).resolve().parent
FOTOS = AQUI / "fotos"
ESPERADO = AQUI / "esperado"

sys.path.insert(0, str(AQUI.parent))

from feed import _LIVE_TOPICS

# Cada cuántos mensajes de `TimingData` se mira si el instante es el más rico.
CADA = 500

# Lo que cambia `transformar`: el factor de los tiempos, cuántos puestos rota la parrilla
# al repartir los datos entre coches, y a qué compuesto pasa cada uno.
FACTOR = 1.0137
ROTA = 5
COMPUESTOS = {"SOFT": "MEDIUM", "MEDIUM": "HARD", "HARD": "SOFT"}

_TIEMPO = re.compile(r"(\+?)(?:(\d+):)?(\d+)\.(\d{3})")
# Los topics con una línea por coche, que son también los que llevan tiempos.
_POR_COCHE = ("TimingData", "TimingStats", "TimingAppData")


def _escala(texto: str) -> str:
    """Un tiempo (``1:36.680``, ``29.268``, ``+5.089``) por ``FACTOR``, en su misma forma;
    lo que no es un tiempo, tal cual."""
    m = _TIEMPO.fullmatch(texto)
    if not m:
        return texto
    signo, minutos, segundos, milis = m.groups()
    ms = round(((int(minutos or 0) * 60 + int(segundos)) * 1000 + int(milis)) * FACTOR)
    if minutos is None:
        return f"{signo}{ms // 1000}.{ms % 1000:03d}"
    return f"{signo}{ms // 60000}:{ms // 1000 % 60:02d}.{ms % 1000:03d}"


def _tiempos(x: Any) -> Any:
    if isinstance(x, dict):
        return {k: _tiempos(v) for k, v in x.items()}
    if isinstance(x, list):
        return [_tiempos(v) for v in x]
    return _escala(x) if isinstance(x, str) else x


def _reparto(foto: Dict[str, Any]) -> Dict[str, str]:
    """Qué número recibe los datos de cada coche: la parrilla de ``DriverList``, por
    número, rotada ``ROTA`` puestos."""
    numeros = sorted((foto.get("DriverList") or {}).keys(), key=lambda n: (len(n), n))
    numeros = [n for n in numeros if n.isdigit()]
    if not numeros:
        return {}
    return {n: numeros[(i + ROTA) % len(numeros)] for i, n in enumerate(numeros)}


def _reparte(foto: Dict[str, Any], destino: Dict[str, str]) -> None:
    """Los datos del coche ``n`` pasan al número ``destino[n]``, y su línea en
    ``DriverList`` con ellos; los nombres de cada número no cambian."""
    for topic in _POR_COCHE:
        lineas = (foto.get(topic) or {}).get("Lines")
        if not isinstance(lineas, dict):
            continue
        nuevas = {}
        for n, linea in lineas.items():
            m = destino.get(n, n)
            if isinstance(linea, dict) and "RacingNumber" in linea:
                linea = {**linea, "RacingNumber": m}
            nuevas[m] = linea
        foto[topic]["Lines"] = nuevas
    pilotos = foto.get("DriverList")
    if isinstance(pilotos, dict):
        lineas = {n: p.get("Line") for n, p in pilotos.items() if isinstance(p, dict) and "Line" in p}
        for n, linea in lineas.items():
            m = destino.get(n, n)
            if isinstance(pilotos.get(m), dict):
                pilotos[m] = {**pilotos[m], "Line": linea}


def _cambia_stints(stints: Any) -> Any:
    """Cada compuesto pasa a otro (``COMPUESTOS``) y la primera parada se retrasa una
    vuelta si el stint siguiente tiene al menos dos: el total de vueltas no cambia, y la
    edad de un juego que vuelve a pista sigue siendo la que llevaba al pararse."""
    if not isinstance(stints, list) or not all(isinstance(s, dict) for s in stints):
        return stints
    try:
        vueltas = [int(s["TotalLaps"]) - int(s["StartLaps"]) for s in stints]
    except (KeyError, TypeError, ValueError):
        return stints
    if len(vueltas) >= 2 and vueltas[1] >= 2:
        vueltas[0] += 1
        vueltas[1] -= 1
    nuevos, total = [], None
    for s, v in zip(stints, vueltas):
        edad = total if s.get("TyresNotChanged") == "1" and total is not None else int(s["StartLaps"])
        total = edad + v
        nuevos.append({
            **s,
            "Compound": COMPUESTOS.get(s.get("Compound"), s.get("Compound")),
            "StartLaps": edad,
            "TotalLaps": total,
        })
    return nuevos


def transformar(foto: Dict[str, Any]) -> Dict[str, Any]:
    """La foto con la forma del feed y otros datos: los tiempos por ``FACTOR``, los datos
    de cada coche bajo otro número (``ROTA``) y los stints cambiados (``_cambia_stints``).
    Los textos de control de carrera, los nombres y las horas no cambian. No es
    idempotente: se aplica una vez, a una foto sacada de una grabación."""
    foto = copy.deepcopy(foto)
    _reparte(foto, _reparto(foto))
    for topic in _POR_COCHE:
        if topic in foto:
            foto[topic] = _tiempos(foto[topic])
    for linea in ((foto.get("TimingAppData") or {}).get("Lines") or {}).values():
        if isinstance(linea, dict) and "Stints" in linea:
            linea["Stints"] = _cambia_stints(linea["Stints"])
    return foto


def plegar(dst: Any, src: Any) -> Any:
    """Aplica un mensaje del feed sobre el estado: los dicts se funden, una lista se
    actualiza con un dict de índices (``{"1": …}``) y ``_deleted`` quita claves."""
    if isinstance(src, dict) and isinstance(dst, list):
        for k, v in src.items():
            i = int(k)
            while len(dst) <= i:
                dst.append({})
            dst[i] = plegar(dst[i], v)
        return dst
    if isinstance(src, dict) and isinstance(dst, dict):
        for k in src.get("_deleted", []):
            dst.pop(k, None)
        for k, v in src.items():
            if k != "_deleted":
                dst[k] = plegar(dst[k], v) if k in dst else v
        return dst
    return src


def formas(timing: Any) -> Counter:
    """Las formas de ``TimingData`` que leen las reglas de ``feed``, contadas."""
    c: Counter = Counter()
    timing = timing if isinstance(timing, dict) else {}
    if "SessionPart" in timing:
        c[f"SessionPart={timing['SessionPart']}"] += 1
    for line in (timing.get("Lines") or {}).values():
        if not isinstance(line, dict):
            continue
        if "Position" not in line:
            c["sin Position"] += 1
        for k in ("Stats", "BestLapTimes"):
            if isinstance(line.get(k), list):
                c[k] += 1
        for k in ("KnockedOut", "Cutoff", "Retired", "Stopped"):
            if line.get(k):
                c[k] += 1
        gap = line.get("GapToLeader")
        if isinstance(gap, str):
            if gap.startswith("LAP "):
                c["Gap LAP n"] += 1
            elif re.fullmatch(r"\d+ L", gap):
                c["Gap N L"] += 1
            elif re.fullmatch(r"\d+L", gap):
                c["Gap NL"] += 1
        interval = line.get("IntervalToPositionAhead")
        value = interval.get("Value") if isinstance(interval, dict) else None
        if isinstance(value, str) and re.fullmatch(r"\d+ ?L", value):
            c["Interval vueltas"] += 1
    return c


def mensajes(grabacion: Path, temas: Collection[str]) -> Iterator[Tuple[str, Any, str]]:
    """Los mensajes de una grabación de los ``temas`` dados, en orden, como ``(topic,
    cuerpo, marca)`` con el cuerpo ya como objeto. La foto inicial lleva la marca vacía.
    Las líneas que no son un mensaje se saltan."""
    with grabacion.open(encoding="utf-8") as f:
        for linea in f:
            try:
                msg = ast.literal_eval(linea.strip())
            except (ValueError, SyntaxError):
                continue
            if not (isinstance(msg, list) and len(msg) >= 3 and msg[0] in temas):
                continue
            topic, cuerpo, marca = msg[0], msg[1], msg[2]
            if isinstance(cuerpo, str):
                cuerpo = json.loads(cuerpo)
            yield topic, cuerpo, marca


def sacar(grabacion: Path, nombre: str) -> None:
    inicial: Dict[str, Any] = {}
    estado: Dict[str, Any] = {}
    plegada: Dict[str, Any] = {}
    mejor = -1
    vistos = 0
    for topic, cuerpo, marca in mensajes(grabacion, _LIVE_TOPICS):
        if marca == "" and topic not in inicial:
            inicial[topic] = cuerpo
            estado[topic] = copy.deepcopy(cuerpo)
            continue
        estado[topic] = plegar(estado[topic], cuerpo) if topic in estado else cuerpo
        if topic == "TimingData":
            vistos += 1
            if vistos % CADA == 0:
                rico = len(formas(estado["TimingData"]))
                if rico > mejor:
                    mejor, plegada = rico, copy.deepcopy(estado)
    FOTOS.mkdir(exist_ok=True)
    for sufijo, foto in (("inicial", inicial), ("plegada", plegada), ("final", estado)):
        destino = FOTOS / f"{nombre}-{sufijo}.json"
        destino.write_text(json.dumps(transformar(foto), ensure_ascii=False), encoding="utf-8")
        print(f"{destino.name}: {len(foto)} temas, {dict(formas(foto.get('TimingData')))}")


def esperado() -> None:
    from feed import _feed_rows

    ESPERADO.mkdir(exist_ok=True)
    for foto in sorted(FOTOS.glob("*.json")):
        filas = _feed_rows(json.loads(foto.read_text(encoding="utf-8")))
        destino = ESPERADO / foto.name
        destino.write_text(
            json.dumps(filas, ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
        )
        print(f"{destino.name}: {len(filas)} filas")


if __name__ == "__main__":
    if sys.argv[1:] == ["--esperado"]:
        esperado()
    elif len(sys.argv) == 3:
        sacar(Path(sys.argv[1]), sys.argv[2])
    else:
        sys.exit(__doc__)
