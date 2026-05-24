{ pkgs, ... }:

{
  boot.initrd.kernelModules = [
    "i915"
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
}
