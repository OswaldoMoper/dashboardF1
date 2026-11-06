"""``main._coverage`` y ``main._telemetry_incomplete``: si la telemetría de una sesión
cargada cubre el tramo de sus vueltas. Con sesiones falsas, sin red.

Importa ``main`` (carga FastF1) con la caché en un directorio temporal.
"""

import importlib

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
