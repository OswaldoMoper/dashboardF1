"""Grabador del feed de timing en vivo de F1 — herramienta de desarrollo.

No forma parte del microservicio: `telemetrySrc` del flake solo empaqueta `main.py`,
`feed.py` y `convert.py`, así que este fichero no entra en la derivación. Existe para **capturar una sesión entera** y
poder diseñar sobre datos reales en vez de sobre una muestra de veinte segundos.

Se conecta a ``wss://livetiming.formula1.com/signalrcore`` reusando el
``SignalRClient`` de FastF1 — su formato de salida es el que
``fastf1.livetiming.data.LiveTimingData`` sabe releer después. Pide los topics de ese
cliente y, además, ``ChampionshipPrediction`` (la predicción del campeonato; en el
archivo de F1 sale en carreras y Sprints, no en clasificación, y solo llega con cuenta).

**Por defecto la conexión es anónima**, y así el feed no manda la telemetría del coche
(``CarData.z``, ``Position.z``). **Con ``--f1tv``, o con la variable ``F1TV`` no vacía, se
conecta con la cuenta de F1TV** del token que guarda FastF1 (``dashboardF1-f1tv`` inicia
sesión). Sin un token que valga, con terminal FastF1 pide el correo y la contraseña; sin
terminal, el grabador no graba: sale con código 3 antes de crear el fichero.

El modo anónimo no usa el ``no_auth=True`` de FastF1: pasa ``None`` como
``access_token_factory`` y el ``signalrcore`` 1.0.2 del pin lo rechaza con ``TypeError:
access_token_factory is not function``. ``_Recorder`` da en su lugar una función que
devuelve la cadena vacía, el token que el modo anónimo quiere mandar. Medido el
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
from typing import Callable, List, Optional

from fastf1.exceptions import F1AuthError
from fastf1.internals.f1account import get_token
from fastf1.livetiming.client import SignalRClient

NO_ACCOUNT = 3


class _Recorder(SignalRClient):
    """El cliente de FastF1 con un modo anónimo que ``signalrcore`` 1.0.2 acepta."""

    def __init__(self, *args, with_account: bool, **kwargs):
        super().__init__(*args, **kwargs)
        self._with_account = with_account

    def _access_token_factory(self) -> Optional[Callable[[], str]]:
        if not self._with_account:
            return lambda: ""
        return super()._access_token_factory()


def main(argv: List[str]) -> int:
    args = [arg for arg in argv if arg != "--f1tv"]
    with_account = len(args) < len(argv) or bool(os.environ.get("F1TV"))
    if not args:
        print(__doc__)
        return 2

    filename = args[0]
    timeout = int(args[1]) if len(args) > 1 else 300

    if with_account:
        try:
            get_token()
        except F1AuthError as exc:
            print(f"sin cuenta de F1TV, no se graba: {exc}", file=sys.stderr)
            return NO_ACCOUNT

    client = _Recorder(filename=filename, filemode="w", timeout=timeout, with_account=with_account)
    client.topics.append("ChampionshipPrediction")
    client.start()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
