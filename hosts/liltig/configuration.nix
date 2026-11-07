{ inputs, ... }:

let
  lib = inputs.nixpkgs.lib;
  # NPU models served beside Flash, plus the guard's mode; one attrset so the
  # llm-npu-fetch alias below cannot drift from the container.
  npuEnv = {
    HALOGEN_NPU_MODELS = "halogen-spotter-0.6b,decider-4b,flux2-klein-4b";
    HALOGEN_AGENT_GUARD = "watch";
  };
  npuEnvArgs = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "-e ${k}=${v}") npuEnv);

  # Where halogen may be reached: any ethernet or wifi NIC (`+` is iptables' name-prefix
  # wildcard), so moving between the USB dongle, the onboard port and wifi needs no edit.
  # Docker bridges, veths and tunnels are not listed, so they are refused.
  lanIfaces = [
    "en+"
    "wl+"
  ];
  # Docker DNATs published ports straight into FORWARD, past the firewall's INPUT chain, so
  # networking.firewall.interfaces cannot gate them. DOCKER-USER runs first in FORWARD. The
  # DROP goes in first and each RETURN is inserted above it, leaving [RETURN... DROP] with
  # no moment where the port is open, even across a firewall reload.
  halogenMatch = "-p tcp -m conntrack --ctstate DNAT --ctorigdstport 8731";
  halogenRules = [
    "${halogenMatch} -j DROP"
  ]
  ++ map (i: "${halogenMatch} -i ${i} -j RETURN") lanIfaces;
in
{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
    ./claude-router.nix
    (import ./strixdash.nix { inherit lanIfaces; })
    ../../modules/roles/workstation.nix
    # by-path (PCI slot) rather than by-id: a by-id name is the drive's serial
    # (vendor OUI + unit number) and this repository is public. Slot names are
    # stable for a given bay, and Disko is the only consumer — the running system
    # mounts /dev/disk/by-partlabel/disk-main-* instead. Re-run Disko after a drive
    # move with the new path.
    (import ../../modules/storage/luks-btrfs.nix {
      device = "/dev/disk/by-path/pci-0000:c1:00.0-nvme-1";
      swapSize = "32G";
    })
  ];

  networking.hostName = "liltig";
  networking.hostId = "534d981c";

  time.timeZone = "Europe/Dublin";
  system.stateVersion = "26.05";

  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false; # UsePAM defeats this
  };

  workstation.zfs.enable = false;

  services.tuned = {
    enable = true;
    ppdSupport = false;
    recommend.accelerator-performance = { };
  };

  systemd.services.tuned-ppd.unitConfig.ConditionPathExists = "/etc/tuned/ppd.conf";

  # halogen's NPU needs the fabric clock pinned or it corrupts results and can hang the host
  # (ROCm/TheRock#8709). Row 7 = 2000 MHz, fclk only; keyed on the GPU's PCI function.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="drm", KERNELS=="0000:c2:00.0", ATTR{device/power_dpm_force_performance_level}="manual", ATTR{device/pp_dpm_fclk}="7"
  '';

  virtualisation.oci-containers = {
    backend = "docker";
    containers.halogen = {
      image = "ghcr.io/peonist-ai/halogen-flash-server:latest";
      pull = "always";
      autoStart = false;
      ports = [ "8731:8731" ]; # all addresses; the firewall rules below limit it to the LAN NIC
      volumes = [ "/home/cvandesande/models/halogen-qwen3.8-flash-next:/models:ro" ];
      environment = npuEnv // {
        HALOGEN_TEMPERATURE = "1.0";
        HALOGEN_TOP_P = "0.95";
        HALOGEN_TOP_K = "20";
        HALOGEN_FORK = "1";
        HALOGEN_FORK_MAP = "claude-code";
        HALOGEN_CACHE_BRANCHES = "3";
        HALOGEN_KV8 = "1";
        HALOGEN_KV_POOL_POSITIONS = "925184";
        # Accept image content: loads the 857 MB vision tower that sits beside the
        # checkpoint. Unset, an image is a 400 and text behaviour is bit-identical.
        HALOGEN_VISION_TOWER = "1";
      };
      extraOptions = [
        "--device=/dev/kfd"
        "--device=/dev/dri"
        "--device=/dev/accel/accel0" # the NPU
        "--ipc=host" # ROCm needs it
        "--ulimit=memlock=-1:-1"
      ];
    };
  };

  networking.firewall = {
    # IPv4 is DNATed past INPUT (see halogenRules); this opens the IPv6 docker-proxy path.
    interfaces = lib.genAttrs lanIfaces (_: {
      allowedTCPPorts = [ 8731 ];
    });
    # DOCKER-USER may not exist yet if the firewall starts before dockerd; dockerd keeps it.
    # -C guard: a firewall reload re-runs this and must not stack duplicate rules.
    extraCommands = ''
      iptables -N DOCKER-USER 2>/dev/null || true
      ${lib.concatMapStringsSep "\n" (
        r: "iptables -C DOCKER-USER ${r} 2>/dev/null || iptables -I DOCKER-USER ${r}"
      ) halogenRules}
    '';
    extraStopCommands = lib.concatMapStringsSep "\n" (
      r: "iptables -D DOCKER-USER ${r} 2>/dev/null || true"
    ) halogenRules;
  };

  virtualisation.docker.autoPrune = {
    enable = true;
    dates = "weekly";
  };

  systemd.services.docker.restartIfChanged = false; # a restart kills the container

  environment.shellAliases = {
    llm-start = "systemctl start docker-halogen";
    llm-stop = "systemctl stop docker-halogen";
    llm-status = "systemctl is-active docker-halogen";
    llm-update = "docker pull ghcr.io/peonist-ai/halogen-flash-server:latest";
    # One-off fetch of the NPU models: needs a writable mount (runtime is :ro), the clock
    # pinned, and llm-stop first. Ctrl-C once the files land. Shares npuEnv with the unit.
    llm-npu-fetch = "docker run --rm -v /home/cvandesande/models/halogen-qwen3.8-flash-next:/models -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next ${npuEnvArgs} --device=/dev/kfd --device=/dev/dri --device=/dev/accel/accel0 --ipc=host --ulimit=memlock=-1:-1 ghcr.io/peonist-ai/halogen-flash-server:latest";
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
