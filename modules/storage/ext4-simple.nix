{
  device,
  espSize ? "512M",
}:

{
  disko.devices.disk.main = {
    type = "disk";
    inherit device;

    content = {
      type = "gpt";

      partitions = {
        ESP = {
          size = espSize;
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };

        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
