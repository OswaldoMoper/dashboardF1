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
      in
      {
        # ── Backend Servant (Fase 1: /home + /api/* en :8080, override con PORT) ──
        packages.backend = hp.backend;
        packages.default = self'.packages.backend;

        # ── Frontend Reflex (GHCJS) — Fase 0 skeleton ──
        # Copia el .jsexe compilado + el index.html propio, listo para servir.
        packages.frontend = pkgs.runCommand "dashboardF1-frontend" { } ''
          mkdir -p $out
          cp -r ${frontendJs}/bin/frontend.jsexe/. $out/
          install -m644 ${./frontend/index.html} $out/index.html
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
          text = ''
            port="''${PORT:-8080}"
            tport="''${TELEMETRY_PORT:-8000}"
            # `FASTF1_CACHE` en vez de un `cd`
            cache="''${FASTF1_CACHE:-$PWD/telemetry-service/.fastf1-cache}"

            echo "microservicio FastF1 → :$tport   (cache: $cache)"
            FASTF1_CACHE="$cache" \
              ${self'.packages.telemetry}/bin/telemetry-service --port "$tport" &
            tpid=$!

            echo "backend Servant   → :$port      (STATIC_DIR: ${self'.packages.frontend})"
            echo "                     web en http://127.0.0.1:$port/"

            PORT="$port" \
            TELEMETRY_PORT="$tport" \
            STATIC_DIR="${self'.packages.frontend}" \
              ${self'.packages.backend}/bin/backend &
            bpid=$!

            cleanup() {
              trap - EXIT INT TERM
              kill "$tpid" "$bpid" 2>/dev/null || true
              wait "$tpid" "$bpid" 2>/dev/null || true
            }
            trap cleanup EXIT INT TERM

            wait "$bpid" || true
          '';
        };

        apps.dev = {
          type = "app";
          program = "${self'.packages.dev}/bin/dashboardF1-dev";
        };

        # ── Haskell dev shell (backend + frontend source-level tooling) ──
        devShells.default = pkgs.mkShell {
          name = "dashboardF1-dev";
          packages = with pkgs; [
            ghc
            cabal-install
            haskell-language-server
            ormolu
            stylish-haskell
            hlint
            pkg-config
          ];
          buildInputs = with pkgs; [
            zlib
          ];
          shellHook = ''
            echo "F1 Functional Dashboard — dev shell (Haskell)"
            echo "  backend : cabal run backend   # Servant en :8080 (Fase 0, sesión 3)"
            echo "  todo    : nix run .#dev       # microservicio + backend, STATIC_DIR desde el store"
          '';
        };

        # ── Python dev shell del microservicio FastF1 ──
        devShells.telemetry = pkgs.mkShell {
          name = "dashboardF1-telemetry";
          packages = [ pythonEnv ];
          shellHook = ''
            echo "telemetry-service — Python dev shell (FastF1, Fase 4)"
            echo "  correr:  cd telemetry-service && uvicorn main:app   (:8000)"
            echo "  o sin shell:  nix run .#telemetry -- --port 8000"
          '';
        };
      };
    };
}
