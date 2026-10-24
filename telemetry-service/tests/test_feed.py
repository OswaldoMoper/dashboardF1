"""``_feed_rows``: la salida guardada sobre fotos reales y las reglas de la fila como
propiedades.

Las fotos y su salida esperada las escribe ``fotos.py``; un cambio intencionado de la
salida se regenera con ``fotos.py --esperado`` y se revisa en el diff.
"""

import json
import math
from pathlib import Path

import pytest
from hypothesis import given
from hypothesis import strategies as st

from feed import _feed_live, _feed_rows, _feed_session

AQUI = Path(__file__).resolve().parent
FOTOS = sorted((AQUI / "fotos").glob("*.json"))

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


def test_cada_foto_tiene_su_salida_esperada():
    esperadas = sorted(p.name for p in (AQUI / "esperado").glob("*.json"))
    assert FOTOS, "no hay fotos"
    assert [p.name for p in FOTOS] == esperadas


@pytest.mark.parametrize("foto", FOTOS, ids=[p.stem for p in FOTOS])
def test_la_salida_de_una_foto_real_no_cambia(foto):
    esperada = json.loads((AQUI / "esperado" / foto.name).read_text(encoding="utf-8"))
    assert _feed_rows(json.loads(foto.read_text(encoding="utf-8"))) == esperada


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


# ── La respuesta del directo ──────────────────────────────────────────────────


@pytest.mark.parametrize("foto", FOTOS, ids=[p.stem for p in FOTOS])
def test_la_respuesta_del_directo_es_la_sesion_y_las_filas_de_la_misma_foto(foto):
    snapshot = json.loads(foto.read_text(encoding="utf-8"))
    assert _feed_live(snapshot) == {
        "session": _feed_session(snapshot),
        "rows": _feed_rows(snapshot),
    }
