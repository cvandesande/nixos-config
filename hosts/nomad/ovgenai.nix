{
  lib,
  pkgs,
  ...
}:

# Qwen3-30B-A3B-nf4-ov on nomad's NPU: an OpenAI-compatible endpoint on 127.0.0.1:8020/v1 (8021 for
# the 8B), started by ov-start and the NPU counterpart of strata/halogen -- on demand, nothing
# resident until asked. Replaces OpenVINO Model Server, which lost here on every axis: it needed a
# hand-written graph, must pin the static window that this NF4 MoE export then fails to shape-infer
# without NPUW chunk options, ships NPU driver 1.35 (older than the 1.38 Intel released for Panther
# Lake), and served the 30B at 2-3 tok/s where the same library in-process does 30. See
# hosts/nomad/ovgenai/server.py for the shim and HANDOFF.md for the full history.
#
# Context size. 8192 is the usable ceiling here and is what gets compiled: NPU prefill is padded to
# MAX_PROMPT_LEN, so time-to-first-token is set by the pinned window, not by the prompt -- documented
# Intel behaviour, measured on this box: TTFT 11 s at 4096, 35 s at 8192, 72 s at 12288, 1124 s at
# 16384, and 32768 fails shape inference outright (garbage-dim reshape, even with the NPUW trio).
# 12288 does compile (1053 s cold) but pays ~72 s per request for that window, and Intel's own docs
# recommend the NPU only up to ~8K context. The dynamic-prefill escape hatch (NPUW_LLM_PREFILL_CHUNK_SIZE
# < MAX_PROMPT_LEN, which should make TTFT track the real prompt) is exactly what breaks shape
# inference on this MoE export. pi/models.json therefore declares 12288 although the server pins
# 8192: pi reserves a fixed 4096-token safety margin plus the reply budget out of the *declared*
# window before computing max_tokens, so an honest 8192 declaration starves every request to
# max_tokens: 1 (measured). 12288 is the smallest declaration under which a slim session
# (`pi --no-extensions`, system+tools ~2k tokens) gets its full 2048-token budget while the physical
# prompt still fits the compiled 8192 -- requests over the compiled window error rather than
# truncate. A full interactive session does not fit any window this device can compile: pi's MCP tool
# schemas alone tokenize to ~14.5k Qwen tokens, and pi's budget floor then needs a declared window
# of ~24k; that workload belongs on strata.
#
# Why no container: the container's only real job was carrying the NPU driver, and Intel's images
# carry the wrong version of it, so it would have had to install Intel's debs by hand anyway. Here
# Nix unpacks those debs (pkgs/intel-npu-userspace.nix) and pip pins the engine
# (hosts/nomad/ovgenai/requirements.txt), which is both smaller and checkable.
#
# Env. The pip openvino wheel carries the NPU *plugin* but not the *compiler* (a 130 MB blob) or the
# level-zero driver, so LD_LIBRARY_PATH has to carry the unpacked debs plus nixpkgs' level-zero
# loader, zlib, libstdc++ and libzstd. ZE_ENABLE_ALT_DRIVERS is what makes that loader look in a
# store path; without it the NPU is invisible and GenAI falls back to CPU silently. No LimitMEMLOCK:
# that was a container-only need, host runs work at the default 8 MB memlock.
#
# Versions. nixpkgs is not usable for the engine: openvino is 2026.1.2 there and intel-npu-driver is
# 1.28.0, and this export wants 2026.4.1 plus 1.38. The venv is therefore pip-installed from the
# pinned requirements file rather than built by Nix, so it is versioned by that file, not flake.lock.
#
# Compile cache. NPU blobs are keyed loosely and can be served stale after an NPUW_* change (the
# classic symptom is `Cannot find tensor for port`), so the cache directory carries a version and
# gets bumped whenever PLUGIN_CONFIG changes. First compile is a few minutes (297 s for the 8192
# window); reload from cache ~7 s.
#
# Static window. MAX_PROMPT_LEN is pinned here because GenAI's default (1024) is smaller than any
# real prompt. Pinning it is what drags in the NPUW MoE chunk options: without them shape inference
# dies with a garbage dimension. Both live in PLUGIN_CONFIG together for that reason.
let
  npuUserspace = pkgs.callPackage ../../pkgs/intel-npu-userspace.nix { };

  # zstd is not decoration: libopenvino_intel_npu_compiler.so dlopen()s libzstd.so.1, and without
  # it the compiler fails to load at first pipeline build ("Failed to load compiler library ... \
  # libzstd.so.1"), which only surfaces on the first start, after the venv step hid it.
  runtimeLibs = lib.makeLibraryPath [
    pkgs.level-zero
    pkgs.zlib
    pkgs.zstd
    pkgs.stdenv.cc.cc.lib
  ];

  stateDir = "/var/lib/ovgenai";
  venv = "${stateDir}/venv";
  src = ./ovgenai; # server.py + requirements.txt, copied to the store with the flake

  cacheVersion = "v1";

  # name -> what to serve. Ports are separate so two models can be up at once, though one NPU means
  # they share compile and inference throughput.
  models = {
    "30b" = {
      path = "/home/cvandesande/models/Qwen3-30B-A3B-nf4-ov";
      port = 8020;
      # HOST_ROUTED is what keeps the MoE experts off the NPU graph; DENSE and DEVICE_ROUTED either
      # fail shape inference or run far slower here.
      pluginConfig = "{\"NPUW_LLM_PREFILL_CHUNK_SIZE\":8192,\"NPUW_MOE_TOKEN_CHUNK_SIZE\":1024,\"NPUW_LLM_PREFILL_MOE_HINT\":\"HOST_ROUTED\"}";
      maxPromptLen = "8192";
      maxNewTokens = "4096";
    };
    "8b" = {
      path = "/home/cvandesande/models/Qwen3-8B-int4-cw-ov";
      port = 8021;
      pluginConfig = "{}";
      maxPromptLen = "8192";
      maxNewTokens = "4096";
    };
  };

  serviceFor = name: cfg: {
    description = "ovgenai OpenAI endpoint for ${name} on the NPU";
    documentation = [ "https://huggingface.co/OpenVINO/Qwen3-30B-A3B-nf4-ov" ];

    # Ordering-only entries draw the "ordered after but doesn't depend on" eval warning; the model
    # units need no network themselves (local venv, local model, loopback bind), and network-online
    # reaches them through ovgenai-init, which is a hard requirement and carries the wants itself.
    requires = [ "ovgenai-init.service" ];
    after = [ "ovgenai-init.service" ];

    # On demand, like strata and halogen: nothing is resident until ov-start says so.
    wantedBy = [ ];

    environment = {
      LD_LIBRARY_PATH = "${npuUserspace}/lib:${runtimeLibs}";
      ZE_ENABLE_ALT_DRIVERS = "${npuUserspace}/lib/libze_intel_npu.so";
      HOME = stateDir;
      OV_DISABLE_TELEMETRY = "1";
      MODEL_NAME = "qwen3-${name}";
      MODEL_PATH = cfg.path;
      DEVICE = "NPU";
      CACHE_DIR = "${stateDir}/cache/${cacheVersion}-${name}";
      MAX_PROMPT_LEN = cfg.maxPromptLen;
      MAX_NEW_TOKENS = cfg.maxNewTokens;
      PLUGIN_CONFIG = cfg.pluginConfig;
      # This export always emits reasoning; the shim splits it into reasoning_content. See HANDOFF.md.
      ENABLE_THINKING = "false";
    };

    serviceConfig = {
      Type = "simple";
      User = "cvandesande";
      Group = "users";
      StateDirectory = "ovgenai";
      # First start after a requirements bump downloads wheels, and the first NPU compile adds
      # minutes; systemd's default 90 s would kill both.
      TimeoutStartSec = "1800";
      ExecStart = ''
        ${venv}/bin/uvicorn --app-dir ${src} server:app --host 127.0.0.1 --port ${toString cfg.port}
      '';
      Restart = "on-failure";
      RestartSec = "5s";
      # Loopback only, so the absent API key stays a non-issue.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ stateDir ];
      # Models are mounted by path, so the read-only root must not hide the home tree.
      ReadOnlyPaths = [ cfg.path ];
    };
  };

in
{
  # One attrset: `systemd.services` twice would be a duplicate attribute. The shared venv is built by
  # its own oneshot -- it needs network -- and skipped once the marker binary is there. Bump
  # requirements and delete /var/lib/ovgenai/venv to force a rebuild.
  systemd.services =
    lib.mapAttrs' (
      name: cfg:
      lib.nameValuePair "ovgenai-${name}" (serviceFor name cfg)
    ) models
    // {
      ovgenai-init = {
        description = "Build the ovgenai virtualenv from the pinned requirements";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "cvandesande";
          Group = "users";
          StateDirectory = "ovgenai";
          # No NetworkAddress=on here: unknown key on this systemd, ignored with a warning; the
          # unit is manual-start anyway and orders after network-online for PyPI fetches.
          # The present-venv check is deliberately a file test, not an import: init runs without
          # LD_LIBRARY_PATH, where `import openvino_genai` always dies on libstdc++ even in a
          # healthy venv -- the guard would then run `uv venv` over an existing one, which uv
          # refuses (exit 2, INVALIDARGUMENT) and the model unit never starts.
          ExecStart = pkgs.writeShellScript "ovgenai-init" ''
            set -euo pipefail
            if [ -x ${venv}/bin/uvicorn ] && [ -n "$(ls -d ${venv}/lib/python*/site-packages/openvino_genai 2>/dev/null)" ]; then
              echo "ovgenai venv present, skipping install"
              exit 0
            fi
            ${pkgs.uv}/bin/uv venv ${venv} --python ${pkgs.python3}/bin/python3
            ${pkgs.uv}/bin/uv pip install --python ${venv}/bin/python -r ${src}/requirements.txt
          '';
        };
      };
    };

  # Root-owned so uv can write it as the service user.
  systemd.tmpfiles.rules = [ "d ${stateDir} 0755 cvandesande users -" ];

  # No sudo: polkit lets an active local session manage these units (the state dir is user-owned
  # too), same shape as halogen's llm-start.
  environment.shellAliases = {
    ov-start = "systemctl start ovgenai-30b";
    ov-start-8b = "systemctl start ovgenai-8b";
    ov-stop = "systemctl stop ovgenai-30b ovgenai-8b";
    ov-status = "systemctl status 'ovgenai-*' --no-pager | grep -E '●|Active'";
    ov-logs = "journalctl -u ovgenai-30b -f";
    ov-rebuild-venv = "rm -rf ${venv} && systemctl restart ovgenai-init";
  };
}
