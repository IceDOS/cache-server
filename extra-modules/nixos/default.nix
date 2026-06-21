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

  # isContainer (container-config.nix) also sets services.udev.enable = false. A
  # module that enables udev then hard-conflicts: the sunshine-headless forged EDID
  # sets hardware.display.edid.packages, and services/hardware/display.nix responds
  # with services.udev.enable = true. Both are normal priority, so the eval aborts.
  # Force udev on (as on a real, non-container system) so the EDID firmware + udev
  # rules land in the closure and the conflict resolves.
  services.udev.enable = lib.mkForce true;
}
