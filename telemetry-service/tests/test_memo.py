"""``main._resolve_session`` y su memo con sesiones falsas: una con datos se queda, una
vacía se vuelve a pedir al pasar ``EMPTY_RETRY`` o al cambiar el token, lo que pase antes.

Importa ``main`` (carga FastF1) con la caché en un directorio temporal. Ni red, ni
calendario: ``_load_session``, ``_latest_race``, ``_token_stamp`` y el reloj son falsos.
"""

import importlib
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
    """Una sesión cargada: con vueltas, con la tabla de vueltas vacía, o sin vueltas
    cargadas, que es lo que deja FastF1 cuando el archivo no da nada."""

    def __init__(self, forma):
        self.forma = forma

    @property
    def laps(self):
        if self.forma == "sin cargar":
            raise DataNotLoadedError("no cargada")
        return Vueltas(self.forma == "vacía")


@pytest.fixture
def memo(main, monkeypatch):
    """El memo limpio, con cargas que salen de ``formas`` en orden; ``cargas`` las
    cuenta, ``reloj`` y ``token`` se mueven a mano."""
    estado = SimpleNamespace(formas=[], cargas=[], reloj=0.0, token=1)

    def cargar(key):
        estado.cargas.append(key)
        return Sesion(estado.formas.pop(0))

    monkeypatch.setattr(main, "_sessions", {})
    monkeypatch.setattr(main, "_empty", {})
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
