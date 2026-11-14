{ lanIfaces }: # the interface allowlist configuration.nix builds for halogen and Open WebUI
{ lib, ... }:

# halogen on liltig's NPU: the local Qwen inference server on :8731, rootless podman, started by
# llm-start. Open WebUI (openwebui.nix) fronts it, and pi's classifier calls it directly.
#
# Models. Flash is served from the checkpoint mounted read-only at /models, with three more loaded
# beside it, all named in the one attrset below so llm-npu-fetch cannot drift: decider-4b, which
# outlives the guard because pi's classifier (pi/extensions/halogen-npu.ts) answers on it too;
# flux2-klein-4b, which answers image requests; and qwen3-embedding-0.6b, the knowledge-search
# model Open WebUI uses, ~0.8 GiB locked. HALOGEN_VISION_TOWER loads the 857 MB vision tower beside
# the checkpoint: unset, an image is a 400 and text behaviour is bit-identical.
#
# Agent guard. A preview and loud here: ordinary Read results scored 0.60 `Controversial` against a
# 0.25 flag, and real Write/Edit/Bash calls got held, so it is off. `watch` logs verdicts without
# holding, `hold` also stops the call.
#
# Records. Request records audit those flags, since the guard's log line gives a tool name, a byte
# count and a score, never the text. One JSON line per finished request, and a full store drops
# records rather than blocking one, so /records stays writable where /models is not.
# HALOGEN_RECORD_TEXT keeps only the text the guard judges: with no API key on this port, prompts,
# replies and thinking stay out.
#
# Volumes. /models is read-only apart from two read-write mounts nested over it: halogen writes
# <dir>/halogen-npu.hnpw for an own checkpoint and fetches programs under npu/, and it re-does the
# conversion after an update invalidates it, so writable there means a plain restart suffices.
#
# Commands. llm-npu-fetch needs a writable mount -- the container mounts /models :ro -- the clock
# pinned, and llm-stop first; Ctrl-C once the files land. qwen3-embedding-0.6b came with the image's
# huggingface_hub instead, and refetching it takes llm-stop too. llm-records lists the newest stores
# and llm-guard puts today's guard flags beside the health counters.

let
  # NPU models served beside Flash, plus the guard's mode; one attrset so llm-npu-fetch can't drift.
  npuEnv = {
    HALOGEN_NPU_MODELS = "decider-4b,flux2-klein-4b,qwen3-embedding-0.6b";
    HALOGEN_AGENT_GUARD = "off";
  };
  npuEnvArgs = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "-e ${k}=${v}") npuEnv);

  # turns/<UTC day>/<host>-<pid>-<ms>.jsonl, one request a line, plain JSON -- jq it.
  recordDir = "/home/cvandesande/.local/share/halogen-records";

  modelsDir = "/home/cvandesande/models/halogen-qwen3.8-flash-next";
in
{
  # Both levels named, as with Open WebUI's dir: tmpfiles makes an unmentioned intermediate
  # root-owned, then refuses the transition.
  systemd.tmpfiles.rules = [
    "d /home/cvandesande/.local/share 0700 cvandesande users -"
    "d ${recordDir} 0700 cvandesande users -"
  ];

  virtualisation.oci-containers = {
    backend = "podman";
    containers.halogen = {
      image = "ghcr.io/peonist-ai/halogen-flash-server:latest";
      pull = "always";
      autoStart = false;
      podman.user = "cvandesande";
      ports = [ "8731:8731" ]; # all addresses; the firewall rules below limit it to the LAN NIC
      volumes = [
        "${modelsDir}:/models:ro"
        # Nested over that mount, and writable where /models is not.
        "${modelsDir}/OvisOCR3:/models/OvisOCR3"
        "${modelsDir}/npu:/models/npu"
        "${recordDir}:/records"
      ];
      environment = npuEnv // {
        HALOGEN_RECORD_DIR = "/records";
        HALOGEN_RECORD_TEXT = "results,args";
        HALOGEN_TEMPERATURE = "1.0";
        HALOGEN_TOP_P = "0.95";
        HALOGEN_TOP_K = "20";
        HALOGEN_FORK = "1";
        HALOGEN_FORK_MAP = "claude-code";
        HALOGEN_CACHE_BRANCHES = "3";
        HALOGEN_KV8 = "1";
        HALOGEN_KV_POOL_POSITIONS = "925184";
        HALOGEN_VISION_TOWER = "1";
      };
      extraOptions = [
        # No --seccomp option, so podman's default profile applies.
        "--device=/dev/kfd"
        "--device=/dev/dri"
        "--device=/dev/accel/accel0" # the NPU
        "--ipc=host" # ROCm needs it
      ];
    };
  };

  # Inherited by the container: --ulimit memlock would be re-applied by podman exec from an
  # 8 MB-capped shell, which fails with crun EPERM.
  systemd.services.podman-halogen.serviceConfig.LimitMEMLOCK = "infinity";

  # Rootless pasta binds :8731 as an ordinary host socket, so INPUT gates it, v4 and v6 -- no
  # DOCKER-USER hook to maintain.
  networking.firewall.interfaces = lib.genAttrs lanIfaces (_: {
    allowedTCPPorts = [ 8731 ];
  });

  environment.shellAliases = {
    llm-start = "systemctl start podman-halogen";
    llm-stop = "systemctl stop podman-halogen";
    llm-status = "systemctl is-active podman-halogen";
    llm-update = "podman pull ghcr.io/peonist-ai/halogen-flash-server:latest";
    llm-npu-fetch = "podman run --rm -v ${modelsDir}:/models -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next ${npuEnvArgs} --device=/dev/kfd --device=/dev/dri --device=/dev/accel/accel0 --ipc=host ghcr.io/peonist-ai/halogen-flash-server:latest";
    llm-records = "ls -1t ${recordDir}/turns/*/*.jsonl 2>/dev/null | head -3";
    llm-guard = "curl -s localhost:8731/health | python3 -m json.tool | grep -A6 request_records; journalctl -u podman-halogen --since today --no-pager | grep 'agent guard' | tail -20";
  };
}
