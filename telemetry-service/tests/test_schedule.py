"""``/fastf1/schedule/{year}``: el calendario de FastF1 de un año, con calendarios falsos y
sin red.

Importa ``main`` (carga FastF1) con la caché en un directorio temporal.
"""

import importlib
import math

import pandas as pd
import pytest
from fastapi import HTTPException


@pytest.fixture(scope="module")
def main(tmp_path_factory):
    with pytest.MonkeyPatch.context() as mp:
        mp.setenv("FASTF1_CACHE", str(tmp_path_factory.mktemp("fastf1-cache")))
        yield importlib.import_module("main")


def test_cada_gran_premio_con_su_ronda_y_su_nombre(main, monkeypatch):
    events = pd.DataFrame(
        {
            "RoundNumber": [16, 20],
            "EventName": ["Bahrain Grand Prix", "São Paulo Grand Prix"],
        }
    )
    monkeypatch.setattr(main.fastf1, "get_event_schedule", lambda year, include_testing: events)
    assert main.schedule(2026) == [
        {"round": 16, "name": "Bahrain Grand Prix"},
        {"round": 20, "name": "São Paulo Grand Prix"},
    ]


def test_sin_ronda_o_sin_nombre_no_sale(main):
    events = pd.DataFrame(
        {
            "RoundNumber": [0, math.nan, 3, 4],
            "EventName": ["Pre-Season Testing", "Sin ronda", "", "Japanese Grand Prix"],
        }
    )
    assert main._schedule_rounds(events) == [{"round": 4, "name": "Japanese Grand Prix"}]


def test_pide_el_año_sin_los_test(main, monkeypatch):
    asked = []

    def schedule(year, include_testing):
        asked.append((year, include_testing))
        return pd.DataFrame({"RoundNumber": [], "EventName": []})

    monkeypatch.setattr(main.fastf1, "get_event_schedule", schedule)
    assert main.schedule(2025) == []
    assert asked == [(2025, False)]


def test_si_fastf1_no_da_el_calendario_503(main, monkeypatch):
    def schedule(year, include_testing):
        raise ValueError("sin red")

    monkeypatch.setattr(main.fastf1, "get_event_schedule", schedule)
    with pytest.raises(HTTPException) as caught:
        main.schedule(2026)
    assert caught.value.status_code == 503


# ── /fastf1/circuits/{year} ─────────────────────────────────────────────────────


class _Ergast:
    """La interfaz Ergast de FastF1, falsa: da ``races`` y apunta los años pedidos."""

    asked = []
    races = pd.DataFrame({"round": [], "circuitId": []})

    def get_race_schedule(self, season):
        _Ergast.asked.append(season)
        return _Ergast.races


def test_cada_gran_premio_con_su_ronda_y_su_circuito(main, monkeypatch):
    _Ergast.asked, _Ergast.races = [], pd.DataFrame(
        {"round": [15, 16, 17], "circuitId": ["bahrain", "bahrain", "yas_marina"], "raceName": ["a", "b", "c"]}
    )
    monkeypatch.setattr(main, "Ergast", _Ergast)
    assert main.circuits(2020) == [
        {"round": 15, "circuit": "bahrain", "name": "a"},
        {"round": 16, "circuit": "bahrain", "name": "b"},
        {"round": 17, "circuit": "yas_marina", "name": "c"},
    ]
    assert _Ergast.asked == [2020]


def test_sin_ronda_o_sin_circuito_no_sale(main):
    races = pd.DataFrame({"round": [0, math.nan, 3, 4], "circuitId": ["x", "y", "", "suzuka"]})
    assert main._circuit_rounds(races) == [{"round": 4, "circuit": "suzuka", "name": ""}]


def test_si_no_hay_circuitos_503(main, monkeypatch):
    class Caida:
        def get_race_schedule(self, season):
            raise ValueError("sin red")

    monkeypatch.setattr(main, "Ergast", Caida)
    with pytest.raises(HTTPException) as caught:
        main.circuits(2026)
    assert caught.value.status_code == 503
