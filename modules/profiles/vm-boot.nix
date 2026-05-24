{ lib, ... }:

{
  boot = {
    loader = {
      timeout = 3;
      systemd-boot = {
        enable = true;
        configurationLimit = lib.mkDefault 3;
        editor = false;
      };
      efi.canTouchEfiVariables = true;
    };

    consoleLogLevel = 4;
    initrd.systemd.enable = true;
  };
}
