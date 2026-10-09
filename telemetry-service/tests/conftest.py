"""Hypothesis guarda todo junto al servicio, y no en el directorio desde el que se lanza
la suite: los ejemplos que fallaron se repiten primero en la pasada siguiente.

El aviso de generación lenta va apagado: la primera pasada en un clon nuevo construye la
tabla de caracteres de hypothesis (más de 1 s) y saldría roja sin que falle nada.
"""

from pathlib import Path

from hypothesis import HealthCheck, settings
from hypothesis.configuration import set_hypothesis_home_dir

set_hypothesis_home_dir(Path(__file__).resolve().parent.parent / ".hypothesis")

settings.register_profile("servicio", suppress_health_check=[HealthCheck.too_slow])
settings.load_profile("servicio")
