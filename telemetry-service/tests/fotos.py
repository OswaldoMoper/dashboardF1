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
        destino.write_text(json.dumps(foto, ensure_ascii=False), encoding="utf-8")
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
