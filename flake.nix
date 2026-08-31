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
            with nixpkgs.legacyPackages.${system};
            writeShellScript "build" ''
              ${bash}/bin/bash ${./build.sh}
            ''
          );
        };

        icedos = icedosApp;
      };
    };
}
