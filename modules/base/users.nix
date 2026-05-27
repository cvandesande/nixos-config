{ ... }:

{
  users.groups.plugdev = { };
  users.users.cvandesande = {
    isNormalUser = true;
    description = "Chris";
    extraGroups = [
      "plugdev"
      "wheel"
    ];
  };
}
