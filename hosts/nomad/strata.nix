{ ... }:

# Strata on nomad's integrated Arc B390, the counterpart of liltig's halogen: rootless podman on
# 127.0.0.1:8081/v1, started by llm-start, no key in the store (it keeps its own under /data).
#
# Model. IQ2_XS, the largest pack that affords the 256K window (39.2 GB weights + ~5.6 GiB k8v4 KV,
# ~13 GiB spare after the OS; IQ3_XXS at 47 GB is too tight) and it keeps all 512 experts. Both
# packs stay on disk, so a switch back is one line. A container --memory limit does nothing here:
# xe pages are not charged to the cgroup and experts are mirrored in *pinned* host memory.
#
# Not Q2_0 (2026-11-15, same flags and probe): slower here, not faster. Its 37.6 GB native plus the
# same 28.8 GB PLE shard is only 4% fewer expert bytes per token, and the fused int8 prompt experts
# do not cover its gate/up rows on Xe3 - the engine logs "int8 path no" for all 48 layers where
# IQ2_XS answers yes for its 34 IQ2_S layers, so every layer falls back to FP16. 4K: 355 tok/s,
# TTFT 11.8 s, decode 12.9 against IQ2_XS's 432 / 9.9 / 16.9 (~/strata-bench/probes.jsonl,
# q2_0-live). MODELS.md's "Q2_0 = fastest" is CUDA, where MMQ has a Q2_0 kernel.
#
# Behaviour. Keep the image entrypoint: `strata launch --no-tui` daemonizes, PID 1 exits and the
# container dies as Exited (0) minutes later with no error logged. The first request after a start
# can stall 40-61 s at prompt layer 0 and abort (SIGABRT, exit -6); the next works, so warm it up
# and keep it up between sessions.
#
# Prefill (2026-11-14). INTEL.md gates the fused int8 prompt experts on a Battlemage B70/B580/B570
# detected by device architecture, so Xe3 gets none and `auto` stays on the FP16 chain; forcing
# them is 4K 329 -> 432 tok/s and TTFT 12.9 -> 9.9 s, decode unchanged, for ~4000 expert slots -
# hence STRATA_PREFILL_LEND_PCT=0, which returns the prompt loan and lands the full 24576.
# STRATA_PREFILL_TIMING=1 (undocumented; the string is in the 0.1.59-sycl binary) put 55% of a
# 9878-token prompt in the gate/up expert GEMM and 15% in dequantizing, so the rest of the gap is
# Xe3 kernel efficiency, not a knob (~/strata-bench/prefill-timing.tsv).
#
# Drafting. mtp-max-t=8 is the one arm with a mechanism the data supports: 45.8/46.8/46.5 tok/s
# over 3/3 reps at windows of T 3.69-3.70 and 78 ms, so one window cost serves 3.6 tokens instead
# of 1, and it changes nothing on unpredictable text (gen stayed 17.1-17.5). Dropped:
# lookup-chain=2 reached the engine but produced 0 chained drafts in every measured window, so its
# numbers came from the ordinary suffix path, and suffix-draft=4 lost to control (45.3 best rep
# against 42.2 median).
#
# Env values. 256K genuinely runs here: a 134k prompt answered correctly at 248 tok/s reused 131k
# of its tokens on the repeat. k8v4 (keys 8-bit, values rotated 4-bit) is 23% less KV than int8 -
# 5.6 GiB at 256K, so ~1100 more expert slots - and more precise than q4_0 on long documents; only
# int8/q4_0/k8v4/fp16 exist and int8 made 256K affordable. 24576 is the mtp measurement (33.02
# GiB); a dflash2 start falls to 6012-10169 slots and what drops out is mirrored and read per
# token, which stalls reasoning. expert-cache=auto lands on 12288 here, so 24576 is pinned
# explicitly, and it only lands when the RAM is genuinely free at start: the engine plans from
# MemAvailable (upstream #2412), so a busy-desktop start landed 13266 slots and a 16.85 GiB mirror
# and measured 3-4x slower on a 4K prompt - restart when idle. spec=6 reaches the engine,
# STRATA_KV_GROW=1 is inert (every start logs "--kv-grow is off"), STRATA_WATCHDOG_S=600 keeps a
# cold prefill from being aborted (#29), and the two STRATA_VERIFY_* keys are INTEL_ARC.md's Arc
# settings because the image has no strata-sycl.sh (#515).
#
# What the container can be told. The entrypoint reads env names and turns them into `strata
# launch` flags: MODEL, FAMILY, MODEL_PATH, CONTEXT, PARALLEL, KV, VISION, GPUS, GPU_ROLES, TUNE,
# TUNE_ALLOW_SMALL, PRESET, PORT, STRATA_SET; everything else comes from the preset in the volume,
# so a rebuild cannot reproduce it. `--set` merges per key, so an empty value cannot clear a stored
# one (`--delete-preset` does). Two flags are outside that list: `--access`, which hard-codes
# `--access lan` and binds 0.0.0.0 inside the container - loopback safety comes only from the
# published port - and `--drafting`, so mtp is preset-only.
#
# Naming. DOCKER.md: `qwen` for the original ISTA-DASLab packs. Rootless podman in a system unit:
# the container needs the user's /run/user/1000 alive and start/stop need sudo, because
# podman-strata.service is in the system manager. No --group-add for --device=/dev/dri, because
# renderD128 is 0666.

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
        STRATA_SET = "expert-cache=24576 spec=6 mtp-max-t=8 STRATA_KV_GROW=1 STRATA_WATCHDOG_S=600 STRATA_VERIFY_NO_HOST=1 STRATA_VERIFY_DEVICE_PLAN=1 SYCL_CACHE_PERSISTENT=0 STRATA_PREFILL_MMQ=1 STRATA_PREFILL_LEND_PCT=0";
        VISION = "off"; # no SYCL vision reader
      };
      extraOptions = [
        "--device=/dev/dri"
        "--shm-size=2g"
      ];
    };
  };

  # Inherited: podman exec re-applies --ulimit memlock from an 8 MB-capped shell (crun EPERM).
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
