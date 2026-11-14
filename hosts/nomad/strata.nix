{ ... }:

# Strata on nomad's integrated Arc B390: the counterpart of liltig's halogen. Rootless podman on
# 127.0.0.1:8081/v1, started by llm-start, and no key in the store (Strata keeps its own under /data).
#
# Memory. Strata plans from host RAM and xe pages aren't charged to the cgroup, so a container
# --memory limit does nothing here, and experts are mirrored in *pinned* host memory. IQ2_XS is the
# largest pack that affords the 256K window: 39.2 GB of weights + ~5.6 GiB of k8v4 KV + the OS leaves
# ~13 GiB spare, and it keeps all 512 experts, so it is better than Coder outside code and for
# non-English. IQ3_XXS (47 GB) leaves too little headroom at 256K.
#
# Behaviour. Keep the image entrypoint: `strata launch --no-tui` daemonizes, PID 1 exits and the
# container dies as Exited (0) minutes later with no error logged. The first request after a start
# sometimes stalls 40-61 s at prompt layer 0 and aborts (SIGABRT, exit -6); the next request works, so
# warm it up and keep the container up between sessions.
#
# Numbers behind the env. 256K is the model's own window and genuinely runs here: a 134k prompt
# answered correctly at 248 tok/s prefill and reused 131k of its 134k tokens on the repeat. k8v4 puts
# keys at 8-bit and values at rotated 4-bit: 23% less KV than int8 (~5.6 GiB at 256K, so ~1100 more
# expert slots), more precise than q4_0 on long documents, prompts 2-5% slower (DETAILS.md); only
# int8/q4_0/k8v4/fp16 exist, and int8 was what made 256K affordable. 24576 is the mtp measurement
# (33.02 GiB); a dflash2 start falls to 6012-10169 slots here, and what drops out of the cache is
# mirrored and read per token, which is what stalls reasoning. STRATA_SET is `--set` only and
# presets merge per key, so an empty value cannot clear a stored one (--delete-preset does);
# expert-cache=auto is DETAILS.md's default and lands on 12288 slots here, so 24576 is pinned
# explicitly. `spec=6` and `STRATA_KV_GROW=1` (the documented `--kv-grow`, an opt-in setting read by
# getenv in the SYCL backend) were set to save memory and lift tok/s and desktop responsiveness, and
# both reach the engine on every start. STRATA_WATCHDOG_S=600 keeps a cold prefill from being
# aborted (#29), and the last two are INTEL_ARC.md's Arc settings because the image has no
# strata-sycl.sh (#515).
#
# What the container can be told. The image's entrypoint reads env names and turns them into
# `strata launch` flags: MODEL, FAMILY, MODEL_PATH, CONTEXT, PARALLEL, KV, VISION, GPUS, GPU_ROLES,
# TUNE, TUNE_ALLOW_SMALL, PRESET, PORT, STRATA_SET. Everything else is read from the preset in the
# volume, so those values live there and a rebuild cannot reproduce them (`--set` merges per key and
# an empty value cannot clear a stored one; `--delete-preset` does). `--access` is not in the
# entrypoint's list: it hard-codes `--access lan`, so the engine binds 0.0.0.0 inside the container and
# loopback safety comes only from the published port. `--drafting` is not in it either, so mtp is
# preset-only here.
#
# Naming. DOCKER.md: use `qwen` for the original ISTA-DASLab packs. Rootless podman in a system unit:
# the container needs the user's /run/user/1000 to stay alive, and start/stop need sudo because
# podman-strata.service is in the system manager. Rootless needs no --group-add for --device=/dev/dri
# because renderD128 is 0666.

let
  image = "ghcr.io/niko1221/strata:latest-sycl";
  user = "cvandesande";
  home = "/home/${user}";
  family = "qwen";
  model = "IQ2_XS"; # a symlink under ~/models pointing at the folder holding the shards
  modelsDir = "${home}/models/${model}";
  dataDir = "${home}/strata-data";
in
{
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
      podman.user = user;
      ports = [ "127.0.0.1:8081:8080" ]; # loopback, so the key stays a local secret
      volumes = [
        "${modelsDir}:/models:ro"
        "${dataDir}:/data"
      ];
      environment = {
        FAMILY = family;
        MODEL = model;
        MODEL_PATH = "/models";
        PRESET = "docker";
        PORT = "8080";
        CONTEXT = "256k";
        TUNE = "skip";
        ALLOW_DOWNLOAD = "0"; # /models is read-only: a download would fetch tens of GB
        KV = "k8v4";
        STRATA_SET = "expert-cache=24576 spec=6 STRATA_KV_GROW=1 STRATA_WATCHDOG_S=600 STRATA_VERIFY_NO_HOST=1 STRATA_VERIFY_DEVICE_PLAN=1 SYCL_CACHE_PERSISTENT=0";
        VISION = "off"; # no SYCL vision reader
      };
      extraOptions = [
        "--device=/dev/dri"
        "--shm-size=2g"
      ];
    };
  };

  # Inherited by the container: --ulimit memlock would be re-applied by podman exec from an
  # 8 MB-capped shell, which fails with crun EPERM.
  systemd.services.podman-strata = {
    serviceConfig.LimitMEMLOCK = "infinity";
  };

  environment.shellAliases = {
    llm-start = "sudo systemctl start podman-strata";
    llm-stop = "sudo systemctl stop podman-strata";
    llm-status = "systemctl is-active podman-strata";
    llm-update = "podman pull ${image}";
    llm-key = "podman exec strata strata launch --show-key --preset docker";
    llm-logs = "journalctl -u podman-strata -f";
    llm-engine = "podman exec strata strata logs --follow";
  };
}
