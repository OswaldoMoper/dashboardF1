"""``main._resolve_session`` y su memo con sesiones falsas: una con datos se queda, una
vacía se vuelve a pedir al pasar ``EMPTY_RETRY`` o al cambiar el token, lo que pase antes,
y una con la telemetría incompleta igual, al pasar ``INCOMPLETE_RETRY``, borrando su
``car_data`` y cargándose sin la caché HTTP.

Importa ``main`` (carga FastF1) con la caché en un directorio temporal. Ni red, ni
calendario: ``_load_session``, ``_latest_race``, ``_token_stamp``, la cobertura, el
borrado y el reloj son falsos.
"""

import importlib
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastf1.exceptions import DataNotLoadedError


@pytest.fixture(scope="module")
def main(tmp_path_factory):
    with pytest.MonkeyPatch.context() as mp:
        mp.setenv("FASTF1_CACHE", str(tmp_path_factory.mktemp("fastf1-cache")))
        yield importlib.import_module("main")


class Vueltas:
    def __init__(self, empty):
        self.empty = empty


class Sesion:
    """Una sesión cargada: con vueltas, con la tabla de vueltas vacía, sin vueltas
    cargadas, que es lo que deja FastF1 cuando el archivo no da nada, o con vueltas y
    la telemetría de un 4 % de ellas, como la carrera de México."""

    def __init__(self, forma):
        self.forma = forma
        self.cobertura = 0.04 if forma == "incompleta" else 1.0

    @property
    def laps(self):
        if self.forma == "sin cargar":
            raise DataNotLoadedError("no cargada")
        return Vueltas(self.forma == "vacía")


@pytest.fixture
def memo(main, monkeypatch):
    """El memo limpio, con cargas que salen de ``formas`` en orden; ``cargas`` las
    cuenta y ``renovadas`` dice cuáles fueron sin la caché HTTP; ``borradas``, de qué
    sesiones se borró el ``car_data``; ``reloj`` y ``token`` se mueven a mano."""
    estado = SimpleNamespace(formas=[], cargas=[], renovadas=[], borradas=[], reloj=0.0, token=1)

    def cargar(key, renew=False):
        estado.cargas.append(key)
        estado.renovadas.append(renew)
        return Sesion(estado.formas.pop(0))

    monkeypatch.setattr(main, "_sessions", {})
    monkeypatch.setattr(main, "_empty", {})
    monkeypatch.setattr(main, "_incomplete", {})
    monkeypatch.setattr(main, "_renew", set())
    monkeypatch.setattr(main, "_telemetry_coverage", lambda s: s.cobertura)
    monkeypatch.setattr(main, "_drop_car_data", estado.borradas.append)
    monkeypatch.setattr(main, "_load_session", cargar)
    monkeypatch.setattr(main, "_latest_race", lambda: (2026, 19))
    monkeypatch.setattr(main, "_token_stamp", lambda: estado.token)
    monkeypatch.setattr(main, "time", SimpleNamespace(monotonic=lambda: estado.reloj))
    return estado


@pytest.mark.parametrize("forma, vacia", [("con datos", False), ("vacía", True), ("sin cargar", True)])
def test_vacia_es_sin_vueltas_cargadas_o_sin_ninguna(main, forma, vacia):
    assert main._is_empty(Sesion(forma)) is vacia


def test_una_sesion_con_datos_se_queda(main, memo):
    memo.formas = ["con datos"]
    primera = main._resolve_session("2026-19-R")
    memo.reloj += 10 * main.EMPTY_RETRY
    memo.token += 1
    assert main._resolve_session("2026-19-R") is primera
    assert memo.cargas == ["2026-19-R"]


def test_una_vacia_se_queda_mientras_no_pase_el_plazo_ni_cambie_el_token(main, memo):
    memo.formas = ["sin cargar"]
    primera = main._resolve_session("2026-19-R")
    memo.reloj += main.EMPTY_RETRY - 1
    assert main._resolve_session("2026-19-R") is primera
    assert memo.cargas == ["2026-19-R"]


def test_una_vacia_se_vuelve_a_pedir_al_pasar_el_plazo_y_la_buena_se_queda(main, memo):
    memo.formas = ["sin cargar", "con datos"]
    main._resolve_session("2026-19-R")
    memo.reloj += main.EMPTY_RETRY
    buena = main._resolve_session("2026-19-R")
    memo.reloj += 10 * main.EMPTY_RETRY
    assert main._resolve_session("2026-19-R") is buena
    assert memo.cargas == ["2026-19-R", "2026-19-R"]


def test_una_vacia_se_vuelve_a_pedir_en_cuanto_cambia_el_token(main, memo):
    memo.formas = ["sin cargar", "con datos"]
    main._resolve_session("2026-19-R")
    memo.token = 2
    assert not main._is_empty(main._resolve_session("2026-19-R"))
    assert memo.cargas == ["2026-19-R", "2026-19-R"]


def test_sin_fichero_de_token_y_despues_con_el_cuenta_como_cambio(main, memo):
    memo.formas = ["sin cargar", "con datos"]
    memo.token = None
    main._resolve_session("2026-19-R")
    memo.token = 7
    main._resolve_session("2026-19-R")
    assert memo.cargas == ["2026-19-R", "2026-19-R"]


def test_latest_vacia_se_olvida_con_su_clave_y_se_carga_una_vez(main, memo):
    memo.formas = ["sin cargar", "con datos"]
    main._resolve_session("latest")
    memo.token = 2
    buena = main._resolve_session("latest")
    assert main._resolve_session("2026-19-R") is buena
    assert memo.cargas == ["2026-19-R", "2026-19-R"]


def test_una_incompleta_se_queda_mientras_no_pase_el_plazo_ni_cambie_el_token(main, memo):
    memo.formas = ["incompleta"]
    primera = main._resolve_session("2026-19-R")
    memo.reloj += main.INCOMPLETE_RETRY - 1
    assert main._resolve_session("2026-19-R") is primera
    assert memo.cargas == ["2026-19-R"]
    assert memo.borradas == []


def test_una_incompleta_apunta_su_cobertura_y_la_hora_de_volver_a_pedirla(main, memo):
    memo.formas = ["incompleta"]
    antes = datetime.now(timezone.utc)
    sesion = main._resolve_session("2026-19-R")
    _, _, cobertura, hora = main._incomplete[id(sesion)]
    assert cobertura == 0.04
    plazo = timedelta(seconds=main.INCOMPLETE_RETRY)
    assert antes + plazo <= hora <= datetime.now(timezone.utc) + plazo


def test_una_incompleta_al_pasar_el_plazo_borra_su_car_data_y_se_carga_sin_la_cache_http(main, memo):
    memo.formas = ["incompleta", "con datos"]
    rota = main._resolve_session("2026-19-R")
    memo.reloj += main.INCOMPLETE_RETRY
    buena = main._resolve_session("2026-19-R")
    memo.reloj += 10 * main.INCOMPLETE_RETRY
    assert main._resolve_session("2026-19-R") is buena
    assert memo.cargas == ["2026-19-R", "2026-19-R"]
    assert memo.renovadas == [False, True]
    assert memo.borradas == [rota]
    assert main._renew == set()


def test_una_incompleta_se_vuelve_a_pedir_en_cuanto_cambia_el_token(main, memo):
    memo.formas = ["incompleta", "con datos"]
    main._resolve_session("2026-19-R")
    memo.token = 2
    main._resolve_session("2026-19-R")
    assert memo.renovadas == [False, True]


def test_una_que_sigue_incompleta_se_vuelve_a_apuntar(main, memo):
    memo.formas = ["incompleta", "incompleta", "con datos"]
    main._resolve_session("2026-19-R")
    memo.reloj += main.INCOMPLETE_RETRY
    main._resolve_session("2026-19-R")
    memo.reloj += main.INCOMPLETE_RETRY
    main._resolve_session("2026-19-R")
    assert memo.renovadas == [False, True, True]
    assert len(memo.borradas) == 2


def test_latest_incompleta_se_renueva_por_su_clave_y_no_por_latest(main, memo):
    memo.formas = ["incompleta", "con datos"]
    main._resolve_session("latest")
    memo.reloj += main.INCOMPLETE_RETRY
    buena = main._resolve_session("latest")
    assert main._resolve_session("2026-19-R") is buena
    assert memo.cargas == ["2026-19-R", "2026-19-R"]
    assert memo.renovadas == [False, True]
    assert main._renew == set()


def test_una_vacia_no_borra_nada_ni_se_carga_sin_la_cache_http(main, memo):
    memo.formas = ["sin cargar", "con datos"]
    main._resolve_session("2026-19-R")
    memo.reloj += main.EMPTY_RETRY
    main._resolve_session("2026-19-R")
    assert memo.renovadas == [False, False]
    assert memo.borradas == []
