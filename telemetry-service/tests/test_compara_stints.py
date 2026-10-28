"""``compara_stints.clasificar``: el tipo de cada pareja de stints de un coche, con los
casos medidos en Singapur y uno inventado por cada tipo que no salió allí."""

import json

import compara_stints


def feed(*tramos):
    return [{"tsCompound": c, "tsStartLap": a, "tsEndLap": b} for c, a, b in tramos]


def openf1(*tramos):
    return [{"compound": c, "lap_start": a, "lap_end": b} for c, a, b in tramos]


def test_iguales_y_la_ultima_vuelta_no_completada_del_coche_1_en_la_clasificacion():
    # Clasificación de Singapur (11384): la vuelta 24 no tiene tiempo ni S3.
    tipos = compara_stints.clasificar(
        feed(("SOFT", 1, 7), ("SOFT", 8, 10), ("SOFT", 11, 15), ("SOFT", 16, 18), ("SOFT", 19, 21),
             ("SOFT", 22, 23)),
        openf1(("SOFT", 1, 7), ("SOFT", 8, 10), ("SOFT", 11, 15), ("SOFT", 16, 18), ("SOFT", 19, 21),
               ("SOFT", 22, 24)),
        sin_tiempo={24},
        cortada=False,
    )
    assert tipos == ["igual"] * 5 + ["vuelta no completada"]


def test_el_arrastre_de_las_vueltas_no_completadas_del_coche_1_en_la_sprint_quali():
    # Sprint quali de Singapur (11379): las vueltas 2 y 15 no tienen tiempo ni S3.
    tipos = compara_stints.clasificar(
        feed(("MEDIUM", 1, 1), ("MEDIUM", 2, 4), ("MEDIUM", 5, 8), ("SOFT", 9, 13)),
        openf1(("MEDIUM", 1, 2), ("MEDIUM", 3, 5), ("MEDIUM", 6, 9), ("SOFT", 10, 15)),
        sin_tiempo={2, 15},
        cortada=False,
    )
    assert tipos == ["vuelta no completada", "arrastre", "arrastre", "vuelta no completada"]


def test_el_ultimo_stint_de_una_grabacion_sin_finished_es_grabacion_cortada():
    # Sprint de Singapur (11383), coche 1: la grabación acaba en `Started`.
    tramos_feed = feed(("INTERMEDIATE", 1, 2), ("INTERMEDIATE", 3, 3), ("INTERMEDIATE", 4, 4),
                       ("INTERMEDIATE", 5, 16))
    tramos_openf1 = openf1(("INTERMEDIATE", 1, 2), ("INTERMEDIATE", 3, 3), ("INTERMEDIATE", 4, 4),
                           ("INTERMEDIATE", 5, 20))
    assert compara_stints.clasificar(tramos_feed, tramos_openf1, sin_tiempo=set(), cortada=True) == [
        "igual", "igual", "igual", "grabación cortada"
    ]
    assert compara_stints.clasificar(tramos_feed, tramos_openf1, sin_tiempo=set(), cortada=False) == [
        "igual", "igual", "igual", "longitud distinta"
    ]


def test_falta_en_un_lado():
    dos = feed(("MEDIUM", 1, 10), ("HARD", 11, 30))
    uno = openf1(("MEDIUM", 1, 10))
    assert compara_stints.clasificar(dos, uno, sin_tiempo=set(), cortada=False) == ["igual", "falta en OpenF1"]
    assert compara_stints.clasificar(
        feed(("MEDIUM", 1, 10)), openf1(("MEDIUM", 1, 10), ("HARD", 11, 30)), sin_tiempo=set(), cortada=False
    ) == ["igual", "falta en el feed"]


def test_otro_compuesto_va_antes_que_la_grabacion_cortada():
    tipos = compara_stints.clasificar(
        feed(("MEDIUM", 1, 10), ("SOFT", 11, 14)),
        openf1(("MEDIUM", 1, 10), ("HARD", 11, 20)),
        sin_tiempo=set(),
        cortada=True,
    )
    assert tipos == ["igual", "otro compuesto"]


def test_fuera_de_la_sesion_el_coche_sin_reinicio_de_la_p1_de_austin():
    # P1 de Austin (11389): HER (#25) sustituye a PER (#11), que no recibe el reinicio.
    assert compara_stints.fuera_de_la_sesion({"1", "11", "25"}, {"1", "25"}) == {"11"}
    # Una grabación que empieza con la sesión en marcha no ve el reinicio: no se aparta nadie.
    assert compara_stints.fuera_de_la_sesion({"1", "11"}, set()) == set()


def test_leer_cuenta_los_reiniciados_sin_la_foto_inicial(tmp_path):
    # El `Stints: []` del #11 en la foto inicial no es un reinicio: es su estado al conectarse.
    foto = json.dumps({"Lines": {"1": {"Stints": [{"Compound": "SOFT"}]}, "11": {"Stints": []}}})
    grabacion = tmp_path / "grabacion.txt"
    grabacion.write_text(
        "\n".join(repr(m) for m in [
            ["TimingAppData", foto, ""],
            ["TimingAppData", {"Lines": {"1": {"Stints": []}}}, "2026-10-23T17:30:04.1Z"],
            ["TimingAppData", {"Lines": {"1": {"Stints": [{"Compound": "MEDIUM"}]}}}, "2026-10-23T17:31:00.0Z"],
        ]) + "\n",
        encoding="utf-8",
    )
    _, _, reiniciados = compara_stints.leer(grabacion)
    assert reiniciados == {"1"}


def test_lo_que_no_se_explica():
    # Una más larga sin la vuelta vacía; misma longitud corrida sin nada antes que la arrastre.
    assert compara_stints.clasificar(
        feed(("SOFT", 1, 5)), openf1(("SOFT", 1, 6)), sin_tiempo=set(), cortada=False
    ) == ["longitud ±1"]
    assert compara_stints.clasificar(
        feed(("SOFT", 1, 5), ("HARD", 6, 9)), openf1(("SOFT", 1, 5), ("HARD", 7, 10)), sin_tiempo=set(),
        cortada=False,
    ) == ["igual", "inicio corrido"]
