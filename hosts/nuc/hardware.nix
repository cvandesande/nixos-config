{ pkgs, ... }:

{
  boot.initrd.kernelModules = [
    "i915"
  ];

  boot.kernelModules = [
    "nct6775"
  ];

  hardware.graphics = {
    extraPackages = with pkgs; [
      intel-vaapi-driver
      libvdpau-va-gl
    ];
  };

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "i965";
  };

  services.thermald.enable = true;
}
