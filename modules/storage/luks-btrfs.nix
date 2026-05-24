{
  device,
  encryptedName ? "crypted",
  espSize ? "1G",
  swapSize,
  swapRandomEncryption ? true,
  swapPriority ? 100,
  swapDiscardPolicy ? "both",
  btrfsMountOptions ? [
    "compress=zstd:3"
    "noatime"
    "discard=async"
  ],
  allowDiscards ? true,
}:

let
  luksPartition = {
    content = {
      type = "luks";
      name = encryptedName;

      settings = {
        inherit allowDiscards;
      };

      content = {
        type = "btrfs";
        extraArgs = [ "-f" ];

        subvolumes = {
          "@" = {
            mountpoint = "/";
            mountOptions = btrfsMountOptions;
          };

          "@home" = {
            mountpoint = "/home";
            mountOptions = btrfsMountOptions;
          };

          "@nix" = {
            mountpoint = "/nix";
            mountOptions = btrfsMountOptions;
          };

          "@log" = {
            mountpoint = "/var/log";
            mountOptions = btrfsMountOptions;
          };

          "@snapshots" = {
            mountpoint = "/.snapshots";
            mountOptions = btrfsMountOptions;
          };
        };
      };
    };
    end = "-${swapSize}";
  };

  swapPartition = {
    size = "100%";
    content = {
      type = "swap";
      randomEncryption = swapRandomEncryption;
      priority = swapPriority;
      discardPolicy = swapDiscardPolicy;
    };
  };
in
{
  disko.devices = {
    disk.main = {
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

          luks = luksPartition;
          swap = swapPartition;
        };
      };
    };
  };
}
