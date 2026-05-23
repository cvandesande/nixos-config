{ ... }:

{
  disko.devices = {
    disk.main = {
      type = "disk";

      device = "/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4086d232";

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
