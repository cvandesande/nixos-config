{ ... }:

{
  users.groups.plugdev = { };
  users.users.cvandesande = {
    isNormalUser = true;
    extraGroups = [
      "plugdev"
      "wheel"
    ];
  };
}
