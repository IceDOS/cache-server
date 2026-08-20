{
  config,
  inputs,
  lib,
  ...
}:

let
  inherit (lib) mkForce;
in
{
  boot.isContainer = true;

  # systemd-boot is a core module (enable defaults true); disable it for the
  # container builds so they need no ESP mountPoint (now a required option).
  icedos.system.bootloaders.systemd-boot.enable = false;

  # isContainer (container-config.nix) forces boot.kernel.enable = false, which
  # drops the kernel from system.build.toplevel — so the cache-server never built
  # or cached any kernel (cachyos or default). Force it back on and pull the kernel
  # into the closure so it is actually built, signed and uploaded.
  boot.kernel.enable = mkForce true;
  nixpkgs.hostPlatform = "x86_64-linux";
  system.extraDependencies = [ config.boot.kernelPackages.kernel ];

  # isContainer (container-config.nix) also sets services.udev.enable = false. A
  # module that enables udev then hard-conflicts: the sunshine-headless forged EDID
  # sets hardware.display.edid.packages, and services/hardware/display.nix responds
  # with services.udev.enable = true. Both are normal priority, so the eval aborts.
  # Force udev on (as on a real, non-container system) so the EDID firmware + udev
  # rules land in the closure and the conflict resolves.
  services.udev.enable = lib.mkForce true;

  # `nix.registry` is `mapAttrs (_: v: { flake = v; }) inputs` (core/modules/nix.nix),
  # so it carries an entry for `self` — the GENERATED state flake. core/build.sh
  # rewrites `build/.state/flake.nix` on every invocation, and a `path:` flake's
  # `lastModified` is its mtime, so that entry gets a fresh wall-clock stamp per run
  # even when narHash and content are byte-identical. That re-hashes
  # etc-nix-registry.json -> etc -> activate -> system.build.toplevel, which would
  # keep every CI run producing a brand-new (and therefore never-cached) toplevel.
  # Repoint `self` at the config snapshot, whose store path pins lastModified to 1.
  nix.registry.self = mkForce { flake = inputs.icedos-config; };
}
