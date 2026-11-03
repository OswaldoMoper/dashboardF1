"""``record_live``: sin cuenta, el token es la cadena vacía y nunca se pide la cuenta; con
cuenta, el de FastF1, y sin un token que valga no se graba ni se crea el fichero."""

from types import SimpleNamespace

import fastf1.livetiming.client as client
import pytest
from fastf1.exceptions import F1AuthError

import record_live


def no_account():
    raise AssertionError("el modo anónimo no pide la cuenta")


def no_token():
    raise F1AuthError("sin token")


@pytest.fixture
def started(monkeypatch):
    """El cliente que ``main`` arrancaría, sin conectarse a nada."""
    clients = []
    monkeypatch.setattr(record_live._Recorder, "start", lambda self: clients.append(self))
    monkeypatch.delenv("F1TV", raising=False)
    return clients


def test_sin_cuenta_el_token_es_la_cadena_vacia_y_no_se_pide_la_cuenta(monkeypatch, tmp_path):
    monkeypatch.setattr(client, "get_token", no_account)
    recorder = record_live._Recorder(filename=str(tmp_path / "feed.txt"), with_account=False)
    factory = recorder._access_token_factory()
    assert callable(factory)
    assert factory() == ""


def test_con_cuenta_el_token_es_el_de_fastf1(monkeypatch, tmp_path):
    monkeypatch.setattr(client, "get_token", lambda: SimpleNamespace(value="el-token"))
    recorder = record_live._Recorder(filename=str(tmp_path / "feed.txt"), with_account=True)
    assert recorder._access_token_factory()() == "el-token"


def test_sin_cuenta_arranca_sin_pedirla_y_pide_la_prediccion(monkeypatch, tmp_path, started):
    monkeypatch.setattr(record_live, "get_token", no_account)
    assert record_live.main([str(tmp_path / "feed.txt"), "60"]) == 0
    [recorder] = started
    assert recorder._with_account is False
    assert recorder.timeout == 60
    assert "ChampionshipPrediction" in recorder.topics


@pytest.mark.parametrize("argv, env", [(["--f1tv"], None), ([], "1")])
def test_con_cuenta_y_sin_token_no_graba_ni_crea_el_fichero(monkeypatch, tmp_path, started, argv, env):
    if env is not None:
        monkeypatch.setenv("F1TV", env)
    monkeypatch.setattr(record_live, "get_token", no_token)
    out = tmp_path / "feed.txt"
    assert record_live.main(argv + [str(out)]) == record_live.NO_ACCOUNT
    assert started == []
    assert not out.exists()


def test_sin_argumentos_enseña_el_uso(started, capsys):
    assert record_live.main([]) == 2
    assert "Uso::" in capsys.readouterr().out
    assert started == []
