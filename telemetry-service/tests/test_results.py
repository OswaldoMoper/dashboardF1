"""``results.session_results``: la clasificación de FastF1 con la forma de OpenF1
``/session_result``, con filas de São Paulo 2026 (carrera, Q y FP1) y lo que OpenF1 dio
de esas mismas sesiones. La descalificación no salió allí: es inventada."""

from hypothesis import given
from hypothesis import strategies as st

from results import session_results, session_summary
from stints import reached_end


def fila(number, position=None, classified="", time=None, laps=None, q=(None, None, None), best=None,
         lap_count=0):
    return {"number": number, "position": position, "classified": classified, "time": time, "laps": laps,
            "q": list(q), "best": best, "lap_count": lap_count}


def por_coche(salida):
    return {r["driver_number"]: r for r in salida}


CARRERA = [
    fila("3", 2.0, "2", 14.602, 71),
    fila("1", 1.0, "1", 5723.504, 71),
    fila("44", 9.0, "9", 4.427, 70),
    fila("11", 18.0, "18", 27.12, 69),
    fila("18", 21.0, "R", None, 30),
    fila("77", 22.0, "W", None, 0),
]


def test_carrera_el_lider_lleva_el_tiempo_total_y_hueco_cero():
    r = por_coche(session_results("Race", CARRERA))[1]
    assert (r["position"], r["number_of_laps"], r["duration"], r["gap_to_leader"]) == (1, 71, 5723.504, 0)


def test_carrera_en_la_vuelta_del_lider_el_tiempo_es_el_del_lider_mas_su_hueco():
    r = por_coche(session_results("Race", CARRERA))[3]
    assert (r["position"], r["duration"], r["gap_to_leader"]) == (2, 5738.106, 14.602)


def test_carrera_un_doblado_no_tiene_tiempo_y_su_hueco_son_las_vueltas():
    salida = por_coche(session_results("Race", CARRERA))
    assert [(salida[n]["duration"], salida[n]["gap_to_leader"]) for n in (44, 11)] == [
        (None, "+1 LAP"), (None, "+2 LAPS")]


def test_carrera_abandono_y_no_salida_sin_posicion_y_con_su_bandera():
    salida = por_coche(session_results("Race", CARRERA))
    assert [(salida[n]["position"], salida[n]["dnf"], salida[n]["dns"], salida[n]["dsq"]) for n in (18, 77)] == [
        (None, True, False, False), (None, False, True, False)]


def test_carrera_descalificado_d_o_e():
    salida = por_coche(session_results("Race", [fila("1", 1.0, "1", 5723.504, 71), fila("16", 3.0, "D", None, 71),
                                                fila("4", 4.0, "E", None, 71)]))
    assert [(salida[n]["position"], salida[n]["dsq"]) for n in (16, 4)] == [(None, True), (None, True)]


def test_la_clasificacion_va_en_orden_y_los_no_clasificados_al_final():
    assert [r["driver_number"] for r in session_results("Race", CARRERA)] == [1, 3, 44, 11, 18, 77]


def test_el_sprint_se_lee_como_la_carrera():
    assert session_results("Sprint", CARRERA) == session_results("Race", CARRERA)


QUALY = [
    fila("1", 1.0, "1.0", q=(90.939, 89.207, 87.47), lap_count=24),
    fila("63", 2.0, "2.0", q=(91.206, 86.745, 87.674), lap_count=23),
    fila("5", 22.0, "N", q=(101.564, None, None), lap_count=5),
]


def test_qualy_el_tiempo_son_las_tres_partes_y_el_hueco_contra_el_mejor_de_cada_una():
    salida = por_coche(session_results("Qualifying", QUALY))
    assert [(salida[n]["duration"], salida[n]["gap_to_leader"]) for n in (1, 63)] == [
        ([90.939, 89.207, 87.47], [0.0, 2.462, 0.0]),
        ([91.206, 86.745, 87.674], [0.267, 0.0, 0.204]),
    ]


def test_qualy_la_posicion_es_la_de_fastf1_aunque_no_este_clasificado():
    r = por_coche(session_results("Qualifying", QUALY))[5]
    assert (r["position"], r["number_of_laps"], r["gap_to_leader"], r["dnf"]) == (22, 5, [10.625, None, None], False)


def test_la_sprint_quali_se_lee_como_la_qualy():
    assert session_results("Sprint Qualifying", QUALY) == session_results("Qualifying", QUALY)


LIBRES = [
    fila("12", best=71.799, lap_count=32),
    fila("98", best=74.966, lap_count=7),
    fila("1", best=71.717, lap_count=33),
    fila("30", lap_count=0),
]


def test_libres_por_la_mejor_vuelta_con_el_hueco_al_mas_rapido():
    salida = session_results("Practice 1", LIBRES)
    assert [(r["driver_number"], r["position"], r["duration"], r["gap_to_leader"]) for r in salida] == [
        (1, 1, 71.717, 0.0), (12, 2, 71.799, 0.082), (98, 3, 74.966, 3.249), (30, None, None, None)]


def test_sin_filas_nada():
    assert [session_results(kind, []) for kind in ("Race", "Qualifying", "Practice 2")] == [[], [], []]


@given(st.lists(st.floats(min_value=60, max_value=200, allow_nan=False), min_size=1, max_size=22, unique=True))
def test_libres_las_posiciones_son_de_una_en_una_y_el_mas_rapido_tiene_hueco_cero(bests):
    salida = session_results("Practice 3", [fila(str(i + 1), best=b) for i, b in enumerate(bests)])
    assert [r["position"] for r in salida] == list(range(1, len(bests) + 1))
    assert salida[0]["gap_to_leader"] == 0.0
    assert [r["duration"] for r in salida] == sorted(bests)


# ``session_summary``: de qué sesión se habla, para /fastf1/session.


def test_resumen_con_nombres_y_finished():
    estados = ["Inactive", "Started", "Aborted", "Started", "Finished", "Finalised", "Ends"]
    assert session_summary("São Paulo Grand Prix", "Race", estados) == {
        "meeting": "São Paulo Grand Prix", "name": "Race", "finished": True}


def test_resumen_de_una_sesion_cortada_o_no_corrida_sin_finished():
    assert [session_summary("Mexico City Grand Prix", "Race", s)["finished"] for s in (["Started", "Aborted"], [])] == [
        False, False]


def test_finished_es_llegar_al_final_del_archivo_como_en_los_stints():
    # Una Q cortada tras la Q1 trae Finished y no acabó; una carrera dada por acabada tras una roja no lo trae.
    q_cortada = ["Inactive", "Started", "Finished", "Inactive"]
    roja_final = ["Inactive", "Started", "Aborted", "Finalised", "Ends"]
    assert [session_summary("", "", s)["finished"] for s in (q_cortada, roja_final, ["Ends"])] == [False, True, True]


@given(st.lists(st.sampled_from(["Inactive", "Started", "Aborted", "Finished", "Finalised", "Ends", "Otro"])))
def test_finished_y_los_stints_dicen_lo_mismo(estados):
    assert session_summary("", "", estados)["finished"] == reached_end(estados)


def test_resumen_sin_dato_sale_vacio():
    assert [session_summary(v, v, [])["meeting"] for v in (None, float("nan"), "nan", "None", "  ")] == [""] * 5
