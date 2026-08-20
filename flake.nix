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

      # Foreground supervisor over three nix binaries — no container runtime.
      # replaceVarsWith fails the build on any unsubstituted @placeholder@.
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

        # Foreground; Ctrl-C or SIGTERM from a keep-alive wrapper drops the stack.
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
            # atticd runs on the host, so mint tokens with atticadm directly. Needs:
            #   export ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64="$(sudo cat /etc/icedos-attic-secret)"
            generate_attic_admin_token() {
              ${atticadm} -f ${self}/stack/conf/server.toml \
                make-token --sub admin --validity '100y' \
                --pull '*' --push '*' --create-cache '*' --configure-cache '*' --configure-cache-retention '*'
            }

            generate_attic_builder_token() {
              validity="''${1:-1y}"
              ${atticadm} -f ${self}/stack/conf/server.toml \
                make-token --sub ci --validity "$validity" \
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
