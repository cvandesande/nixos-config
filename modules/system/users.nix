{ ... }:

{
  users.users.cvandesande = {
    isNormalUser = true;
    extraGroups = [ "docker" "wheel" "networkmanager" ];
  };
}
