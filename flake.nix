{
  description = "F1 Functional Dashboard — Haskell (Servant + Reflex) + Python (FastF1) + analytics";

  nixConfig = {
    allow-import-from-derivation = true;
    extra-substituters = [ "https://nixcache.reflex-frp.org" ];
    extra-trusted-public-keys = [
      "ryantrinkle.com-1:JJiAKaRv9mWgpVAz8dwewnZe0AzzEAzPkagE9SP5NWI="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-reflex.url = "github:NixOS/nixpkgs/59e69648d345d6e8fef86158c555730fa12af9de";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      perSystem = { pkgs, self', system, ... }:
      let
        reflexPkgs = import inputs.nixpkgs-reflex { inherit system; };
        jsPkgs = reflexPkgs.pkgsCross.ghcjs.haskell.packages.ghc910.extend (hf: _hp: {
          common = hf.callCabal2nix "common" ./common { };
          frontend = hf.callCabal2nix "frontend" ./frontend { };
        });
        frontendJs = jsPkgs.frontend;

        hp = pkgs.haskellPackages.extend (hf: _hp: {
          common = hf.callCabal2nix "common" ./common { };
          backend = hf.callCabal2nix "backend" ./backend { };
        });

        # ── Microservicio FastF1 ──
        python = reflexPkgs.python3;

        pypiWheel = { pname, version, hash, deps, extra ? { } }:
          python.pkgs.buildPythonPackage ({
            inherit pname version;
            format = "wheel";
            src = pkgs.fetchPypi {
              inherit pname version hash;
              format = "wheel";
              dist = "py3";
              python = "py3";
            };
            propagatedBuildInputs = deps;

            doCheck = false;
            pythonImportsCheck = [ pname ];
          } // extra);

        timple = pypiWheel {
          pname = "timple";
          version = "0.1.8";
          hash = "sha256-GVpJ52+KQ14LwHk0C2xXJyzDr/kEH2H4hYeQ1gek5J0=";
          deps = with python.pkgs; [ numpy matplotlib ];
        };

        signalrcore = pypiWheel {
          pname = "signalrcore";
          version = "1.0.2";
          hash = "sha256-SG47GBMRkfX1KEGE9D8tUUJHn40itCv/mC1S73+BAlw=";
          deps = with python.pkgs; [ msgpack requests websocket-client ];

          extra.pythonRelaxDeps = [ "msgpack" ];
        };

        fastf1 = pypiWheel {
          pname = "fastf1";
          version = "3.8.3";
          hash = "sha256-4ycPbWCDhmLdPhXPYjZRkiin/PzACfXtsZV5h2nIRa0=";

          deps = (with python.pkgs; [
            cryptography
            matplotlib
            numpy
            pandas
            platformdirs
            pydantic
            pyjwt
            python-dateutil
            rapidfuzz
            requests
            requests-cache
            scipy
            websockets
          ]) ++ [ signalrcore timple ];
        };

        pythonEnv = python.withPackages (ps: [
          fastf1
          ps.fastapi
          ps.uvicorn
        ]);

        telemetrySrc = pkgs.runCommand "telemetry-service-src" { } ''
          mkdir -p $out
          install -m644 ${./telemetry-service/main.py} $out/main.py
        '';

        # Guard shared by the working-tree commands: they run code from $PWD, so
        # the repository root is a precondition and not an assumption.
        guardRoot = ''
          if [ ! -f flake.nix ] || [ ! -d telemetry-service ]; then
            echo "error: lánzalo desde la raíz del repositorio" >&2
            exit 2
          fi
        '';

        # `packages.dev` embeds the frontend, backend and telemetry store paths, so
        # putting it in the dev shell would rebuild GHCJS on every entry after a
        # source change — and with direnv, in every terminal. This launcher gives it
        # the same short name and defers to `nix run`, which builds only when the
        # command is actually used.
        devLauncher = pkgs.writeShellApplication {
          name = "dashboardF1-dev";
          text = ''
            ${guardRoot}
            exec nix run .#dev -- "$@"
          '';
        };
      in
      {
        # ── Backend Servant (Fase 1: /home + /api/* en :8080, override con PORT) ──
        packages.backend = hp.backend;
        packages.default = self'.packages.backend;

        # ── Frontend Reflex (GHCJS) ──
        packages.frontend = pkgs.runCommand "dashboardF1-frontend" { } ''
          mkdir -p $out
          cp -r ${frontendJs}/bin/frontend.jsexe/. $out/
          install -m644 ${./frontend/index.html}   $out/index.html
          install -m644 ${./frontend/dashboard.css} $out/dashboard.css
        '';

        # ── Microservicio FastF1 ──
        packages.telemetry = pkgs.writeShellApplication {
          name = "telemetry-service";
          runtimeInputs = [ pythonEnv ];
          text = ''
            exec uvicorn --app-dir ${telemetrySrc} main:app "$@"
          '';
        };

        apps.telemetry = {
          type = "app";
          program = "${self'.packages.telemetry}/bin/telemetry-service";
        };

        # `nix run .#backend` (o `nix run`) — levanta el backend.
        apps.backend = {
          type = "app";
          program = "${self'.packages.backend}/bin/backend";
        };
        apps.default = self'.apps.backend;

        # ── Entorno de desarrollo completo: microservicio + backend ──
        packages.dev = pkgs.writeShellApplication {
          name = "dashboardF1-dev";
          runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.iproute2 ];
          text = ''
            port="''${PORT:-8080}"
            tport="''${TELEMETRY_PORT:-8000}"
            # `FASTF1_CACHE` en vez de un `cd`
            cache="''${FASTF1_CACHE:-$PWD/telemetry-service/.fastf1-cache}"

            # Both ports are checked before anything starts. `ss -p` only names
            # processes of the current user, so the holder may be missing.
            if [ "$port" = "$tport" ]; then
              echo "error: PORT y TELEMETRY_PORT son el mismo (:$port); elige otro con PORT=<puerto>" >&2
              exit 2
            fi
            busy=""
            holder_re='users:\(\("([^"]+)"'
            check_port() {
              local p="$1" role="$2" var="$3" line held=""
              line="$(ss -ltnpH "sport = :$p")"
              [ -z "$line" ] && return 0
              if [[ $line =~ $holder_re ]]; then
                held=" (lo tiene «''${BASH_REMATCH[1]}»)"
              fi
              echo "error: el puerto :$p del $role está ocupado$held; elige otro con $var=<puerto>" >&2
              busy=1
            }
            check_port "$port" backend PORT
            check_port "$tport" microservicio TELEMETRY_PORT
            [ -z "$busy" ] || exit 2

            echo "microservicio FastF1 → :$tport   (cache: $cache)"
            FASTF1_CACHE="$cache" \
              ${self'.packages.telemetry}/bin/telemetry-service --port "$tport" &
            tpid=$!
            pids=("$tpid")

            cleanup() {
              trap - EXIT INT TERM
              kill "''${pids[@]}" 2>/dev/null || true
              wait "''${pids[@]}" 2>/dev/null || true
            }
            trap cleanup EXIT INT TERM

            # Load the latest race once, alone, before the backend's 5 s ceiling
            # meets a process that has not loaded it yet.
            warned="la primera carga puede salir con datos de ejemplo"
            listening=""
            for _ in $(seq 60); do
              if [ -n "$(ss -ltnH "sport = :$tport")" ]; then listening=1; break; fi
              kill -0 "$tpid" 2>/dev/null || break
              sleep 1
            done
            if [ -z "$listening" ]; then
              echo "aviso: la última carrera no se pudo cargar (el microservicio no escucha en :$tport); $warned" >&2
            else
              warm="$(curl -sS -o /dev/null -m 120 -w '%{http_code} %{time_total}' \
                "http://127.0.0.1:$tport/fastf1/drivers/latest" 2>/dev/null || true)"
              read -r code secs <<<"$warm"
              secs="$(LC_ALL=C printf '%.1f' "''${secs:-0}")"
              if [ "$code" = 200 ]; then
                echo "última carrera en memoria ($secs s)"
              elif [ "$code" = 000 ]; then
                echo "aviso: la última carrera no se pudo cargar (sin respuesta en $secs s); $warned" >&2
              else
                echo "aviso: la última carrera no se pudo cargar (HTTP $code, $secs s); $warned" >&2
              fi
            fi

            echo "backend Servant   → :$port      (STATIC_DIR: ${self'.packages.frontend})"
            echo "                     web en http://127.0.0.1:$port/"

            PORT="$port" \
            TELEMETRY_PORT="$tport" \
            STATIC_DIR="${self'.packages.frontend}" \
              ${self'.packages.backend}/bin/backend &
            bpid=$!
            pids+=("$bpid")

            wait "$bpid" || true
          '';
        };

        apps.dev = {
          type = "app";
          program = "${self'.packages.dev}/bin/dashboardF1-dev";
        };

        # ── Comandos cortos de desarrollo ──
        #
        # These provide the ENVIRONMENT and run the code from the working tree,
        # not a copy in the store, so they run the script as edited instead of
        # the last committed one. Not hermetic, and that is the point.

        packages.live = pkgs.writeShellApplication {
          name = "dashboardF1-live";
          runtimeInputs = [ pythonEnv ];
          text = ''
            ${guardRoot}
            cd telemetry-service
            exec python live_table.py "$@"
          '';
        };

        packages.record = pkgs.writeShellApplication {
          name = "dashboardF1-record";
          runtimeInputs = [ pythonEnv ];
          text = ''
            ${guardRoot}
            if [ "$#" -lt 1 ]; then
              echo "uso: dashboardF1-record <fichero> [timeout_segundos]" >&2
              echo "     (o nix run .#record -- <fichero> [timeout_segundos])" >&2
              exit 2
            fi
            exec python telemetry-service/record_live.py "$@"
          '';
        };

        # No `runtimeInputs`: it uses the dev shell's cabal, which already has
        # zlib and pkg-config resolved. A second GHC here would link against a
        # different zlib and fail where `cabal build` succeeds.
        packages.test = pkgs.writeShellApplication {
          name = "dashboardF1-test";
          text = ''
            ${guardRoot}
            if ! command -v cabal >/dev/null 2>&1; then
              echo "error: no hay cabal en el PATH; entra antes a nix develop" >&2
              exit 2
            fi
            cabal build all
            exec cabal test all --test-show-details=direct "$@"
          '';
        };

        # Runs the binary `cabal build backend` leaves in the working tree, so a
        # code change needs no `nix build`. Its path carries the GHC and package
        # version, so it is located and never spelled out. The default port
        # stays off 8080, which another service holds on this machine;
        # `nix run .#api` finds whichever port this binds.
        packages.serve = pkgs.writeShellApplication {
          name = "dashboardF1-serve";
          runtimeInputs = [ pkgs.findutils ];
          text = ''
            ${guardRoot}
            binary="$(find dist-newstyle -type f -name backend -perm -u+x \
              -print -quit 2>/dev/null || true)"
            if [ -z "$binary" ]; then
              echo "error: no encuentro el binario. Corre antes: cabal build backend" >&2
              exit 2
            fi
            if [ ! -e result ]; then
              echo "aviso: no hay ./result, así que el bundle del frontend no se sirve." >&2
              echo "       Lo deja ahí nix build .#frontend; la API funciona igual." >&2
            fi
            export STATIC_DIR="''${STATIC_DIR:-result}"
            export PORT="''${PORT:-8097}"
            echo "backend → :$PORT   (STATIC_DIR: $STATIC_DIR)"
            echo "                     binario: $binary"
            exec "$binary"
          '';
        };

        apps.serve = {
          type = "app";
          program = "${self'.packages.serve}/bin/dashboardF1-serve";
        };

        # Without PORT it LOCATES the listening backend instead of assuming one:
        # a guessed port answers with whatever else is bound there, and a reply
        # from a stranger reads like a bug in ours. And `127.0.0.1`, not
        # `localhost`, which resolves to IPv6 while the backend binds v4.
        packages.api = pkgs.writeShellApplication {
          name = "dashboardF1-api";
          runtimeInputs = [ pkgs.curl pkgs.iproute2 ];
          text = ''
            port="''${PORT:-}"
            if [ -z "$port" ]; then
              port="$(ss -ltnpH 2>/dev/null \
                | awk '/"backend"/ { split($4, a, ":"); print a[length(a)]; exit }')"
            fi
            if [ -z "$port" ]; then
              echo "error: no hay ningún backend escuchando. Arráncalo, o di el puerto:" >&2
              echo "       PORT=8097 dashboardF1-api live" >&2
              exit 2
            fi
            exec curl -i -sS "http://127.0.0.1:$port/api/''${1:-live}"
          '';
        };

        apps.live = {
          type = "app";
          program = "${self'.packages.live}/bin/dashboardF1-live";
        };

        apps.record = {
          type = "app";
          program = "${self'.packages.record}/bin/dashboardF1-record";
        };

        apps.test = {
          type = "app";
          program = "${self'.packages.test}/bin/dashboardF1-test";
        };

        apps.api = {
          type = "app";
          program = "${self'.packages.api}/bin/dashboardF1-api";
        };

        # ── Haskell dev shell (backend + frontend source-level tooling) ──
        devShells.default = pkgs.mkShell {
          name = "dashboardF1-dev";
          packages = (with pkgs; [
            ghc
            cabal-install
            haskell-language-server
            ormolu
            stylish-haskell
            hlint
            pkg-config
          ]) ++ [
            devLauncher
            self'.packages.test
            self'.packages.serve
            self'.packages.api
            self'.packages.live
            self'.packages.record
          ];
          buildInputs = with pkgs; [
            zlib
          ];
          shellHook = ''
            echo "F1 Functional Dashboard — dev shell (Haskell)"
            echo "  backend : cabal run backend       # Servant en :8080 (Fase 0, sesión 3)"
            echo "  todo    : dashboardF1-dev         # microservicio + backend, STATIC_DIR desde el store"
            echo "  pruebas : dashboardF1-test        # cabal build all + cabal test all"
            echo "  servir  : dashboardF1-serve       # el binario de cabal, :8097, STATIC_DIR=result"
            echo "  api     : dashboardF1-api live    # curl -i a /api/live, con cabeceras"
            echo "  feed    : dashboardF1-live        # la tabla del directo, ahora"
            echo "  grabar  : dashboardF1-record <fichero> [segundos]"
          '';
        };

        # ── Python dev shell del microservicio FastF1 ──
        devShells.telemetry = pkgs.mkShell {
          name = "dashboardF1-telemetry";
          packages = [ pythonEnv ];
          shellHook = ''
            echo "telemetry-service — Python dev shell (FastF1)"
            echo "  correr:  cd telemetry-service && uvicorn main:app   (:8000)"
            echo "  o sin shell:  nix run .#telemetry -- --port 8000"
            echo "  feed en vivo: nix run .#live                  # la tabla, ahora"
            echo "  grabar feed : nix run .#record -- salida.txt 900"
          '';
        };
      };
    };
}
