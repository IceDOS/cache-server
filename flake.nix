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

      dockerStackPkg = pkgs.writeShellScriptBin "docker" ''
        env \
          ATTICD_BIN="${pkgs.attic-server}/bin/atticd" \
          ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64="$(sudo cat /etc/icedos-attic-secret)" \
          docker compose -f "${self}/stack/compose.yml" "$@"
      '';

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
      };

      devShells.${system} = {
        stack = pkgs.mkShell {
          buildInputs = with pkgs; [
            attic-client
            attic-server
          ];
          shellHook = ''
            export ATTICD_BIN="${pkgs.attic-server}/bin/atticd"
            export ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64="$(sudo cat /etc/icedos-attic-secret)"

            generate_attic_admin_token() {
              nix run .#stack.docker -- exec app "${pkgs.attic-server}/bin/atticadm" \
                -f /etc/attic/server.toml \
                make-token --sub admin --validity '100y' \
                --pull '*' --push '*' --create-cache '*' --configure-cache '*' --configure-cache-retention '*'
            }

            generate_attic_builder_token() {
              nix run .#stack.docker -- exec app "${pkgs.attic-server}/bin/atticadm" \
                -f /etc/attic/server.toml \
                make-token --sub ci --validity '1y' \
                --pull icedos --push icedos
            }
          '';
        };
      };

      packages.${system} = {
        stack.docker = dockerStackPkg;
      };
    };
}
