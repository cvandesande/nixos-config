{ pkgs, ... }:

{
  services = {
    # YubiKey/FIDO2 support
    udev.packages = [
      pkgs.libfido2
      pkgs.yubikey-personalization
    ];
  };

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          # Shows battery charge of connected devices on supported Bluetooth
          # adapters.
          Experimental = true;
          # Lets other devices connect faster at the cost of increased power
          # consumption.
          FastConnectable = true;
        };
      };
    };

    sane = {
      enable = true;
      extraBackends = [ pkgs.epsonscan2 ];
    };
  };
}
