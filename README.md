# F1 Functional Dashboard

Plataforma modular de dashboard de Fórmula 1 construida en Haskell (backend funcional + frontend reactivo), con un microservicio Python para telemetría y un módulo de analítica matemática.

Con live timing, telemetría, comparación de vueltas, estrategias de neumáticos, estadísticas históricas y widgets personalizables.

## Estructura del repositorio

| Directorio          | Propósito                                                        |
| ------------------- | ---------------------------------------------------------------- |
| `backend/`          | Backend Haskell (Servant + Warp + Lucid): API REST y WebSockets. |
| `frontend/`         | Frontend Haskell (Reflex-DOM, GHC JS-backend): widgets/layouts.  |
| `telemetry-service/`| Microservicio Python (FastF1): telemetría avanzada.              |
| `analysis/`         | Analítica Haskell reutilizando `Mathematical_Data_Analysis`.     |
| `docs/`             | Documentación viva del proyecto.                                 |

## Documentación

Para las fases, [`docs/ROADMAP.md`](docs/ROADMAP.md); para la arquitectura, [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Desarrollo

El toolchain se provee vía Nix flakes (GHC/cabal/python no están en el PATH global):

```sh
nix develop            # shell Haskell (backend + frontend)
nix run .#backend      # levanta el backend Servant en :8080
nix develop .#telemetry -c python3 --version   # entorno del microservicio
```
