"""El feed en vivo traducido a las claves de los DTO de Haskell, sin efectos.

Lo puro de ``GET /fastf1/live``: qué temas se piden (``_LIVE_TOPICS``) y cómo se lee la
foto, que llega ya capturada (``main._live_snapshot``). No importa FastF1.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

from convert import _num, _text


# Lo que se pide en la suscripción, de todo lo que el feed publica. `_feed_rows`
# lee dos —`DriverList` y `TimingData`—; el resto lo consume el dato de sesión que
# viaja con la tabla, y los que hoy no lee nadie se piden igual para que ampliar la
# tabla no obligue a volver aquí.
#
# **Lo que cuesta pedir de más está medido** (2026-09-14, sin sesión en marcha,
# tres pasadas a cada lado): la foto pasa de 47,5 a 95,0 KB y el tiempo **no se
# mueve** —17,03 s de media contra 17,19, menos de lo que varían las pasadas entre
# sí—. O sea que el coste está en la conversación con el feed y no en los bytes, y
# el techo de 30 s de `Handler.Feed.Manager` conserva su margen.
#
# Y el peso de un topic depende de **cuándo** se pida, porque la foto trae estado
# acumulado: `RaceControlMessages` son 30 KB con la sesión acabada y menos de 1 KB
# antes de empezar.
#
# `LapCount` **solo existe en carrera** —57 mensajes en la carrera 11369 y ninguno
# en la clasificación 11365—, así que su ausencia en la foto es el caso normal y no
# un fallo del feed.
_LIVE_TOPICS = [
    "DriverList",
    "SessionInfo",
    "TimingData",
    "TimingAppData",
    "TimingStats",
    "LapCount",
    "TrackStatus",
    "RaceControlMessages",
    "ExtrapolatedClock",
]


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

    **La diferencia en vueltas llega con dos formas, con y sin espacio, y se
    devuelve tal cual.** Medido en la carrera 11369: ``GapToLeader`` trae
    ``"1 L"`` 12 veces y ``"1L"`` 8, e ``IntervalToPositionAhead`` también trae
    las dos; las de dos cifras (``"14L"``, ``"26L"``) solo salieron sin espacio.
    Quien distinga vueltas de segundos tiene que aceptar las dos.
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


def _feed_part_best(line: Dict[str, Any], part: Any) -> str:
    """La mejor vuelta de un coche en la parte en curso de una clasificación.

    Vive en ``BestLapTimes``, una lista **por parte** (Q1, Q2, Q3), y ``SessionPart``
    dice cuál; medido en la clasificación del 2026-09-12. Fuera de una clasificación
    no hay lista, y sale **vacío**: «esta sesión no tiene partes». Un coche sin
    vuelta en la parte sale ``"-"``.
    """
    bests = line.get("BestLapTimes")
    if not isinstance(bests, list) or not isinstance(part, int) or not 1 <= part <= len(bests):
        return ""
    entry = bests[part - 1]
    return _feed_text(entry if isinstance(entry, dict) else None)


def _feed_part_bests(line: Dict[str, Any]) -> List[str]:
    """La mejor vuelta de un coche en cada parte de una clasificación, en orden.

    Una entrada por parte que el feed publica, ``"-"`` en la que no tiene vuelta.
    Fuera de una clasificación no hay ``BestLapTimes`` y sale la lista vacía.
    """
    bests = line.get("BestLapTimes")
    if not isinstance(bests, list):
        return []
    return [_feed_text(entry if isinstance(entry, dict) else None) for entry in bests]


def _feed_last_sectors(line: Dict[str, Any]) -> List[str]:
    """Los tres sectores de la última vuelta completa de un coche, como texto.

    Salen de ``Sectors[n].PreviousValue``; ``Value`` es el de la vuelta en curso. Tres
    entradas, ``"-"`` en el sector que no lo trae, y la lista vacía si la línea no trae
    ``Sectors``. **No comprueba que sumen la vuelta:** eso lo decide el backend.
    """
    sectors = line.get("Sectors")
    if isinstance(sectors, list):
        sectors = {str(i): sector for i, sector in enumerate(sectors)}
    if not isinstance(sectors, dict):
        return []
    out = []
    for i in range(3):
        sector = sectors.get(str(i))
        previous = sector.get("PreviousValue") if isinstance(sector, dict) else None
        out.append(_feed_text(previous))
    return out


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
                "ltCar": str(number),
                "ltDriver": _text(info.get("Tla")) or str(number),
                "ltTeam": _text(info.get("TeamName")),
                "ltGap": "LEADER" if leader else gap,
                "ltInterval": "-" if leader else interval,
                "ltLastLap": _feed_text(line.get("LastLapTime")),
                "ltLastSectors": _feed_last_sectors(line),
                "ltStatus": (
                    "Dnf" if line.get("Retired") or line.get("Stopped") else "Running"
                ),
                "ltBestLap": _feed_text(line.get("BestLapTime")),
                "ltPartBestLap": _feed_part_best(line, part),
                "ltPartBests": _feed_part_bests(line),
                "ltKnockedOut": bool(line.get("KnockedOut")),
                "ltCutoff": bool(line.get("Cutoff")),
            }
        )

    rows.sort(key=lambda row: row["ltPosition"])
    return rows


def _feed_stints(snapshot: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Los stints de cada coche en ``TimingAppData``, con las claves de
    ``Common.Types.TyreStint`` más las del feed.

    Coches en orden de número y, dentro de cada uno, **un stint por entrada de
    ``Stints``** (lista, o diccionario por índice tras plegar), en su orden: no se
    omite ninguno, tampoco el ``UNKNOWN`` ni el de 0 vueltas, y el mismo juego tras
    parar sale aparte.

    * ``tsLaps`` son las vueltas **completadas** (``TotalLaps − StartLaps``): la
      empezada y no completada no cuenta.
    * ``tsStartLap`` es 1 más las vueltas de los anteriores y ``tsEndLap`` el inicio
      más las vueltas menos 1: un stint de 0 vueltas acaba antes de empezar.
    * ``tsAge`` es ``StartLaps``; ``tsNew`` y ``tsSameSet`` dicen si ``New`` es
      ``"true"`` y si ``TyresNotChanged`` es ``"1"``.
    * Un contador que falta o no es número cuenta 0, y las vueltas negativas que
      salgan de ahí **no se recortan**.
    * El stint en curso no lleva marca: si la sesión sigue, lo dice quien llama.
    """
    drivers = snapshot.get("DriverList") or {}
    timing_app = snapshot.get("TimingAppData") or {}
    lines = timing_app.get("Lines") or {}

    stints: List[Dict[str, Any]] = []
    for number in sorted(lines, key=lambda n: (_num(n) or 0, n)):
        line = lines[number]
        if not isinstance(line, dict):
            continue
        entries = line.get("Stints") or []
        if isinstance(entries, dict):
            entries = [entries[k] for k in sorted(entries, key=lambda k: _num(k) or 0)]
        info = drivers.get(number) if isinstance(drivers, dict) else None
        info = info if isinstance(info, dict) else {}
        driver = _text(info.get("Tla")) or str(number)
        start = 1
        for entry in entries:
            entry = entry if isinstance(entry, dict) else {}
            age = int(_num(entry.get("StartLaps")) or 0)
            laps = int(_num(entry.get("TotalLaps")) or 0) - age
            stints.append(
                {
                    "tsDriver": driver,
                    "tsCar": str(number),
                    "tsCompound": _text(entry.get("Compound")),
                    "tsStartLap": start,
                    "tsEndLap": start + laps - 1,
                    "tsLaps": laps,
                    "tsAge": age,
                    "tsNew": _text(entry.get("New")) == "true",
                    "tsSameSet": _text(entry.get("TyresNotChanged")) == "1",
                }
            )
            start += laps
    return stints


def _feed_flags(snapshot: Dict[str, Any]) -> List[Dict[str, str]]:
    """Los avisos de bandera de control de carrera, tal como llegan.

    Solo los transporta: quién cuenta y qué estado sale lo decide el backend
    (``Handler.Live.Helper.feedState``). **La lista trae también los de la
    sesión anterior** hasta el primer aviso de la nueva; los descarta el
    backend con la hora de inicio.
    """
    race_control = snapshot.get("RaceControlMessages")
    messages = race_control.get("Messages") if isinstance(race_control, dict) else None
    if isinstance(messages, dict):
        messages = list(messages.values())
    if not isinstance(messages, list):
        return []
    return [
        {
            "utc": _text(message.get("Utc")),
            "flag": _text(message.get("Flag")),
            "scope": _text(message.get("Scope")),
        }
        for message in messages
        if isinstance(message, dict) and _text(message.get("Category")) == "Flag"
    ]


def _feed_notices(snapshot: Dict[str, Any]) -> List[Dict[str, str]]:
    """Los avisos de control de carrera que no son de bandera, tal como llegan.

    Los de bandera viajan aparte (``_feed_flags``). Como allí, **la lista trae
    también los de la sesión anterior**, y cuáles cuentan lo decide el backend.
    """
    race_control = snapshot.get("RaceControlMessages")
    messages = race_control.get("Messages") if isinstance(race_control, dict) else None
    if isinstance(messages, dict):
        messages = list(messages.values())
    if not isinstance(messages, list):
        return []
    return [
        {
            "utc": _text(message.get("Utc")),
            "category": _text(message.get("Category")),
            "message": _text(message.get("Message")),
        }
        for message in messages
        if isinstance(message, dict) and _text(message.get("Category")) != "Flag"
    ]


def _feed_track(snapshot: Dict[str, Any]) -> Optional[Dict[str, str]]:
    """El estado de la pista tal como llega: el código (``"1"`` a ``"7"``) y su
    nombre (``"AllClear"``, ``"Yellow"``, ``"Red"``…). ``None`` sin el tema."""
    track = snapshot.get("TrackStatus")
    if not isinstance(track, dict):
        return None
    return {"status": _text(track.get("Status")), "message": _text(track.get("Message"))}


def _feed_session(snapshot: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Qué sesión anuncia el feed, con las claves de ``Handler.Feed.Helper``.

    Sale de seis topics y ninguno se reordena ni se calcula: el reloj viaja
    **crudo** —el instante, el restante como texto y la marca— porque quien lo
    resuelve necesita saber cuándo está sirviendo, y eso no se sabe aquí. Lo
    mismo la hora de inicio (local, con su desfase aparte), los avisos de
    control de carrera (``_feed_flags``, ``_feed_notices``) y el estado de la
    pista (``_feed_track``): qué sale de ellos lo decide el backend.

    ``None`` si la foto no trae ``SessionInfo``, y eso significa «el feed no
    anunció sesión», que no es lo mismo que anunciarla con los campos vacíos.
    No se ha observado nunca en las dos grabaciones.

    ``siCircuit`` solo va si ``Meeting`` trae ``Circuit.ShortName``.

    Dos ausencias que son el caso normal y no un fallo:

    * ``LapCount`` **solo existe en carrera**, así que cuatro de las cinco
      sesiones de un fin de semana llegan sin vuelta. Los dos campos van o no
      van juntos: una vuelta sin total no dice por dónde va la sesión.
    * ``ExtrapolatedClock`` puede faltar, y su marca puede faltar dentro de él;
      ausente se trata como **parado**, que es lo que el feed emitió en los dos
      únicos mensajes medidos sin ella.
    * La parte (``siPart``; ``0`` antes de empezar), cuántos entran en cada parte
      (``siEntries``) y el tiempo del 107 % (``siCutOffTime``) **solo existen en
      clasificación**. El tiempo se publica durante la primera parte, y la foto
      **conserva el último en las siguientes**: quién lo enseñe mira la parte.

    Y el estado sale del **campo** ``SessionStatus`` de ``SessionInfo``, no del
    topic homónimo, que es otro y cicla por segmento.
    """
    info = snapshot.get("SessionInfo")
    if not isinstance(info, dict):
        return None

    meeting = info.get("Meeting")
    meeting = meeting if isinstance(meeting, dict) else {}

    session: Dict[str, Any] = {
        "siType": _text(info.get("Type")),
        "siName": _text(info.get("Name")),
        "siMeeting": _text(meeting.get("Name")),
        "siState": _text(info.get("SessionStatus")),
        "siStartDate": _text(info.get("StartDate")) or None,
        "siGmtOffset": _text(info.get("GmtOffset")) or None,
        "siFlags": _feed_flags(snapshot),
        "siNotices": _feed_notices(snapshot),
    }

    circuit = meeting.get("Circuit")
    circuit = circuit if isinstance(circuit, dict) else {}
    short_name = _text(circuit.get("ShortName"))
    if short_name:
        session["siCircuit"] = short_name

    laps = snapshot.get("LapCount")
    if isinstance(laps, dict):
        current = _num(laps.get("CurrentLap"))
        total = _num(laps.get("TotalLaps"))
        if current is not None and total is not None:
            session["siCurrentLap"] = int(current)
            session["siTotalLaps"] = int(total)

    clock = snapshot.get("ExtrapolatedClock")
    if isinstance(clock, dict):
        session["siClockUtc"] = _text(clock.get("Utc")) or None
        session["siClockRemaining"] = _text(clock.get("Remaining")) or None
        session["siClockRunning"] = bool(clock.get("Extrapolating"))

    timing = snapshot.get("TimingData")
    timing = timing if isinstance(timing, dict) else {}
    part = _num(timing.get("SessionPart"))
    if part is not None:
        session["siPart"] = int(part)
    entries = timing.get("NoEntries")
    if isinstance(entries, list):
        session["siEntries"] = [int(n) for n in map(_num, entries) if n is not None]
    cutoff = _text(timing.get("CutOffTime"))
    if cutoff:
        session["siCutOffTime"] = cutoff

    track = _feed_track(snapshot)
    if track is not None:
        session["siTrack"] = track

    return session


def _feed_live(snapshot: Dict[str, Any]) -> Dict[str, Any]:
    """La respuesta de ``GET /fastf1/live``: ``{"session": …, "rows": [ … ],
    "stints": [ … ]}``.

    Las tres partes salen de la **misma** foto, así que hablan del mismo instante:
    pedirlas por separado daría partes que pueden discrepar.
    """
    return {
        "session": _feed_session(snapshot),
        "rows": _feed_rows(snapshot),
        "stints": _feed_stints(snapshot),
    }
