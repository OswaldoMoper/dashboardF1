"""``stints.session_stints`` y ``stints.complete``: los stints de FastF1 con la forma de
OpenF1 ``/stints``, con casos de las carreras de 2026 (Australia, México, São Paulo) y los
estados de sus sesiones tal como los guarda la caché."""

from hypothesis import given
from hypothesis import strategies as st

from stints import complete, cut, session_stints


def vuelta(number, lap, stint, compound="MEDIUM", tyre_life=None):
    return {"number": number, "lap": lap, "stint": stint, "compound": compound, "tyre_life": tyre_life}


def tramo(number, desde, hasta, stint, compound, vida_inicial):
    return [vuelta(number, n, stint, compound, float(vida_inicial + n - desde)) for n in range(desde, hasta + 1)]


def por_tramo(salida):
    return [(s["driver_number"], s["compound"], s["lap_start"], s["lap_end"], s["tyre_age_at_start"])
            for s in salida]


# Australia: el 1 entra en boxes en la 11 y sale en la 12 (OpenF1 pone el cambio una
# vuelta antes); FastF1 numera el stint y el cambio cae en la vuelta buena.
AUSTRALIA_1 = tramo("1", 1, 11, 1.0, "MEDIUM", 1) + tramo("1", 12, 58, 2.0, "HARD", 1)

ESTADOS_SAO_PAULO = ["Inactive", "Started", "Finished", "Finalised", "Ends"]
ESTADOS_MEXICO = ["Started"]
ESTADOS_Q = ["Inactive", "Started", "Finished", "Inactive", "Started", "Finished",
             "Inactive", "Started", "Finished", "Finalised", "Ends"]


def test_el_cambio_de_stint_cae_en_la_vuelta_en_que_fastf1_cambia_el_numero():
    assert por_tramo(session_stints(AUSTRALIA_1)) == [(1, "MEDIUM", 1, 11, 0), (1, "HARD", 12, 58, 0)]


def test_la_vida_al_empezar_es_la_de_la_primera_vuelta_menos_uno():
    usado = tramo("16", 20, 40, 2.0, "HARD", 5)
    assert por_tramo(session_stints(usado)) == [(16, "HARD", 20, 40, 4)]


def test_el_mismo_compuesto_tras_una_parada_es_otro_stint():
    dos = tramo("4", 1, 20, 1.0, "HARD", 1) + tramo("4", 21, 50, 2.0, "HARD", 1)
    assert por_tramo(session_stints(dos)) == [(4, "HARD", 1, 20, 0), (4, "HARD", 21, 50, 0)]


def test_un_abandono_acaba_en_su_ultima_vuelta_de_fastf1():
    assert por_tramo(session_stints(tramo("18", 1, 31, 1.0, "SOFT", 1))) == [(18, "SOFT", 1, 31, 0)]


def test_sin_vida_en_la_primera_vuelta_la_vida_al_empezar_es_nula():
    sin_vida = [vuelta("14", 32, 3.0, "SOFT", None)] + tramo("14", 33, 45, 3.0, "SOFT", 2)
    assert session_stints(sin_vida)[0]["tyre_age_at_start"] is None


def test_un_compuesto_desconocido_sale_nulo():
    for hueco in ("None", "", None, float("nan")):
        assert session_stints([vuelta("11", 22, 2.0, hueco, 1.0)])[0]["compound"] is None


def test_una_vuelta_sin_numero_o_sin_stint_no_entra():
    sueltas = [vuelta("1", None, 1.0), vuelta("1", 3, float("nan")), vuelta("1", 4, 1.0, "SOFT", 1.0)]
    assert por_tramo(session_stints(sueltas)) == [(1, "SOFT", 4, 4, 0)]


def test_vueltas_desordenadas_salen_por_su_numero():
    desorden = list(reversed(tramo("44", 1, 5, 1.0, "SOFT", 3)))
    assert por_tramo(session_stints(desorden)) == [(44, "SOFT", 1, 5, 2)]


def test_los_coches_salen_por_numero_y_cada_uno_por_stint():
    mezcla = tramo("44", 1, 3, 2.0, "HARD", 1) + tramo("1", 1, 3, 1.0, "SOFT", 1) + tramo("44", 1, 3, 1.0, "SOFT", 1)
    assert [(s["driver_number"], s["compound"]) for s in session_stints(mezcla)] == [
        (1, "SOFT"), (44, "SOFT"), (44, "HARD")]


def test_sin_vueltas_no_hay_stints():
    assert session_stints([]) == []


def test_sao_paulo_llego_entera():
    assert complete(ESTADOS_SAO_PAULO, 71, 71)


def test_mexico_cortada_por_las_dos_razones():
    assert not complete(ESTADOS_MEXICO, 56, 71)


def test_cortada_solo_por_las_vueltas():
    assert not complete(ESTADOS_SAO_PAULO, 56, 71)


def test_cortada_solo_por_el_estado():
    assert not complete(ESTADOS_MEXICO, 71, 71)


def test_una_q_sin_vueltas_en_el_resultado_cuenta_solo_el_estado():
    assert complete(ESTADOS_Q, 23, None)


def test_una_q_cortada_tras_la_q1_no_llego_entera():
    assert not complete(["Inactive", "Started", "Finished", "Inactive", "Started"], 23, None)
    assert cut(["Inactive", "Started", "Finished", "Inactive", "Started"], 23, None) == {"lastLap": 23, "laps": None}


def test_una_q_con_la_q3_suspendida_y_dada_por_acabada_llego_entera():
    assert complete(["Inactive", "Started", "Finished", "Inactive", "Started", "Finished",
                     "Inactive", "Started", "Aborted", "Finalised", "Ends"], 18, None)


def test_una_carrera_acabada_con_bandera_roja_sin_reanudar_llego_entera():
    assert complete(["Inactive", "Started", "Aborted", "Finalised", "Ends"], 44, 44)


def test_basta_uno_de_los_dos_finales():
    assert complete(["Started", "Finished", "Finalised"], 71, 71)
    assert complete(["Started", "Finished", "Ends"], 71, 71)
    assert not complete(["Started", "Finished"], 71, 71)


def test_sin_ninguna_vuelta_no_llego_entera():
    assert not complete(ESTADOS_SAO_PAULO, None, 71)


def test_mexico_acaba_en_la_56_de_71():
    assert cut(ESTADOS_MEXICO, 56, 71) == {"lastLap": 56, "laps": 71}


def test_entera_no_tiene_corte():
    assert cut(ESTADOS_SAO_PAULO, 71, 71) is None
    assert cut(ESTADOS_Q, 23, None) is None


def test_cortada_solo_por_el_estado_no_dice_de_cuantas():
    assert cut(ESTADOS_MEXICO, 71, 71) == {"lastLap": 71, "laps": None}


def test_sin_vueltas_en_el_resultado_no_dice_de_cuantas():
    assert cut(ESTADOS_MEXICO, 23, None) == {"lastLap": 23, "laps": None}


def test_sin_ninguna_vuelta_no_hay_corte_que_decir():
    assert cut(ESTADOS_MEXICO, None, 71) is None


@given(st.lists(st.sampled_from(["Inactive", "Started", "Finished", "Aborted", "Finalised", "Ends"]), max_size=6),
       st.one_of(st.none(), st.integers(1, 80)), st.one_of(st.none(), st.integers(1, 80)))
def test_hay_corte_si_y_solo_si_no_llego_entera_y_tiene_vueltas(estados, ultima, del_resultado):
    hay = cut(estados, ultima, del_resultado)
    assert (hay is not None) == (ultima is not None and not complete(estados, ultima, del_resultado))
    if hay is not None and hay["laps"] is not None:
        assert hay["lastLap"] < hay["laps"]


@given(st.lists(st.tuples(st.sampled_from(["1", "4", "44"]), st.integers(1, 70), st.integers(1, 5)),
                max_size=60, unique_by=lambda t: (t[0], t[1])))
def test_cada_vuelta_cae_en_el_stint_de_su_coche_y_su_numero(filas):
    salida = session_stints([vuelta(n, lap, float(stint), "SOFT", 1.0) for n, lap, stint in filas])
    claves = {(int(n), stint) for n, _, stint in filas}
    assert len(salida) == len(claves)
    for n, lap, _ in filas:
        assert any(s["driver_number"] == int(n) and s["lap_start"] <= lap <= s["lap_end"] for s in salida)
