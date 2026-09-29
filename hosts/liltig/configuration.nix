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
  # ppdSupport = false is load-bearing: with it true, tuned's power-profiles
  # compatibility layer applies its own profile and overrides recommend.
  services.tuned = {
    enable = true;
    ppdSupport = false;
    recommend.accelerator-performance = { };
  };

  # The tuned module puts the package in systemd.packages, so upstream
  # tuned-ppd.service is linked and started through its own [Install] section
  # even though ppdSupport is false. It then exits 1 because /etc/tuned/ppd.conf
  # is only generated when ppdSupport is true. Skip it instead of failing.
  systemd.services.tuned-ppd.unitConfig.ConditionPathExists = "/etc/tuned/ppd.conf";

  # Strix Halo local LLM: Qwen3.8-Flash-Next with MTP speculative decoding.
  # The GGUF has no MTP head, so it is loaded from the shared sidecar file via
  # --spec-draft-model. Stock llama.cpp cannot do this until upstream PR #28243
  # merges, so the image overlays Unsloth's pinned Vulkan build (b11160) on the
  # upstream Vulkan image. It is built locally, not pulled:
  #   docker build -t llama-server-unsloth:b11160-mix-a6922cc hosts/liltig/llama-server
  virtualisation.oci-containers = {
    backend = "docker";
    containers.llama-server = {
      image = "llama-server-unsloth:b11160-mix-a6922cc";
      autoStart = false;
      ports = [ "127.0.0.1:8080:8080" ];
      volumes = [ "/home/cvandesande/models:/models:ro" ];
      entrypoint = "/opt/unsloth/llama-server";
      cmd = [
        "--host" "0.0.0.0"
        "--port" "8080"
        "--alias" "qwen3.8-flash-next-coding"
        "--model" "/models/Qwen3.8-Flash-Next/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf"
        "--ctx-size" "262144"
        "--n-gpu-layers" "999"
        # ctx and ngl are explicit, so --fit has nothing to adjust.
        "--fit" "off"
        "--flash-attn" "on"
        "--jinja"
        "--cache-type-k" "q8_0"
        "--cache-type-v" "q8_0"
        "--parallel" "1"
        "--cache-reuse" "256"
        "--temp" "1.0"
        "--top-p" "0.95"
        "--top-k" "20"
        "--min-p" "0.00"
        "--spec-type" "draft-mtp"
        "--spec-draft-model" "/models/Qwen3.8-Flash-Next/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
        "--spec-draft-ngl" "999"
        "--spec-draft-n-max" "5"
        "--no-reasoning-preserve"
        "--reasoning" "on"
        "--reasoning-budget-message" "Reasoning budget reached. Stop deliberating and implement the approved task using the available tools."
      ];
      # /dev/dri is the whole GPU requirement on Vulkan; /dev/kfd would only be
      # needed by a ROCm image. Both nodes are mode 0666, so no group-add.
      extraOptions = [ "--device=/dev/dri" ];
    };
  };

  environment.shellAliases = {
    llm-start  = "systemctl start docker-llama-server";
    llm-stop   = "systemctl stop docker-llama-server";
    llm-status = "systemctl is-active docker-llama-server";
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
