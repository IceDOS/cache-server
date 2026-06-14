{ ... }:
{
  # Prevent bootloader error
  boot.isContainer = true;

  nixpkgs.hostPlatform = "x86_64-linux";
}
