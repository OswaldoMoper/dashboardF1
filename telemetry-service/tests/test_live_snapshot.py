"""``main._live_snapshot`` contra un feed falso: la foto vuelve sin esperar a que se cierre
la conexión, también cuando el feed no manda el estado.

Importa ``main`` (carga FastF1) con la caché en un directorio temporal, para no crear
``.fastf1-cache`` donde se lance la suite.
"""

import importlib
import threading

import pytest
import requests
import signalrcore.hub_connection_builder
import signalrcore.messages.completion_message

FOTO = {"SessionInfo": {"Name": "Race"}, "TimingData": {"Lines": {}}}


@pytest.fixture(scope="module")
def main(tmp_path_factory):
    with pytest.MonkeyPatch.context() as mp:
        mp.setenv("FASTF1_CACHE", str(tmp_path_factory.mktemp("fastf1-cache")))
        yield importlib.import_module("main")


class Completion:
    def __init__(self, result):
        self.result = result


class FeedFalso:
    """Acepta la conexión al momento y, si ``manda``, contesta al ``Subscribe`` con
    ``FOTO``. Su ``stop`` avisa en ``cerrando`` y se queda bloqueado hasta ``soltar``."""

    def __init__(self, manda):
        self.manda = manda
        self.cerrando = threading.Event()
        self.soltar = threading.Event()
        self.al_abrir = None

    # HubConnectionBuilder
    def __call__(self):
        return self

    def with_url(self, _url, options=None):
        return self

    def build(self):
        return self

    # La conexión
    def on_open(self, callback):
        self.al_abrir = callback

    def on(self, _name, _callback):
        pass

    def start(self):
        self.al_abrir()

    def send(self, _method, _args, on_invocation=None):
        if self.manda:
            on_invocation(Completion(FOTO))

    def stop(self):
        self.cerrando.set()
        self.soltar.wait(10)


class Negociado:
    cookies = {"AWSALBCORS": "galleta"}


def con_feed(monkeypatch, manda):
    feed = FeedFalso(manda)
    monkeypatch.setattr(requests, "options", lambda *_a, **_k: Negociado())
    monkeypatch.setattr(signalrcore.hub_connection_builder, "HubConnectionBuilder", feed)
    monkeypatch.setattr(signalrcore.messages.completion_message, "CompletionMessage", Completion)
    return feed


def en_hilo(funcion):
    salida = {}

    def correr():
        try:
            salida["valor"] = funcion()
        except Exception as error:
            salida["error"] = error

    hilo = threading.Thread(target=correr, daemon=True)
    hilo.start()
    hilo.join(2.0)
    return hilo, salida


def test_la_foto_vuelve_sin_esperar_a_que_cierre_la_conexion(main, monkeypatch):
    feed = con_feed(monkeypatch, manda=True)
    try:
        hilo, salida = en_hilo(lambda: main._live_snapshot(timeout=1.0))
        assert not hilo.is_alive()
        assert salida["valor"] == FOTO
        assert feed.cerrando.wait(2.0)
    finally:
        feed.soltar.set()


def test_sin_estado_falla_sin_esperar_a_que_cierre_la_conexion(main, monkeypatch):
    feed = con_feed(monkeypatch, manda=False)
    try:
        hilo, salida = en_hilo(lambda: main._live_snapshot(timeout=0.2))
        assert not hilo.is_alive()
        assert isinstance(salida["error"], TimeoutError)
        assert feed.cerrando.wait(2.0)
    finally:
        feed.soltar.set()
