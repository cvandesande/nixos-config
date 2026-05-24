{ lib, ... }:

{
  networking.networkmanager.enable = false;
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network = {
    enable = true;
    networks."10-dhcp" = {
      matchConfig.Name = [
        "en*"
        "eth*"
      ];
      networkConfig.DHCP = "yes";
    };
  };

  services = {
    displayManager.sddm.enable = lib.mkForce false;
    desktopManager.plasma6.enable = lib.mkForce false;
  };
}
