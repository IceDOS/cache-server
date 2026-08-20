{
  config,
  icedosLib,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkForce;
in
{
  boot.isContainer = true;

  # Core module, enabled by default; container builds have no ESP mountPoint.
  icedos.system.bootloaders.systemd-boot.enable = false;

  # isContainer forces boot.kernel.enable = false, dropping the kernel from
  # system.build.toplevel — so no kernel was ever built, signed or uploaded.
  boot.kernel.enable = mkForce true;
  nixpkgs.hostPlatform = "x86_64-linux";

  # systemPackages only reaches the toplevel via system.path, whose buildEnv links to LEAF
  # targets — so a symlink farm (cudaPackages.cudatoolkit) is never a closure reference.
  system.extraDependencies = [
    config.boot.kernelPackages.kernel
  ]
  ++ icedosLib.pkgs.mapper pkgs config.icedos.system.packages;

  # isContainer also disables udev, which conflicts at normal priority with modules that
  # enable it (sunshine-headless's forged EDID sets hardware.display.edid.packages).
  services.udev.enable = lib.mkForce true;

  # `self` is the GENERATED state flake, rewritten every run, and a path: flake's
  # lastModified is its mtime — which re-hashes etc -> activate -> toplevel every run.
  nix.registry.self = mkForce { flake = inputs.icedos-config; };
}
