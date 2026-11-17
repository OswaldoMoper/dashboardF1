"""El techo de tiempo y las conexiones nuevas de lo que FastF1 pide a la red.

Sin salir del PC: servidores en ``127.0.0.1``. Uno acepta y nunca contesta, que desde el
cliente se ve igual que una conexión muerta por el camino; otro es HTTP con keep-alive y
cuenta las conexiones que le abren. Importa ``main`` (carga FastF1) con la caché en un
directorio temporal.
"""

import importlib
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
import requests


@pytest.fixture(scope="module")
def main(tmp_path_factory):
    with pytest.MonkeyPatch.context() as mp:
        mp.setenv("FASTF1_CACHE", str(tmp_path_factory.mktemp("fastf1-cache")))
        yield importlib.import_module("main")


def mudo_en(port):
    """Un socket que escucha en ``port`` y no acepta nunca: la conexión se abre y la
    petición no tiene respuesta."""
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.listen()
    return sock


@pytest.fixture
def mudo():
    sock = mudo_en(0)
    yield f"http://127.0.0.1:{sock.getsockname()[1]}/"
    sock.close()


class Contador(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    conexiones = 0

    def setup(self):
        super().setup()
        type(self).conexiones += 1

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


@pytest.fixture
def contador():
    """Un servidor HTTP con keep-alive: el servidor, su URL y la clase que cuenta las
    conexiones. Se puede apagar dentro de la prueba."""
    handler = type("ContadorDeEstaPrueba", (Contador,), {"conexiones": 0})
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    vivo = [True]

    def apagar():
        if vivo[0]:
            vivo[0] = False
            server.shutdown()
            server.server_close()

    yield server, f"http://127.0.0.1:{server.server_address[1]}/", handler, apagar
    apagar()


def test_sin_timeout_propio_se_rinde_al_techo(main, mudo):
    session = requests.Session()
    main._with_timeout(session, 0.5)
    empieza = time.monotonic()
    with pytest.raises(requests.exceptions.ReadTimeout):
        session.get(mudo)
    assert time.monotonic() - empieza < 5


def test_un_timeout_propio_se_respeta(main):
    pedidas = []

    class Sesion:
        def request(self, method, url, *args, **kwargs):
            pedidas.append(kwargs.get("timeout"))

    sesion = Sesion()
    main._with_timeout(sesion, 30.0)
    sesion.request("GET", "http://x/")
    sesion.request("GET", "http://x/", timeout=5.0)
    assert pedidas == [30.0, 5.0]


def test_la_misma_sesion_reutiliza_la_conexion(contador):
    _, url, handler, _ = contador
    session = requests.Session()
    session.get(url)
    session.get(url)
    assert handler.conexiones == 1


def test_tras_cerrar_las_ociosas_abre_otra_y_sigue_sirviendo(main, contador):
    _, url, handler, _ = contador
    session = requests.Session()
    session.get(url)
    main._close_idle(session)
    assert session.get(url).text == "ok"
    assert handler.conexiones == 2


def test_las_dos_sesiones_de_fastf1_llevan_el_techo(main):
    """Si una versión de FastF1 cambia dónde guarda sus sesiones, esto falla."""
    sesiones = main._fastf1_sessions()
    assert len(sesiones) == 2
    assert all(isinstance(s, requests.Session) for s in sesiones)
    assert all("request" in vars(s) for s in sesiones)


def test_la_que_guarda_se_rinde_al_techo_y_devuelve_lo_guardado(main, contador):
    """El camino del calendario: una respuesta guardada y vencida, y el servidor que ya no
    contesta. La sesión con caché de FastF1, con el techo, devuelve lo guardado."""
    server, url, _, apagar = contador
    port = server.server_address[1]
    clase = type(main.fastf1.Cache._requests_session_cached)
    session = clase(backend="memory", cache_control=True, stale_if_error=True, expire_after=1)
    main._with_timeout(session, 0.5)
    assert session.get(url).text == "ok"
    time.sleep(1.2)
    apagar()
    # La conexión de antes la seguiría atendiendo su hilo: como en una carga, se renueva.
    main._close_idle(session)
    sock = mudo_en(port)
    try:
        empieza = time.monotonic()
        respuesta = session.get(url)
        tardo = time.monotonic() - empieza
    finally:
        sock.close()
    assert respuesta.text == "ok"
    assert respuesta.from_cache
    assert tardo < 5


def test_coger_el_cerrojo_renueva_las_conexiones(main, monkeypatch):
    """Una carga renueva las conexiones antes de pedir nada; lo ya en memoria no las toca."""
    renovadas = []
    monkeypatch.setattr(main, "_sessions", {})
    monkeypatch.setattr(main, "_empty", {})
    monkeypatch.setattr(main, "_incomplete", {})
    monkeypatch.setattr(main, "_renew", set())
    monkeypatch.setattr(main, "_telemetry_incomplete", lambda s: False)
    monkeypatch.setattr(main, "_is_empty", lambda s: False)
    monkeypatch.setattr(main, "_give_back", lambda: None)
    monkeypatch.setattr(main, "_token_stamp", lambda: 1)
    monkeypatch.setattr(main, "_fresh_connections", lambda: renovadas.append("renovar"))
    monkeypatch.setattr(main, "_load_session", lambda key, renew=False: renovadas.append(key) or object())
    primera = main._resolve_session("2026-20-Q")
    assert main._resolve_session("2026-20-Q") is primera
    assert renovadas == ["renovar", "2026-20-Q"]
