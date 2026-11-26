"""``_feed_rows``: las reglas de la fila como propiedades, sobre fotos con la forma del feed
y campos sueltos o mal formados. Las fotos completas y coherentes, en ``test_generadas.py``.
"""

import json
import math

import pytest
from hypothesis import given
from hypothesis import strategies as st

from feed import _LIVE_TOPICS, _feed_rows, _feed_session

# Las claves de `Common.Types.LiveTimingRow`.
CLAVES = {
    "ltPosition",
    "ltCar",
    "ltDriver",
    "ltTeam",
    "ltGap",
    "ltInterval",
    "ltLastLap",
    "ltLastSectors",
    "ltStatus",
    "ltBestLap",
    "ltPartBestLap",
    "ltPartBests",
    "ltKnockedOut",
    "ltCutoff",
}


# ── Propiedades ───────────────────────────────────────────────────────────────

textos = st.one_of(
    st.text(max_size=8),
    st.sampled_from(["", "-", "+1.234", "1 L", "1L", "LAP 3", "1:30.000"]),
)
valores = st.one_of(textos, st.fixed_dictionaries({"Value": textos}))
posiciones = st.one_of(
    st.none(),
    st.integers(-3, 30),
    st.integers(1, 22).map(str),
    st.sampled_from(["", "x", "nan", "inf"]),
)
numeros = st.integers(1, 99).map(str)
tiempos_de_sector = st.sampled_from(["", " ", "27.241", "1:05.300", " 26.243 "])
sector = st.fixed_dictionaries({}, optional={"Value": textos, "PreviousValue": tiempos_de_sector})
sectores = st.one_of(
    st.lists(sector, max_size=4),
    st.dictionaries(st.sampled_from(["0", "1", "2", "3"]), sector, max_size=4),
)
lineas = st.fixed_dictionaries(
    {},
    optional={
        "Position": posiciones,
        "GapToLeader": textos,
        "IntervalToPositionAhead": valores,
        "LastLapTime": valores,
        "BestLapTime": valores,
        "Retired": st.booleans(),
        "Stopped": st.booleans(),
        "KnockedOut": st.booleans(),
        "Cutoff": st.booleans(),
        "Stats": st.lists(
            st.fixed_dictionaries(
                {}, optional={"TimeDiffToFastest": textos, "TimeDifftoPositionAhead": textos}
            ),
            max_size=3,
        ),
        "BestLapTimes": st.lists(st.fixed_dictionaries({}, optional={"Value": textos}), max_size=3),
        "Sectors": sectores,
    },
)
fotos = st.fixed_dictionaries(
    {
        "DriverList": st.dictionaries(
            numeros, st.fixed_dictionaries({}, optional={"Tla": textos, "TeamName": textos}), max_size=6
        ),
        "TimingData": st.fixed_dictionaries(
            {"Lines": st.dictionaries(numeros, lineas, max_size=8)},
            optional={"SessionPart": st.one_of(st.none(), st.integers(0, 4))},
        ),
    }
)


def con_posicion(linea):
    try:
        return math.isfinite(float(linea.get("Position")))
    except (TypeError, ValueError):
        return False


@given(fotos)
def test_cada_fila_lleva_las_claves_del_dto_y_se_serializa_sin_nan(foto):
    filas = _feed_rows(foto)
    assert all(set(fila) == CLAVES for fila in filas)
    json.dumps(filas, allow_nan=False)


@given(fotos)
def test_el_numero_es_el_de_su_linea_aunque_haya_acronimo(foto):
    lineas = foto["TimingData"]["Lines"]
    filas = _feed_rows(foto)
    assert sorted(fila["ltCar"] for fila in filas) == sorted(n for n, l in lineas.items() if con_posicion(l))
    for fila in filas:
        assert int(float(lineas[fila["ltCar"]]["Position"])) == fila["ltPosition"]


@given(fotos)
def test_las_filas_salen_por_posicion(foto):
    posiciones = [fila["ltPosition"] for fila in _feed_rows(foto)]
    assert posiciones == sorted(posiciones)


@given(fotos)
def test_sale_una_fila_por_coche_con_posicion(foto):
    lineas = foto["TimingData"]["Lines"].values()
    assert len(_feed_rows(foto)) == sum(1 for linea in lineas if con_posicion(linea))


@given(fotos)
def test_el_lider_lleva_leader_y_sin_intervalo(foto):
    for fila in _feed_rows(foto):
        if fila["ltPosition"] == 1:
            assert (fila["ltGap"], fila["ltInterval"]) == ("LEADER", "-")


@given(fotos)
def test_solo_retirado_o_parado_es_abandono_y_eliminado_no(foto):
    # Sin parrilla, cada fila lleva el número del coche y se casa con su línea.
    lineas = foto["TimingData"]["Lines"]
    for fila in _feed_rows({**foto, "DriverList": {}}):
        linea = lineas[fila["ltDriver"]]
        abandono = bool(linea.get("Retired") or linea.get("Stopped"))
        assert (fila["ltStatus"] == "Dnf") == abandono
        assert fila["ltKnockedOut"] == bool(linea.get("KnockedOut"))


tipos = st.sampled_from(["Practice", "Qualifying", "Race", "", "Otro"])


@given(fotos, tipos)
def test_en_libres_y_clasificacion_parado_no_es_abandono(foto, tipo):
    lineas = foto["TimingData"]["Lines"]
    for fila in _feed_rows({**foto, "DriverList": {}, "SessionInfo": {"Type": tipo}}):
        linea = lineas[fila["ltDriver"]]
        cuenta_parado = tipo not in ("Practice", "Qualifying")
        abandono = bool(linea.get("Retired") or (cuenta_parado and linea.get("Stopped")))
        assert (fila["ltStatus"] == "Dnf") == abandono


def test_el_12_parado_en_la_q_de_baku_sigue_en_pista_y_en_carrera_abandona():
    # El #12 de la Q del 2026-09-25: `Stopped` 13 min y después corrió la Q2.
    foto = {
        "DriverList": {"12": {"Tla": "ANT"}},
        "TimingData": {"Lines": {"12": {"Position": "5", "Stopped": True, "Retired": False}}},
    }

    def estado(tipo):
        return _feed_rows({**foto, "SessionInfo": {"Type": tipo}})[0]["ltStatus"]

    assert estado("Qualifying") == "Running"
    assert estado("Practice") == "Running"
    assert estado("Race") == "Dnf"
    assert _feed_rows(foto)[0]["ltStatus"] == "Dnf"


@given(fotos)
def test_los_sectores_de_la_ultima_son_los_previousvalue_de_sus_tres_sectores(foto):
    lineas = foto["TimingData"]["Lines"]
    for fila in _feed_rows({**foto, "DriverList": {}}):
        sectores = lineas[fila["ltDriver"]].get("Sectors")
        if sectores is None:
            assert fila["ltLastSectors"] == []
            continue
        if isinstance(sectores, list):
            sectores = {str(i): s for i, s in enumerate(sectores)}
        esperado = [(sectores.get(str(i)) or {}).get("PreviousValue", "").strip() or "-" for i in range(3)]
        assert fila["ltLastSectors"] == esperado


# ── El topic SessionStatus ────────────────────────────────────────────────────


def test_el_topic_sessionstatus_se_pide():
    assert "SessionStatus" in _LIVE_TOPICS


def test_el_topic_viaja_crudo_y_aparte_del_campo_de_sessioninfo():
    snapshot = {
        "SessionInfo": {"Type": "Race", "SessionStatus": "Started"},
        "SessionStatus": {"Status": "Aborted", "Started": "Started"},
    }
    session = _feed_session(snapshot)
    assert session["siState"] == "Started"
    assert session["siTopicStatus"] == "Aborted"


@pytest.mark.parametrize("topic", [None, "Aborted", {}, {"Status": ""}, {"Started": "Started"}])
def test_sin_estado_en_el_topic_no_va_la_clave(topic):
    snapshot = {"SessionInfo": {"Type": "Race", "SessionStatus": "Started"}}
    if topic is not None:
        snapshot["SessionStatus"] = topic
    assert "siTopicStatus" not in _feed_session(snapshot)
