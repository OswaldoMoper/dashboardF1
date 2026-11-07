"""``main._coverage`` y ``main._telemetry_incomplete``: si la telemetría de una sesión
cargada cubre el tramo de sus vueltas. Y lo que se hace con una incompleta: qué fichero
de la caché se borra, la carga sin la caché HTTP y ``lcTelemetry`` en la comparación.
Con sesiones falsas, sin red.

Importa ``main`` (carga FastF1) con la caché en un directorio temporal.
"""

import importlib
import os
from datetime import datetime, timezone
from types import SimpleNamespace

import fastf1
import pandas as pd
import pytest
from fastf1.exceptions import DataNotLoadedError


@pytest.fixture(scope="module")
def main(tmp_path_factory):
    with pytest.MonkeyPatch.context() as mp:
        mp.setenv("FASTF1_CACHE", str(tmp_path_factory.mktemp("fastf1-cache")))
        yield importlib.import_module("main")


@pytest.mark.parametrize(
    "telemetria, vueltas, esperado",
    [
        ((0, 100), (0, 100), 1.0),
        ((-50, 200), (0, 100), 1.0),
        ((0, 25), (0, 100), 0.25),
        ((75, 300), (0, 100), 0.25),
        ((200, 300), (0, 100), 0.0),
        (None, (0, 100), 0.0),
        ((0, 100), None, None),
        ((0, 100), (50, 50), None),
    ],
)
def test_la_cobertura_es_la_fraccion_del_tramo_de_las_vueltas(main, telemetria, vueltas, esperado):
    assert main._coverage(telemetria, vueltas) == esperado


class Sesion:
    """Una sesión cargada con vueltas entre ``vueltas`` (en segundos de sesión) y la
    telemetría de cada coche entre los tramos de ``coches``; ``None`` en cualquiera de
    los dos es que no se cargó."""

    def __init__(self, vueltas, coches):
        self._vueltas = vueltas
        self._coches = coches

    @property
    def laps(self):
        if self._vueltas is None:
            raise DataNotLoadedError("no cargada")
        desde, hasta = self._vueltas
        return pd.DataFrame({
            "LapStartTime": pd.to_timedelta([desde, desde + 90, pd.NA], unit="s"),
            "Time": pd.to_timedelta([desde + 90, hasta, pd.NA], unit="s"),
        })

    @property
    def car_data(self):
        if self._coches is None:
            raise DataNotLoadedError("no cargada")
        return {
            str(n): pd.DataFrame({"SessionTime": pd.to_timedelta([desde, hasta], unit="s")})
            for n, (desde, hasta) in enumerate(self._coches)
        }


# La carrera de México: unos 115 min de vueltas y 10,6 min de telemetría.
MEXICO = (3600.0, 3600.0 + 115 * 60)


@pytest.mark.parametrize(
    "sesion, incompleta",
    [
        (Sesion(MEXICO, [MEXICO, MEXICO]), False),
        (Sesion(MEXICO, [(MEXICO[0], MEXICO[0] + 10.6 * 60)] * 2), True),
        (Sesion(MEXICO, [(MEXICO[0], MEXICO[0] + 10.6 * 60), MEXICO]), False),
        (Sesion((0.0, 100.0), [(0.0, 50.0)]), False),
        (Sesion((0.0, 100.0), [(0.0, 49.0)]), True),
        (Sesion(MEXICO, None), True),
        (Sesion(MEXICO, []), True),
        (Sesion(None, [MEXICO]), False),
    ],
    ids=["entera", "méxico", "un coche entero", "justo la mitad", "menos de la mitad",
         "sin telemetría cargada", "sin coches", "sin vueltas"],
)
def test_incompleta_si_cubre_menos_de_la_mitad_de_las_vueltas(main, sesion, incompleta):
    assert main._telemetry_incomplete(sesion) is incompleta


# La carpeta de la carrera de México en la caché, tal como la da ``Session.api_path``.
MEXICO_PATH = "/static/2026/2026-11-01_Mexico_City_Grand_Prix/2026-11-01_Race/"


def test_el_car_data_es_el_fichero_que_escribe_fastf1(main):
    sesion = SimpleNamespace(api_path=MEXICO_PATH)
    suyo = fastf1.Cache._get_cache_file_path(MEXICO_PATH, "car_data")
    assert os.path.realpath(main._car_data_file(sesion)) == os.path.realpath(suyo)


def test_se_borra_el_car_data_y_lo_demas_de_la_sesion_se_queda(main):
    sesion = SimpleNamespace(api_path=MEXICO_PATH)
    car = main._car_data_file(sesion)
    pos = os.path.join(os.path.dirname(car), "position_data.ff1pkl")
    os.makedirs(os.path.dirname(car), exist_ok=True)
    for f in (car, pos):
        with open(f, "wb") as out:
            out.write(b"x")
    main._drop_car_data(sesion)
    assert not os.path.exists(car)
    assert os.path.exists(pos)
    main._drop_car_data(sesion)


@pytest.mark.parametrize("renew, apagadas", [(False, (False, False)), (True, (True, False))])
def test_al_renovar_se_carga_sin_la_cache_http_y_con_la_procesada(main, monkeypatch, renew, apagadas):
    vistas = []

    class Cargable:
        def load(self, **_):
            vistas.append((fastf1.Cache._http_tmp_disabled, fastf1.Cache._func_tmp_disabled))

    monkeypatch.setattr(main.fastf1, "get_session", lambda *_: Cargable())
    main._load_session("2026-20-R", renew)
    assert vistas == [apagadas]
    assert (fastf1.Cache._http_tmp_disabled, fastf1.Cache._func_tmp_disabled) == (False, False)


@pytest.fixture
def respuesta(main, monkeypatch):
    """``main.comparison`` sobre una sesión falsa: ``incompleta`` la apunta en
    ``_incomplete`` con un 4 % y la hora de volver a pedirla."""
    sesion = SimpleNamespace()
    monkeypatch.setattr(main, "_incomplete", {})
    monkeypatch.setattr(main, "_resolve_session", lambda _: sesion)
    monkeypatch.setattr(main, "_resolve_drivers", lambda *_: ["1", "16"])
    monkeypatch.setattr(main, "_qualifying_parts", lambda _: [])
    monkeypatch.setattr(main, "_comparison_entry", lambda _s, n, *_: {"ceCar": n})

    def pedir(samples, incompleta):
        if incompleta:
            hora = datetime(2026, 11, 7, 0, 40, 5, tzinfo=timezone.utc)
            main._incomplete[id(sesion)] = (0.0, None, 0.04213, hora)
        return main.comparison("2026-20-R", "1,16", samples)

    return pedir


def test_con_trazas_y_la_telemetria_incompleta_lleva_su_cobertura_y_la_hora(respuesta):
    assert respuesta(100, True)["lcTelemetry"] == {"coverage": 0.0421, "retryAt": "2026-11-07T00:40:05Z"}


@pytest.mark.parametrize("samples, incompleta", [(0, True), (100, False), (0, False)])
def test_sin_trazas_o_entera_no_lleva_nada(respuesta, samples, incompleta):
    assert "lcTelemetry" not in respuesta(samples, incompleta)
