"""``_feed_stints``: una foto real contra lo que da OpenF1, un trozo de grabación con un
stint sin vueltas completadas, y las reglas de la cuenta como propiedades."""

import json
from pathlib import Path

from hypothesis import given
from hypothesis import strategies as st

import feed

AQUI = Path(__file__).resolve().parent

CLAVES = {
    "tsDriver",
    "tsCar",
    "tsCompound",
    "tsStartLap",
    "tsEndLap",
    "tsLaps",
    "tsAge",
    "tsNew",
    "tsSameSet",
}


def tramos(stints, coche):
    return [(s["tsCompound"], s["tsStartLap"], s["tsEndLap"]) for s in stints if s["tsCar"] == coche]


def test_la_carrera_del_13_de_septiembre_da_los_stints_de_openf1():
    # OpenF1, misma sesión (11369): 47 stints, y el coche 1 MEDIUM 1–15 y HARD 16–57.
    foto = json.loads((AQUI / "fotos" / "carrera-2026-09-13-final.json").read_text(encoding="utf-8"))
    stints = feed._feed_stints(foto)
    assert len(stints) == 47
    assert tramos(stints, "1") == [("MEDIUM", 1, 15), ("HARD", 16, 57)]
    assert {s["tsDriver"] for s in stints if s["tsCar"] == "1"} == {"NOR"}


def test_el_stint_sin_vueltas_completadas_sale_y_acaba_antes_de_empezar():
    # El #6 en la sprint de Singapur (2026-10-10), plegado tras el reinicio: vuelve a pista
    # con el mismo juego y la vuelta 3 no se completa (OpenF1 la cuenta: 3–3).
    foto = {
        "TimingAppData": {
            "Lines": {
                "6": {
                    "RacingNumber": "6",
                    "Stints": [
                        {"LapFlags": 0, "Compound": "INTERMEDIATE", "New": "true", "TyresNotChanged": "0",
                         "TotalLaps": 2, "StartLaps": 0, "LapTime": "2:32.187", "LapNumber": 2},
                        {"LapFlags": 0, "Compound": "INTERMEDIATE", "New": "false", "TyresNotChanged": "1",
                         "TotalLaps": 2, "StartLaps": 2},
                    ],
                }
            }
        }
    }
    stints = feed._feed_stints(foto)
    assert tramos(stints, "6") == [("INTERMEDIATE", 1, 2), ("INTERMEDIATE", 3, 2)]
    assert [(s["tsLaps"], s["tsAge"], s["tsNew"], s["tsSameSet"]) for s in stints] == [
        (2, 0, True, False),
        (0, 2, False, True),
    ]
    assert {s["tsDriver"] for s in stints} == {"6"}


# ── Propiedades ───────────────────────────────────────────────────────────────

compuestos = st.sampled_from(["SOFT", "MEDIUM", "HARD", "INTERMEDIATE", "WET", "UNKNOWN"])
numeros = st.integers(1, 99).map(str)


@st.composite
def un_stint(draw):
    edad = draw(st.integers(0, 20))
    total = edad + draw(st.integers(0, 40))
    como_texto = draw(st.booleans())
    return {
        "Compound": draw(compuestos),
        "New": draw(st.sampled_from(["true", "false"])),
        "TyresNotChanged": draw(st.sampled_from(["0", "1"])),
        "StartLaps": str(edad) if como_texto else edad,
        "TotalLaps": str(total) if como_texto else total,
    }


fotos = st.fixed_dictionaries(
    {
        "TimingAppData": st.fixed_dictionaries(
            {
                "Lines": st.dictionaries(
                    numeros, st.fixed_dictionaries({"Stints": st.lists(un_stint(), max_size=6)}), max_size=8
                )
            }
        )
    },
    optional={
        "DriverList": st.dictionaries(numeros, st.fixed_dictionaries({}, optional={"Tla": st.text(max_size=4)}))
    },
)


def por_coche(foto):
    return foto["TimingAppData"]["Lines"]


@given(fotos)
def test_un_stint_por_entrada_en_su_orden_y_los_coches_por_numero(foto):
    stints = feed._feed_stints(foto)
    lineas = por_coche(foto)
    assert [s["tsCar"] for s in stints] == [
        n for n in sorted(lineas, key=int) for _ in lineas[n]["Stints"]
    ]
    for n, linea in lineas.items():
        assert [s["tsCompound"] for s in stints if s["tsCar"] == n] == [e["Compound"] for e in linea["Stints"]]


@given(fotos)
def test_cada_stint_empieza_justo_despues_de_donde_acabo_el_anterior(foto):
    stints = feed._feed_stints(foto)
    for n in por_coche(foto):
        suyos = [s for s in stints if s["tsCar"] == n]
        inicios = [s["tsStartLap"] for s in suyos]
        assert inicios == [1 + sum(s["tsLaps"] for s in suyos[:k]) for k in range(len(suyos))]
        assert all(s["tsEndLap"] == s["tsStartLap"] + s["tsLaps"] - 1 for s in suyos)


@given(fotos)
def test_las_vueltas_son_las_completadas_y_la_edad_la_del_juego(foto):
    stints = feed._feed_stints(foto)
    for n, linea in por_coche(foto).items():
        suyos = [s for s in stints if s["tsCar"] == n]
        for s, e in zip(suyos, linea["Stints"]):
            assert s["tsLaps"] == int(e["TotalLaps"]) - int(e["StartLaps"])
            assert s["tsAge"] == int(e["StartLaps"])
            assert s["tsNew"] == (e["New"] == "true")
            assert s["tsSameSet"] == (e["TyresNotChanged"] == "1")


@given(fotos)
def test_la_lista_y_el_diccionario_por_indice_dan_lo_mismo(foto):
    plegada = json.loads(json.dumps(foto))
    for linea in por_coche(plegada).values():
        linea["Stints"] = {str(i): e for i, e in enumerate(linea["Stints"])}
    assert feed._feed_stints(plegada) == feed._feed_stints(foto)


@given(fotos)
def test_cada_stint_lleva_sus_claves_y_se_serializa_sin_nan(foto):
    stints = feed._feed_stints(foto)
    assert all(set(s) == CLAVES for s in stints)
    json.dumps(stints, allow_nan=False)
