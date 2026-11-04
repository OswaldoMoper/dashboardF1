# F1 Functional Dashboard

> Proyecto personal y no oficial, sin relación con las empresas de Fórmula 1.
> F1, FORMULA 1 y las marcas relacionadas son de Formula One Licensing B.V.

Plataforma modular de dashboard de Fórmula 1 construida en Haskell (backend funcional + frontend reactivo), con un microservicio Python para telemetría y un módulo de analítica matemática.

Con live timing, telemetría, comparación de vueltas, estrategias de neumáticos, estadísticas históricas y widgets personalizables.

## Estructura del repositorio

| Directorio          | Propósito                                                        |
| ------------------- | ---------------------------------------------------------------- |
| `backend/`          | Backend Haskell (Servant + Warp + Lucid): API REST y WebSockets. |
| `frontend/`         | Frontend Haskell (Reflex-DOM, GHC JS-backend): widgets/layouts.  |
| `telemetry-service/`| Microservicio Python (FastF1): telemetría avanzada.              |
| `analysis/`         | Analítica Haskell (módulo por integrar).                         |
| `docs/`             | Documentación viva del proyecto.                                 |

## Datos

Los datos se leen en el momento de OpenF1, Jolpica, FastF1 y el feed en directo.
El archivo de sesiones acabadas de F1 pide una cuenta de F1TV. La sesión se inicia
en la terminal con `dashboardF1-f1tv` y dura unos cuatro días; sin ella, FastF1 no
carga las sesiones acabadas y Lap Comparison y Telemetry enseñan un ejemplo. Lap
Comparison dice si la cuenta vale y cuándo lo que enseña es el ejemplo.

Las grabaciones del feed que usan `telemetry-service/tests/` y `e2e/` no se
distribuyen: sin ellas, `dashboardF1-pytest` y `dashboardF1-e2e` no pasan.
`dashboardF1-hspec` sí.

## Documentación

Para las fases, [`docs/ROADMAP.md`](docs/ROADMAP.md); para la arquitectura, [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Desarrollo

El toolchain se provee vía Nix flakes (GHC/cabal/python no están en el PATH global):

```sh
nix develop            # shell Haskell (backend + frontend)
nix run .#dev          # microservicio + backend; la web en http://127.0.0.1:8080/
nix run .#backend      # solo el backend Servant en :8080
nix develop .#telemetry -c python3 --version   # entorno del microservicio
```

`nix run .#dev` sirve el bundle del frontend **desde el store** (`STATIC_DIR`), así que no hace falta
`./result` y `nix build .#backend` no puede pisarlo. Sí hace falta el bundle construido
(`nix build .#frontend`), y al iterar sobre `frontend/` hay que **rearrancar** tras cada build. El puerto
se cambia con `PORT`; la cache de FastF1, con `FASTF1_CACHE`. El microservicio **no abre puerto**: escucha en
un socket Unix, `$XDG_RUNTIME_DIR/dashboardF1/fastf1-<PORT>.sock`, y el backend le habla por ahí. Para
depurarlo, `curl --unix-socket <ruta> http://localhost/fastf1/…`. El comando imprime el puerto, el socket y
la cache al arrancar, y se para antes de lanzar nada si el puerto o el socket están ocupados.

`nix run` a secas levanta **solo el backend**, a propósito: es el único artefacto desplegable, y con el
microservicio caído el backend degrada a cache o dummy — el escenario que conviene ejercitar por defecto.
