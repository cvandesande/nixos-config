{
  config,
  lib,
  ...
}:

{
  imports = [
    ./claude-router.nix
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

    # Trial alternative to llama-server: halogen-flash-server, a closed-source
    # ROCm engine built for gfx1151 only. It also speaks the Anthropic Messages
    # API (/v1/messages), and claude-router sends local requests to it.
    # Weights (v2 checkpoint, n-gram table, MTP head, tokenizer) come from
    #   hf download peonist-ai/halogen-qwen3.8-flash-next --local-dir ~/models/halogen-qwen3.8-flash-next
    # HALOGEN_DOWNLOAD is unset, so the container makes no outbound connection
    # and /models stays read-only. Shipped defaults otherwise.
    containers.halogen = {
      image = "ghcr.io/peonist-ai/halogen-flash-server:0.18.7@sha256:8dee1b88821369c62f33d8d523bdf5785ed5b6945793268bae557fb69a26863f";
      autoStart = false;
      ports = [ "127.0.0.1:8731:8731" ];
      volumes = [ "/home/cvandesande/models/halogen-qwen3.8-flash-next:/models:ro" ];
      # Claude Code sends no sampling fields, and halogen decodes such requests
      # greedy, which can loop inside the think block at long context. Default
      # to the model card's thinking settings (the llama-server values above).
      # A request that sends its own values still wins.
      environment = {
        HALOGEN_TEMPERATURE = "1.0";
        HALOGEN_TOP_P = "0.95";
        HALOGEN_TOP_K = "20";
        # Keep each Claude Code thread's state (main conversation and every
        # subagent) so its next request starts from it. Needs no client
        # setting; claude-router passes the session headers through.
        HALOGEN_FORK = "1";
        HALOGEN_FORK_MAP = "claude-code";
      };
      # ROCm needs /dev/kfd as well as /dev/dri (both mode 0666, so no
      # group-add). The GPU runtime dies at startup without --ipc=host.
      extraOptions = [
        "--device=/dev/kfd"
        "--device=/dev/dri"
        "--ipc=host"
        "--ulimit=memlock=-1:-1"
      ];
    };
  };

  systemd.services = {
    # halogen (~89 GiB) and llama-server (~100 GiB) do not fit together, and
    # memory pressure wedges halogen rather than failing it. Starting either
    # stops the other (Conflicts= is symmetric); the ordering makes the stop
    # finish before the start.
    docker-halogen = {
      conflicts = [ "docker-llama-server.service" ];
      after = [ "docker-llama-server.service" ];
    };

    # system.autoUpgrade switches live, and a docker.service restart takes the LLM
    # container (and any in-flight generation) down with it. Keep the running
    # daemon across switches; the new docker takes effect at the next reboot.
    docker.restartIfChanged = false;
  };

  # llm-* follow the backend claude-router sends local requests to (halogen).
  # llama-server stays available as the fallback; switching back also needs
  # the router's --local port changed to 8080.
  environment.shellAliases = {
    llm-start  = "systemctl start docker-halogen";
    llm-stop   = "systemctl stop docker-halogen";
    llm-status = "systemctl is-active docker-halogen";
    llamacpp-start  = "systemctl start docker-llama-server";
    llamacpp-stop   = "systemctl stop docker-llama-server";
    llamacpp-status = "systemctl is-active docker-llama-server";
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
