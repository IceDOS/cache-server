{
  inputs = {
    icedos = {
      url = "github:IceDOS/core";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };
  };

  outputs =
    {
      icedos,
      nixpkgs,
      self,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      atticd = "${pkgs.attic-server}/bin/atticd";
      atticadm = "${pkgs.attic-server}/bin/atticadm";

      # The whole stack is a foreground supervisor running three nix binaries
      # (atticd + nginx + caddy) — no container runtime, no daemon. Binary and
      # config store paths are baked into the @placeholders@ here; replaceVarsWith
      # also fails the build if any placeholder is left unsubstituted.
      supervisor = pkgs.replaceVarsWith {
        src = ./stack/supervisor.sh;
        name = "icedos-cache";
        dir = "bin";
        isExecutable = true;

        replacements = {
          inherit atticd;
          nginx = "${pkgs.nginx}/bin/nginx";
          caddy = "${pkgs.caddy}/bin/caddy";
          server = "${self}/stack/conf/server.toml";
          nginxconf = "${self}/stack/conf/nginx.conf";
          caddyfile = "${self}/stack/conf/Caddyfile";
        };
      };

      icedosApp =
        (icedos.lib.mkIceDOS {
          configRoot = self;
          stateDir = "build/.state";
        }).apps.${system}.default;
    in
    {
      apps.${system} = {
        build = {
          type = "app";
          program = toString (
            with pkgs;
            writeShellScript "build" ''
              ${bash}/bin/bash ${./build.sh}
            ''
          );
        };

        icedos = icedosApp;

        # `nix run .#stack` brings the whole stack up in the foreground; Ctrl-C
        # (or SIGTERM from a systemd/OpenRC keep-alive wrapper) drops it.
        stack = {
          type = "app";
          program = "${supervisor}/bin/icedos-cache";
        };
      };

      devShells.${system} = {
        stack = pkgs.mkShell {
          buildInputs = with pkgs; [
            attic-client
            attic-server
          ];
          shellHook = ''
            # atticd runs on the host, so mint tokens with atticadm directly.
            # Requires the JWT secret in the environment, e.g.:
            #   export ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64="$(sudo cat /etc/icedos-attic-secret)"
            generate_attic_admin_token() {
              ${atticadm} -f ${self}/stack/conf/server.toml \
                make-token --sub admin --validity '100y' \
                --pull '*' --push '*' --create-cache '*' --configure-cache '*' --configure-cache-retention '*'
            }

            generate_attic_builder_token() {
              ${atticadm} -f ${self}/stack/conf/server.toml \
                make-token --sub ci --validity '1y' \
                --pull icedos --push icedos
            }
          '';
        };
      };

      packages.${system} = {
        inherit supervisor;
      };
    };
}
