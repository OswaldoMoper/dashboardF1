"""``_feed_live`` sobre fotos completas generadas (``generadores.foto_del_feed``): lo que la
respuesta del directo tiene que cumplir con cualquier parrilla y cualquier tipo de sesión."""

import json

from hypothesis import given
from hypothesis import strategies as st

import generadores
from feed import _LIVE_TOPICS, _feed_live, _feed_rows, _feed_session, _feed_stints
from generadores import foto_del_feed


def lineas(foto):
    return foto["TimingData"]["Lines"]


@given(foto_del_feed())
def test_la_foto_generada_trae_los_temas_que_se_piden_y_se_dice_generada(foto):
    assert set(_LIVE_TOPICS) - {"LapCount"} <= set(foto)
    assert foto["SessionInfo"]["Path"] == generadores.GENERADA


@given(foto_del_feed())
def test_la_respuesta_del_directo_es_la_sesion_las_filas_y_los_stints_de_la_misma_foto(foto):
    assert _feed_live(foto) == {
        "session": _feed_session(foto),
        "rows": _feed_rows(foto),
        "stints": _feed_stints(foto),
    }


@given(foto_del_feed())
def test_la_respuesta_se_serializa_sin_nan(foto):
    json.dumps(_feed_live(foto), allow_nan=False)


@given(foto_del_feed())
def test_una_fila_por_coche_en_orden_de_posicion_con_su_piloto_y_su_equipo(foto):
    filas = _feed_rows(foto)
    assert [f["ltPosition"] for f in filas] == list(range(1, len(lineas(foto)) + 1))
    for fila in filas:
        piloto = foto["DriverList"][fila["ltCar"]]
        assert lineas(foto)[fila["ltCar"]]["Position"] == str(fila["ltPosition"])
        assert (fila["ltDriver"], fila["ltTeam"]) == (piloto["Tla"], piloto["TeamName"])


@given(foto_del_feed())
def test_el_lider_lleva_leader_y_sin_intervalo_y_nadie_mas(foto):
    filas = _feed_rows(foto)
    assert (filas[0]["ltGap"], filas[0]["ltInterval"]) == ("LEADER", "-")
    assert all(f["ltGap"] != "LEADER" for f in filas[1:])


@given(foto_del_feed("Race"))
def test_en_carrera_el_hueco_y_el_intervalo_son_los_de_la_linea(foto):
    for fila in _feed_rows(foto)[1:]:
        linea = lineas(foto)[fila["ltCar"]]
        assert fila["ltGap"] == (linea["GapToLeader"] or "-")
        assert fila["ltInterval"] == (linea["IntervalToPositionAhead"]["Value"] or "-")


@given(foto_del_feed("Qualifying"))
def test_en_clasificacion_el_hueco_es_el_de_la_parte_en_curso(foto):
    parte = foto["TimingData"]["SessionPart"]
    for fila in _feed_rows(foto)[1:]:
        stats = lineas(foto)[fila["ltCar"]]["Stats"]
        esperado = stats[parte - 1 if 1 <= parte <= len(stats) else 0]["TimeDiffToFastest"] or "-"
        assert fila["ltGap"] == esperado


@given(foto_del_feed())
def test_retirado_es_abandono_y_parado_solo_en_carrera(foto):
    carrera = foto["SessionInfo"]["Type"] == "Race"
    for fila in _feed_rows(foto):
        linea = lineas(foto)[fila["ltCar"]]
        abandono = linea["Retired"] or (carrera and linea["Stopped"])
        assert fila["ltStatus"] == ("Dnf" if abandono else "Running")


@given(foto_del_feed())
def test_un_stint_por_entrada_y_ningun_coche_pasa_de_sus_vueltas(foto):
    stints = _feed_stints(foto)
    neumaticos = foto["TimingAppData"]["Lines"]
    assert len(stints) == sum(len(linea["Stints"]) for linea in neumaticos.values())
    for numero, linea in lineas(foto).items():
        del_coche = [s for s in stints if s["tsCar"] == numero]
        assert {s["tsDriver"] for s in del_coche} <= {foto["DriverList"][numero]["Tla"]}
        assert sum(s["tsLaps"] for s in del_coche) <= linea["NumberOfLaps"]


@given(st.sampled_from(generadores.TIPOS).flatmap(lambda tipo: foto_del_feed(tipo).map(lambda f: (tipo, f))))
def test_la_sesion_dice_su_tipo_y_solo_trae_los_campos_de_ese_tipo(tipo_y_foto):
    tipo, foto = tipo_y_foto
    sesion = _feed_session(foto)
    assert sesion["siType"] == tipo
    assert sesion["siCircuit"] == foto["SessionInfo"]["Meeting"]["Circuit"]["ShortName"]
    assert ("siCurrentLap" in sesion) == (tipo == "Race")
    assert ("siPart" in sesion) == (tipo == "Qualifying")
