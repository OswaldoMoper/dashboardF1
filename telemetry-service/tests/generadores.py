"""Fotos del feed generadas: la forma de una foto real, con lo demás al azar.

``foto_del_feed`` da una foto con los temas que pide el servicio (``feed._LIVE_TOPICS``)
y una **parrilla coherente**: los mismos coches en ``DriverList``, ``TimingData``,
``TimingAppData`` y ``TimingStats``, posiciones del 1 al N sin repetir, tiempos con el
formato del feed y los campos propios de libres, clasificación o carrera. Los nombres,
acrónimos, equipos y circuitos son inventados.

``GENERADA`` es la etiqueta ``"generada"`` que el campo ``Path`` de ``SessionInfo``
lleva siempre, para que una foto generada no se confunda con una grabada.
"""

from __future__ import annotations

from typing import Any, Dict, List

from hypothesis import strategies as st

GENERADA = "generada"

TIPOS = ("Practice", "Qualifying", "Race")
COMPUESTOS = ("SOFT", "MEDIUM", "HARD", "INTERMEDIATE", "WET", "UNKNOWN")
EQUIPOS = tuple(f"Equipo {i}" for i in range(1, 12))
ESTADOS = ("Inactive", "Started", "Aborted", "Finished", "Finalised", "Ends")


def vuelta(ms: int) -> str:
    """Un tiempo de vuelta como lo escribe el feed: ``1:36.680``."""
    return f"{ms // 60000}:{ms // 1000 % 60:02d}.{ms % 1000:03d}"


def segundos(ms: int, signo: str = "") -> str:
    """Un tiempo corto como lo escribe el feed: ``29.268`` o ``+5.089``."""
    return f"{signo}{ms // 1000}.{ms % 1000:03d}"


acronimos = st.text("ABCDEFGHIJKLMNOPQRSTUVWXYZ", min_size=3, max_size=3)
vueltas_ms = st.integers(60_000, 140_000)
sectores_ms = st.integers(15_000, 50_000)


@st.composite
def _sector(draw) -> Dict[str, Any]:
    sector: Dict[str, Any] = {
        "Value": draw(st.one_of(st.just(""), sectores_ms.map(segundos))),
        "Status": 0,
        "OverallFastest": draw(st.booleans()),
        "PersonalFastest": draw(st.booleans()),
        "Stopped": False,
        "Segments": [{"Status": draw(st.sampled_from([0, 2048, 2049, 2051, 2064]))}
                     for _ in range(draw(st.integers(0, 10)))],
    }
    if draw(st.booleans()):
        sector["PreviousValue"] = draw(sectores_ms.map(segundos))
    return sector


@st.composite
def _stints(draw) -> List[Dict[str, Any]]:
    stints = []
    for _ in range(draw(st.integers(0, 4))):
        edad = draw(st.integers(0, 12))
        stints.append(
            {
                "Compound": draw(st.sampled_from(COMPUESTOS)),
                "New": draw(st.sampled_from(["true", "false"])),
                "TyresNotChanged": draw(st.sampled_from(["0", "1"])),
                "StartLaps": edad,
                "TotalLaps": edad + draw(st.integers(0, 30)),
                "LapFlags": 0,
            }
        )
    return stints


@st.composite
def _linea_de_tiempos(draw, numero: str, posicion: int, tipo: str, vueltas: int) -> Dict[str, Any]:
    lider = posicion == 1
    if tipo == "Race":
        hueco = "" if lider else draw(st.one_of(
            st.integers(1, 90_000).map(lambda ms: segundos(ms, "+")),
            st.integers(1, 3).map(lambda n: f"{n} L"),
        ))
    else:
        hueco = "" if lider else draw(st.integers(1, 5_000).map(lambda ms: segundos(ms, "+")))
    linea: Dict[str, Any] = {
        "RacingNumber": numero,
        "Line": posicion,
        "Position": str(posicion),
        "ShowPosition": True,
        "Status": 0,
        "InPit": draw(st.booleans()),
        "PitOut": draw(st.booleans()),
        "Retired": draw(st.booleans()),
        "Stopped": draw(st.booleans()),
        "NumberOfLaps": vueltas,
        "NumberOfPitStops": draw(st.integers(0, 4)),
        "LastLapTime": {
            "Value": draw(st.one_of(st.just(""), vueltas_ms.map(vuelta))),
            "Status": 0,
            "OverallFastest": draw(st.booleans()),
            "PersonalFastest": draw(st.booleans()),
        },
        "BestLapTime": {"Value": draw(st.one_of(st.just(""), vueltas_ms.map(vuelta))),
                        "Lap": draw(st.integers(1, 70))},
        "Sectors": draw(st.lists(_sector(), min_size=3, max_size=3)),
        "Speeds": {trampa: {"Value": str(draw(st.integers(180, 350))), "Status": 0,
                            "OverallFastest": False, "PersonalFastest": False}
                   for trampa in ("I1", "I2", "FL", "ST")},
    }
    if tipo == "Race":
        linea["GapToLeader"] = hueco
        linea["IntervalToPositionAhead"] = {"Value": hueco, "Catching": draw(st.booleans())}
    elif tipo == "Practice":
        linea["TimeDiffToFastest"] = hueco
        linea["TimeDiffToPositionAhead"] = hueco
    else:
        linea["KnockedOut"] = draw(st.booleans())
        linea["Cutoff"] = draw(st.booleans())
        linea["Stats"] = [{"TimeDiffToFastest": hueco, "TimeDifftoPositionAhead": hueco} for _ in range(3)]
        linea["BestLapTimes"] = [{"Value": draw(st.one_of(st.just(""), vueltas_ms.map(vuelta))),
                                  "Lap": draw(st.integers(1, 30))} for _ in range(3)]
    return linea


@st.composite
def foto_del_feed(draw, tipo: str | None = None) -> Dict[str, Any]:
    """Una foto completa del feed. Con ``tipo`` (``"Practice"``, ``"Qualifying"`` o
    ``"Race"``) la sesión es de ese tipo; sin él, de cualquiera de los tres."""
    tipo = tipo or draw(st.sampled_from(TIPOS))
    numeros = draw(st.lists(st.integers(1, 99).map(str), min_size=2, max_size=22, unique=True))
    tlas = draw(st.lists(acronimos, min_size=len(numeros), max_size=len(numeros), unique=True))
    orden = draw(st.permutations(numeros))
    posicion = {numero: i for i, numero in enumerate(orden, 1)}

    pilotos, tiempos, neumaticos, estadisticas = {}, {}, {}, {}
    for numero, tla in zip(numeros, tlas):
        stints = draw(_stints())
        completadas = sum(s["TotalLaps"] - s["StartLaps"] for s in stints)
        # A veces el coche lleva menos vueltas de las que suman sus stints: el tope de
        # `_feed_stints` tiene que tener trabajo.
        vueltas = max(0, completadas - draw(st.integers(0, 3)))
        pilotos[numero] = {
            "RacingNumber": numero,
            "Tla": tla,
            "BroadcastName": tla,
            "FirstName": tla.title(),
            "LastName": tla.title(),
            "FullName": f"{tla.title()} {tla.title()}",
            "Reference": tla,
            "PublicIdRight": tla,
            "Line": posicion[numero],
            "TeamName": draw(st.sampled_from(EQUIPOS)),
            "TeamColour": draw(st.sampled_from(["888888", "3671C6", "E8002D", "FF8000"])),
        }
        tiempos[numero] = draw(_linea_de_tiempos(numero, posicion[numero], tipo, vueltas))
        neumaticos[numero] = {"RacingNumber": numero, "Line": posicion[numero], "Stints": stints}
        estadisticas[numero] = {"RacingNumber": numero, "Line": posicion[numero],
                                "PersonalBestLapTime": {}, "BestSectors": [], "BestSpeeds": {}}

    timing: Dict[str, Any] = {"Lines": tiempos}
    if tipo == "Qualifying":
        timing["SessionPart"] = draw(st.integers(0, 3))
        timing["NoEntries"] = [20, 15, 10]
        timing["CutOffTime"] = draw(vueltas_ms.map(vuelta))
        timing["CutOffPercentage"] = "107"

    foto: Dict[str, Any] = {
        "SessionInfo": {
            "Key": draw(st.integers(1, 20_000)),
            "Type": tipo,
            "Name": {"Practice": "Practice 1", "Qualifying": "Qualifying", "Race": "Race"}[tipo],
            "Path": GENERADA,
            "StartDate": "2030-01-01T12:00:00",
            "EndDate": "2030-01-01T13:00:00",
            "GmtOffset": "00:00:00",
            "SessionStatus": draw(st.sampled_from(ESTADOS)),
            "ArchiveStatus": {"Status": "Generating"},
            "Meeting": {
                "Key": 1, "Number": 1, "Name": "Gran Premio de Prueba", "OfficialName": "Gran Premio de Prueba",
                "Location": "Pruebas", "Circuit": {"Key": 1, "ShortName": "Circuito de Prueba"},
                "Country": {"Key": 1, "Code": "XXX", "Name": "Pruebas"},
            },
        },
        "DriverList": pilotos,
        "TimingData": timing,
        "TimingAppData": {"Lines": neumaticos},
        "TimingStats": {"Withheld": False, "SessionType": tipo, "Lines": estadisticas},
        "TrackStatus": draw(st.sampled_from([
            {"Status": "1", "Message": "AllClear"}, {"Status": "2", "Message": "Yellow"},
            {"Status": "5", "Message": "Red"}])),
        "SessionStatus": {"Status": draw(st.sampled_from(ESTADOS))},
        "ExtrapolatedClock": {"Utc": "2030-01-01T12:30:00.000Z", "Remaining": "00:30:00",
                              "Extrapolating": draw(st.booleans())},
        "RaceControlMessages": {"Messages": draw(st.lists(st.fixed_dictionaries(
            {"Utc": st.just("2030-01-01T12:10:00"),
             "Category": st.sampled_from(["Flag", "Other", "Drs", "CarEvent"]),
             "Message": st.text(max_size=20)},
            optional={"Flag": st.sampled_from(["GREEN", "YELLOW", "RED", "CHEQUERED"]),
                      "Scope": st.sampled_from(["Track", "Sector", "Driver"])}), max_size=5))},
    }
    if tipo == "Race":
        total = draw(st.integers(1, 78))
        foto["LapCount"] = {"CurrentLap": draw(st.integers(1, total)), "TotalLaps": total}
    return foto
