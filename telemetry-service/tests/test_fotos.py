"""``fotos.transformar``: lo que cambia de una foto del feed y lo que conserva."""

import fotos


def test_un_tiempo_cambia_en_su_misma_forma_y_lo_demas_no():
    assert [fotos._escala(t) for t in ["1:36.680", "29.268", "+5.089", "59.900"]] == [
        "1:38.005", "29.669", "+5.159", "60.721"]
    assert [fotos._escala(t) for t in ["LAP 5", "1 L", "312", ""]] == ["LAP 5", "1 L", "312", ""]


def test_los_datos_de_cada_coche_pasan_a_otro_numero_con_su_linea_y_sin_tocar_la_entrada():
    foto = {
        "DriverList": {n: {"Tla": t, "Line": i} for i, (n, t) in enumerate([("1", "AAA"), ("4", "BBB"), ("16", "CCC")], 1)},
        "TimingData": {"Lines": {n: {"RacingNumber": n, "Position": str(i), "GapToLeader": g}
                                 for i, (n, g) in enumerate([("1", ""), ("4", "+1.000"), ("16", "+2.000")], 1)}},
    }
    salida = fotos.transformar(foto)
    # Con tres coches, rotar 5 puestos es rotar 2: el 1 pasa al 16, el 4 al 1 y el 16 al 4.
    assert salida["TimingData"]["Lines"] == {
        "16": {"RacingNumber": "16", "Position": "1", "GapToLeader": ""},
        "1": {"RacingNumber": "1", "Position": "2", "GapToLeader": "+1.014"},
        "4": {"RacingNumber": "4", "Position": "3", "GapToLeader": "+2.027"},
    }
    assert {n: (p["Tla"], p["Line"]) for n, p in salida["DriverList"].items()} == {
        "1": ("AAA", 2), "4": ("BBB", 3), "16": ("CCC", 1)}
    assert foto["TimingData"]["Lines"]["1"] == {"RacingNumber": "1", "Position": "1", "GapToLeader": ""}


def test_los_stints_rotan_el_compuesto_y_retrasan_la_primera_parada_sin_cambiar_el_total():
    stint = lambda c, a, t, mismo="0": {"Compound": c, "StartLaps": a, "TotalLaps": t, "TyresNotChanged": mismo}
    assert fotos._cambia_stints([stint("MEDIUM", 0, 15), stint("HARD", 0, 42)]) == [
        stint("HARD", 0, 16), stint("SOFT", 0, 41)]
    # El juego que vuelve a pista lleva la edad con la que se paró; la lluvia no rota.
    assert fotos._cambia_stints([stint("SOFT", 0, 5), stint("SOFT", 5, 10, "1"), stint("WET", 0, 3)]) == [
        stint("MEDIUM", 0, 6), stint("MEDIUM", 6, 10, "1"), stint("WET", 0, 3)]
