{ config, lib, ... }:
{
  # Prevent bootloader error
  boot.isContainer = true;

  nixpkgs.hostPlatform = "x86_64-linux";

  # isContainer (container-config.nix) forces boot.kernel.enable = false, which
  # drops the kernel from system.build.toplevel — so the cache-server never built
  # or cached any kernel (cachyos or default). Force it back on and pull the kernel
  # into the closure so it is actually built, signed and uploaded.
  boot.kernel.enable = lib.mkForce true;
  system.extraDependencies = [ config.boot.kernelPackages.kernel ];
}
