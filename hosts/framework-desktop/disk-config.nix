{ ... }:

{
  disko.devices = {
    disk.main = {
      type = "disk";

      # Replace this with the real NVMe device from:
      #   ls -l /dev/disk/by-id/ | grep nvme
      #
      # Prefer a stable /dev/disk/by-id path over /dev/nvme0n1.
      device = "/dev/disk/by-id/YOUR_NVME_DEVICE";

      content = {
        type = "gpt";

        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };

          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "crypted";

              settings = {
                allowDiscards = true;
                fallbackToPassword = true;
              };

              content = {
                type = "btrfs";
                extraArgs = [ "-f" ];

                subvolumes = {
                  "@" = {
                    mountpoint = "/";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };

                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };

                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };

                  "@log" = {
                    mountpoint = "/var/log";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };

                  "@snapshots" = {
                    mountpoint = "/.snapshots";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
