"""Grabador del feed de timing en vivo de F1 — herramienta de desarrollo.

No forma parte del microservicio: `telemetrySrc` del flake solo empaqueta `main.py`, así
que este fichero no entra en la derivación. Existe para **capturar una sesión entera** y
poder diseñar sobre datos reales en vez de sobre una muestra de veinte segundos.

Se conecta a ``wss://livetiming.formula1.com/signalrcore`` reusando el
``SignalRClient`` de FastF1 — su formato de salida es el que
``fastf1.livetiming.data.LiveTimingData`` sabe releer después. Pide los topics de ese
cliente y, además, ``ChampionshipPrediction`` (la predicción del campeonato; en el
archivo de F1 sale en carreras y Sprints, no en clasificación).

**Por defecto la conexión es anónima**, y así el feed no manda la telemetría del coche
(``CarData.z``, ``Position.z``). **Con ``--f1tv``, o con la variable ``F1TV`` no vacía, se
conecta con una cuenta de F1TV:** la primera vez ``fastf1.internals.f1auth`` imprime una
dirección para iniciar sesión en el navegador, y guarda el token para las siguientes.

Para la conexión anónima está el único apaño del fichero: FastF1 ofrece
``no_auth=True`` para eso, pero pasa ``None`` como ``access_token_factory`` y el
``signalrcore`` 1.0.2 del pin lo rechaza con ``TypeError: access_token_factory is not
function``. En vez de reimplementar ``_run`` entero se sustituye ``get_auth_token`` por
una función que devuelve la cadena vacía: sigue siendo una función, así que la
validación pasa, y el token vacío es lo que el modo anónimo quiere mandar. Medido el
2026-09-06 contra el GP de Italia: el feed acepta la conexión sin token y sirve los doce
topics completos.

**Lo que este grabador no hace, y conviene saberlo antes de confiar en él:** el
``SignalRClient`` no reconecta solo —su propio código lleva un ``TODO`` al respecto—, así
que una caída de red parte la grabación. El ``timeout`` es de inactividad del feed, no de
duración total: con bandera roja el feed sigue latiendo, pero conviene dejarlo holgado.

Uso::

    python record_live.py [--f1tv] salida.txt [timeout_segundos]
"""

import os
import sys

import fastf1.internals.f1auth as f1auth

_ARGS = [arg for arg in sys.argv[1:] if arg != "--f1tv"]
_WITH_ACCOUNT = len(_ARGS) < len(sys.argv) - 1 or bool(os.environ.get("F1TV"))

# El apaño del Haddock de arriba: una función que devuelve el token vacío, puesta antes
# de importar el cliente porque `livetiming.client` la captura por valor al importarse.
if not _WITH_ACCOUNT:
    f1auth.get_auth_token = lambda: ""

from fastf1.livetiming.client import SignalRClient  # noqa: E402


def main() -> int:
    if not _ARGS:
        print(__doc__)
        return 2

    filename = _ARGS[0]
    timeout = int(_ARGS[1]) if len(_ARGS) > 1 else 300

    client = SignalRClient(filename=filename, filemode="w", timeout=timeout)
    client.topics.append("ChampionshipPrediction")
    # `no_auth` se queda en False a propósito: es lo que hace que el cliente use la
    # `get_auth_token` de arriba —la sustituida o la de la cuenta— en vez del `None`
    # que rompe signalrcore.
    client.start()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
