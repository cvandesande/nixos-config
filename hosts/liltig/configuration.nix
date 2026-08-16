{
  config,
  lib,
  ...
}:

{
  imports = [
    ../../modules/roles/workstation.nix
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4086d232";
      swapSize = "32G";
    })
  ];

  networking.hostName = "liltig";
  networking.hostId = "534d981c";

  time.timeZone = "Europe/Dublin";
  system.stateVersion = "26.05";

  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # No local ZFS pools (LUKS+btrfs storage), opt out of global workstation ZFS.
  workstation.zfs.enable = false;

  # Strix Halo Vulkan/RADV: 110 GiB GTT aperture and no unified-memory IOMMU overhead.
  boot.kernelParams = [
    "ttm.pages_limit=28835840"
    "ttm.page_pool_size=28835840"
  ];

  # Prioritize inference throughput and disable higher-latency CPU idle states.
  services.tuned = {
    enable = true;
    ppdSupport = false;
    recommend.accelerator-performance = { };
  };

  # Strix Halo local LLM using llama-swap's current Vulkan llama.cpp build.
  virtualisation.oci-containers = {
    backend = "docker";
    containers.llama-swap = {
      image = "ghcr.io/mostlygeek/llama-swap:vulkan";
      autoStart = false;
      ports = [ "127.0.0.1:8080:8080" ];
      volumes = [
        "/home/cvandesande/models:/models:ro"
        "/home/cvandesande/.config/llama-swap/config.yaml:/app/config.yaml:ro"
      ];
      # /dev/dri is the whole GPU requirement on Vulkan; /dev/kfd would only be
      # needed by a ROCm image. Both nodes are mode 0666, so no group-add.
      extraOptions = [ "--device=/dev/dri" ];
    };
  };

  environment.shellAliases = {
    llm-start  = "systemctl start docker-llama-swap";
    llm-stop   = "systemctl stop docker-llama-swap";
    llm-status = "systemctl is-active docker-llama-swap";
  };

  fileSystems."/home/cvandesande/mnt/whiterock" = {
    device = "whiterock:/zfspool/Downloads";
    fsType = "nfs4";
    options = [
      "defaults"
      "noauto"
      "noatime"
      "users"
      "bg"
      "x-systemd.mkdir"
    ];
  };
}
