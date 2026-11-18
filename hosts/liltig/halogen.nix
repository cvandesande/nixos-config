{ lanIfaces }: # the interface allowlist configuration.nix builds for halogen and Open WebUI
{ lib, ... }:

# halogen on liltig's NPU: the local Qwen inference server on :8731, rootless podman, started by
# llm-start. Open WebUI (openwebui.nix) fronts it, and pi's classifier calls it directly.
#
# Models. Flash plus four NPU models, all named in npuEnv below so llm-npu-fetch cannot drift:
# decider-4b, which pi's classifier answers on; qwen3-embedding-0.6b for knowledge search; and the
# speech pair behind the mic and speaker -- ASR on the NPU, its vocoder on the CPU, both the 1.7B
# of their pair (naming both sizes is refused). The pair stays locked at ~4 GiB and ~5 GiB, so it
# and the embedder share one pool and the driver can answer ret -28; the server closes the idle
# parts and retries, answer unchanged.
#
# Guard. Off: ordinary Read results scored 0.60 `Controversial` against a 0.25 flag and real
# Write/Edit/Bash calls got held; `watch` logs verdicts without holding. Request records audit the
# flags, since the guard's log line gives a tool name and a score, never the text.

let
  # NPU models served beside Flash, plus the guard's mode; one attrset so
  # llm-npu-fetch can't drift.
  npuEnv = {
    HALOGEN_NPU_MODELS = "decider-4b,qwen3-embedding-0.6b,qwen3-asr-1.7b,qwen3-tts-1.7b-customvoice";
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
        # Nested over that mount, writable where /models is not: halogen writes its .hnpw and
        # refetches programs here, so a conversion an update invalidates just needs a restart.
        "${modelsDir}/OvisOCR3:/models/OvisOCR3"
        "${modelsDir}/npu:/models/npu"
        "${recordDir}:/records"
      ];
      environment = npuEnv // {
        HALOGEN_RECORD_DIR = "/records";
        # results and args only: with no API key on this port, prompts and replies stay out.
        HALOGEN_RECORD_TEXT = "results,args";
        HALOGEN_TEMPERATURE = "1.0";
        HALOGEN_TOP_P = "0.95";
        HALOGEN_TOP_K = "20";
        HALOGEN_FORK = "1";
        HALOGEN_FORK_MAP = "claude-code";
        HALOGEN_CACHE_BRANCHES = "3";
        HALOGEN_KV8 = "1";
        HALOGEN_KV_POOL_POSITIONS = "925184";
        # loads the 857 MB vision tower beside the checkpoint; unset, an image is a 400
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
    # needs a writable /models mount and llm-stop first; Ctrl-C once the files land
    llm-npu-fetch = "podman run --rm -v ${modelsDir}:/models -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next ${npuEnvArgs} --device=/dev/kfd --device=/dev/dri --device=/dev/accel/accel0 --ipc=host ghcr.io/peonist-ai/halogen-flash-server:latest";
    llm-records = "ls -1t ${recordDir}/turns/*/*.jsonl 2>/dev/null | head -3";
    # Voice without a browser: llm-say speaks a line to a WAV, llm-asr reads that file back.
    llm-say = "curl -s localhost:8731/v1/audio/speech -H 'Content-Type: application/json' -d '{\"model\":\"qwen3-tts-1.7b-customvoice\",\"voice\":\"ryan\",\"input\":\"Hello from the NPU.\"}' -o /tmp/halogen-say.wav";
    llm-asr = "curl -s localhost:8731/v1/audio/transcriptions -F model=qwen3-asr-1.7b -F file=@/tmp/halogen-say.wav";
    llm-guard = "curl -s localhost:8731/health | python3 -m json.tool | grep -A6 request_records; journalctl -u podman-halogen --since today --no-pager | grep 'agent guard' | tail -20";
  };
}
