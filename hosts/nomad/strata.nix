{ pkgs, ... }:

# Strata on the integrated Arc B390: nomad's counterpart of liltig's halogen. Rootless
# podman on 127.0.0.1:8081/v1, started by llm-start, no key in the store (Strata keeps one in /data).
#
# No container --memory limit: Strata plans from host RAM and xe pages aren't charged to the cgroup,
# so strata-watchdog below watches the host. Keep the image entrypoint: `strata launch --no-tui`
# daemonizes, PID 1 exits and the container dies as Exited (0) minutes later with no error logged.
let
  image = "ghcr.io/niko1221/strata:latest-sycl";
  user = "cvandesande";
  home = "/home/${user}";
  # Model to serve. Coder IQ1_M is here because it fits: ~35 GiB used, ~26 GiB spare. Gyro-M is the
  # better model but needs so much more that the box crawls (a 53-token warmup took 39 s; see notes).
  family = "coder";
  model = "IQ1_M"; # a symlink under ~/models pointing at the folder holding that model's shards
  packName = "${family}-${pkgs.lib.toLower model}";
  modelsDir = "${home}/models/${model}";
  # Packs, engine state, launch presets and the generated key. Rebuild-safe: nothing here is built.
  dataDir = "${home}/strata-data";
  packDir = "${dataDir}/Strata-data/packs/${packName}";

  # Built once, then it lives in the volume. Single-file packs need this because the Intel launcher's
  # multi-shard glob misses them (runner.py gates on find_shards, adopt.py on find_single).
  preparePack = pkgs.writeShellScript "strata-prepare-pack" ''
    set -eu
    if [ -d ${packDir} ]; then exit 0; fi
    ${pkgs.podman}/bin/podman run --rm --entrypoint sh \
      -v ${dataDir}:/data -v ${modelsDir}:/models:ro ${image} \
      '${pkgs.coreutils}/bin/mkdir' -p /data/Strata-data/packs && \
      /opt/strata/terminal/python/bin/python3 /opt/strata/terminal/setup.py \
        --prepare-pack /data/Strata-data/packs/${packName} \
        --gguf-dir /models --family ${family} --model ${model}
  '';

  # The iGPU shares the RAM pool, so this watches MemAvailable/SwapFree, not the container's usage.
  watchdog = pkgs.writeShellScript "strata-watchdog" ''
    set -uo pipefail
    CONTAINER=strata AVAIL_FLOOR=5 SWAP_FLOOR=2
    logger -t strata-watchdog "watching $CONTAINER: stop if MemAvailable < ''${AVAIL_FLOOR}G or SwapFree < ''${SWAP_FLOOR}G"
    while true; do
      avail=$(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo)
      swapfree=$(awk '/SwapFree/{printf "%d", $2/1048576}' /proc/meminfo)
      if ${pkgs.podman}/bin/podman ps -q -f name="^$CONTAINER$" | grep -q . && \
         { [ "$avail" -lt "$AVAIL_FLOOR" ] || [ "$swapfree" -lt "$SWAP_FLOOR" ]; }; then
        logger -t strata-watchdog "host low (MemAvailable ''${avail}G, SwapFree ''${swapfree}G) -> stopping $CONTAINER"
        ${pkgs.podman}/bin/podman stop -t 20 "$CONTAINER" || true
        exit 0
      fi
      sleep 3
    done
  '';
in
{
  # Rootless podman in a system unit: the container needs the user's /run/user/1000 to stay alive.
  users.users.${user}.linger = true;

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0700 ${user} users -"
  ];

  virtualisation.oci-containers = {
    backend = "podman";
    containers.strata = {
      inherit image;
      pull = "always";
      autoStart = false;
      podman.user = user; # the attrname is the container name: "strata", what the watchdog watches
      ports = [ "127.0.0.1:8081:8080" ]; # loopback only: the key stays a local secret
      volumes = [
        "${modelsDir}:/models:ro" # MODEL_PATH: nothing is downloaded for the model itself
        "${dataDir}:/data"
      ];
      environment = {
        FAMILY = family;
        MODEL = model;
        MODEL_PATH = "/models";
        # 256k is the model's own window and genuinely runs here: a 134k prompt answered correctly at
        # 248 tok/s prefill and reused 131k of its 134k tokens on the repeat. ~29 KiB/token at int8.
        CONTEXT = "256k";
        KV = "int8"; # engine default, and what makes 256k affordable; only int8/q4_0/k8v4/fp16 exist
        # `--set` only; presets merge per key, so an empty value cannot clear a stored one (--delete-preset does).
        # expert-cache=auto is DETAILS.md's default (it lands on 12288 slots here); 600 s so a cold prefill isn't aborted (#29).
        # The last three are INTEL_ARC.md's Arc settings: the image has no strata-sycl.sh, so nothing sets them (#515).
        STRATA_SET = "expert-cache=auto STRATA_WATCHDOG_S=600 STRATA_VERIFY_NO_HOST=1 STRATA_VERIFY_DEVICE_PLAN=1 SYCL_CACHE_PERSISTENT=0";
        VISION = "off"; # no SYCL vision reader, and it would fetch a 0.9 GB mmproj
      };
      extraOptions = [
        "--device=/dev/dri" # renderD128 is 0666, so rootless needs no --group-add
        "--shm-size=2g"
      ];
    };
  };

  # Inherited by the container, unlike --ulimit=memlock=-1:-1, which podman exec then fails to
  # re-apply from an 8 MB-capped shell (crun EPERM). Strata mirrors experts in *pinned* host memory.
  # The first request after a start sometimes stalls 40-61 s at prompt layer 0 and aborts (SIGABRT,
  # exit -6); the next request works, so warm it up and keep the container up between sessions.
  systemd.services.podman-strata = {
    serviceConfig.LimitMEMLOCK = "infinity";
    # Builds the pack into the volume on first start (skipped once it exists).
    preStart = "${preparePack}";
  };

  # Always on and idle: it only acts when the container is up and the host runs short.
  systemd.user.services.strata-watchdog = {
    description = "Stop Strata before this unified-memory laptop runs out of RAM";
    after = [ "network-online.target" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = watchdog;
      Restart = "always";
      RestartSec = "5"; # re-arms after a kill, in case the plan is lowered and restarted
    };
  };

  # podman-strata.service is a system unit (rootless container, system manager), so start/stop need sudo.
  environment.shellAliases = {
    llm-start = "sudo systemctl start podman-strata";
    llm-stop = "sudo systemctl stop podman-strata";
    llm-status = "systemctl is-active podman-strata";
    llm-update = "podman pull ${image}";
    llm-key = "podman exec strata strata launch --show-key --preset docker"; # rewrites the preset's choices file
    llm-logs = "journalctl -u podman-strata -f";
    llm-engine = "podman exec strata strata logs --follow"; # the log file is NUL-separated: grepping it needs tr '\0' '\n'
  };
}
