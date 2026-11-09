{ lanIfaces }: # the interface allowlist configuration.nix builds for halogen, strixDash and Open WebUI
{ lib, ... }:

# halogen: the local Qwen/NPU inference server on :8731, rootless podman; Open WebUI (openwebui.nix) fronts it.
let
  # NPU models served beside Flash, plus the guard's mode; one attrset so llm-npu-fetch below cannot drift.
  # qwen3-embedding-0.6b: Open WebUI's knowledge search, ~0.8 GiB locked; fetched with the image's huggingface_hub, not llm-npu-fetch (needs llm-stop).
  npuEnv = {
    # decider-4b outlives the guard: pi's classifier (`pi/extensions/halogen-npu.ts`) answers on it too.
    HALOGEN_NPU_MODELS = "decider-4b,flux2-klein-4b,qwen3-embedding-0.6b";
    # The guard is a preview and loud here: ordinary Read results scored 0.60 `Controversial` against a 0.25 flag, and real Write/Edit/Bash calls got held. `watch` logs verdicts without holding, `hold` also stops the call.
    HALOGEN_AGENT_GUARD = "off";
  };
  npuEnvArgs = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "-e ${k}=${v}") npuEnv);

  # Request records audit those flags -- the guard's log line gives a tool name, a byte count and a score, never the text.
  recordDir = "/home/cvandesande/.local/share/halogen-records";

  # The checkpoint volume, read-only at /models; the two paths halogen itself writes get a narrow read-write mount below.
  modelsDir = "/home/cvandesande/models/halogen-qwen3.8-flash-next";
in
{
  # Both levels named, as with Open WebUI's dir: tmpfiles makes an unmentioned intermediate root-owned, then refuses the transition.
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
        # Nested over that mount: halogen writes <dir>/halogen-npu.hnpw for an own checkpoint and fetches programs under npu/,
        # and it re-does the conversion after an update that invalidates it -- writable here means a plain restart suffices.
        "${modelsDir}/OvisOCR3:/models/OvisOCR3"
        "${modelsDir}/npu:/models/npu"
        # Writable, unlike /models: one JSON line per finished request, and a full store drops records rather than blocking one.
        "${recordDir}:/records"
      ];
      environment = npuEnv // {
        # Only the text the guard judges: with no API key on this port, prompts, replies and thinking stay out.
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
        # Loads the 857 MB vision tower beside the checkpoint; unset, an image is a 400 and text behaviour is bit-identical.
        HALOGEN_VISION_TOWER = "1";
      };
      extraOptions = [
        "--device=/dev/kfd"
        "--device=/dev/dri"
        "--device=/dev/accel/accel0" # the NPU
        "--ipc=host" # ROCm needs it
        # No --ulimit=memlock (see LimitMEMLOCK below) and no seccomp option, so podman's default profile applies.
      ];
    };
  };

  # Inherited by the container, unlike --ulimit=memlock=-1:-1, which podman exec then fails to re-apply from an 8 MB-capped shell (crun EPERM).
  systemd.services.podman-halogen.serviceConfig.LimitMEMLOCK = "infinity";

  # Rootless pasta binds :8731 as an ordinary host socket, so INPUT gates it, v4 and v6 -- no DOCKER-USER hook to maintain.
  networking.firewall.interfaces = lib.genAttrs lanIfaces (_: {
    allowedTCPPorts = [ 8731 ];
  });

  environment.shellAliases = {
    llm-start = "systemctl start podman-halogen";
    llm-stop = "systemctl stop podman-halogen";
    llm-status = "systemctl is-active podman-halogen";
    llm-update = "podman pull ghcr.io/peonist-ai/halogen-flash-server:latest";
    # One-off NPU model fetch: needs a writable mount (runtime is :ro), the clock pinned, and llm-stop first; Ctrl-C once the files land.
    llm-npu-fetch = "podman run --rm -v ${modelsDir}:/models -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next ${npuEnvArgs} --device=/dev/kfd --device=/dev/dri --device=/dev/accel/accel0 --ipc=host ghcr.io/peonist-ai/halogen-flash-server:latest";
    # Newest first: turns/<UTC day>/<host>-<pid>-<ms>.jsonl, one request a line, plain JSON -- jq it.
    llm-records = "ls -1t ${recordDir}/turns/*/*.jsonl 2>/dev/null | head -3";
    # Store counters plus today's guard flags: curl -s localhost:8731/health | jq .request_records for the store alone.
    llm-guard = "curl -s localhost:8731/health | python3 -m json.tool | grep -A6 request_records; journalctl -u podman-halogen --since today --no-pager | grep 'agent guard' | tail -20";
  };
}
