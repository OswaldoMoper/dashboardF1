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
        jsPkgs = reflexPkgs.pkgsCross.ghcjs.haskell.packages.ghc910;
        frontendJs = jsPkgs.callCabal2nix "frontend" ./frontend { };
      in
      {
        # ── Backend Servant (Fase 0: endpoint /home en :8080, override con PORT) ──
        packages.backend = pkgs.haskellPackages.callCabal2nix "backend" ./backend { };
        packages.default = self'.packages.backend;

        # ── Frontend Reflex (GHCJS) — Fase 0 skeleton ──
        # Copia el .jsexe compilado + el index.html propio, listo para servir.
        packages.frontend = pkgs.runCommand "dashboardF1-frontend" { } ''
          mkdir -p $out
          cp -r ${frontendJs}/bin/frontend.jsexe/. $out/
          install -m644 ${./frontend/index.html} $out/index.html
        '';

        # `nix run .#backend` (o `nix run`) — levanta el backend.
        apps.backend = {
          type = "app";
          program = "${self'.packages.backend}/bin/backend";
        };
        apps.default = self'.apps.backend;

        # ── Haskell dev shell (backend + frontend source-level tooling) ──
        devShells.default = pkgs.mkShell {
          name = "dashboardF1-dev";
          packages = with pkgs; [
            ghc
            cabal-install
            haskell-language-server
            ormolu
            hlint
          ];
          shellHook = ''
            echo "F1 Functional Dashboard — dev shell (Haskell)"
            echo "  backend : cabal run backend   # Servant en :8080 (Fase 0, sesión 3)"
          '';
        };

        # ── Python dev shell del microservicio FastF1 (Fase 4) ──
        devShells.telemetry = pkgs.mkShell {
          name = "dashboardF1-telemetry";
          packages = with pkgs; [
            python3
            python3Packages.pip
            python3Packages.virtualenv
          ];
          shellHook = ''
            echo "telemetry-service — Python dev shell (FastF1, Fase 4)"
            echo "  deps declaradas en telemetry-service/requirements.txt (sin lógica aún)"
          '';
        };
      };
    };
}
