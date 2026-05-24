{ ... }:

{
  users.users.cvandesande = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };
}
