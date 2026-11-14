{ pkgs, ... }:

# OpenVINO Model Server on the NPU: Qwen3-8B-int4-cw, OpenAI API on 127.0.0.1:8000/v3/chat/completions, started by ovms-start.
# Qwen3-30B-A3B-nf4-ov also runs but is ~7x slower here and needs the NPUW prefill/token chunk sizes (see ~/npu-test).
let
  image = "docker.io/openvino/model_server:latest-gpu"; # GPU image also ships the NPU driver
  # Mounted over the model dir: OVMS only generates graph.pbtxt itself when it downloads the model.
  graph = pkgs.writeText "graph.pbtxt" ''
    input_stream: "HTTP_REQUEST_PAYLOAD:input"
    output_stream: "HTTP_RESPONSE_PAYLOAD:output"

    node: {
      name: "LLMExecutor"
      calculator: "HttpLLMCalculator"
      input_stream: "LOOPBACK:loopback"
      input_stream: "HTTP_REQUEST_PAYLOAD:input"
      input_side_packet: "LLM_NODE_RESOURCES:llm"
      output_stream: "LOOPBACK:loopback"
      output_stream: "HTTP_RESPONSE_PAYLOAD:output"
      input_stream_info: {
        tag_index: 'LOOPBACK:0',
        back_edge: true
      }
      node_options: {
        [type.googleapis.com / mediapipe.LLMCalculatorOptions]: {
          models_path: "/model"
          device: "NPU" # change to GPU or CPU to compare
          # The DEVICE_PROPERTIES form in the OVMS docs is silently ignored for NPU; static shapes fix the window at compile time.
          # Prefix caching reuses a shared prompt prefix: 8.6s -> 2.9s on follow-up turns at ~5K tokens. First compile ~16 min.
          plugin_config: '{"MAX_PROMPT_LEN": 32768, "MIN_RESPONSE_LEN": 4096, "NPUW_LLM_ENABLE_PREFIX_CACHING": true}'
        }
      }
      input_stream_handler {
        input_stream_handler: "SyncSetInputStreamHandler",
        options {
          [mediapipe.SyncSetInputStreamHandlerOptions.ext] {
            sync_set {
              tag_index: "LOOPBACK:0"
            }
          }
        }
      }
    }
  '';
in
{
  # The uid is read for RequiresMountsFor; linger now comes from strata.nix, which owns the LLM role here.
  users.users.cvandesande.uid = 1000;

  virtualisation.oci-containers = {
    backend = "podman";
    containers.openvino = {
      inherit image;
      pull = "always";
      autoStart = false;
      podman.user = "cvandesande";
      ports = [ "127.0.0.1:8000:8000" ];
      volumes = [
        "/home/cvandesande/models/Qwen3-8B-int4-cw-ov:/model:ro"
        "${graph}:/graph/graph.pbtxt:ro"
        # The compile cache ignores some NPUW options and can serve a stale blob ("Cannot find tensor for port"): bump it when they change.
        "/var/cache/openvino-npu-v2:/cache"
      ];
      cmd = [
        "--model_name"
        "qwen3-8b"
        "--model_path"
        "/graph"
        "--cache_dir"
        "/cache"
        "--rest_port"
        "8000"
      ];
      extraOptions = [
        "--device=/dev/accel"
        "--device=/dev/dri"
        # renderD128 and accel0 are 0666, so rootless needs no --group-add gid.
      ];
    };
  };

  # Inherited by the container; --ulimit=memlock is not re-applied by podman exec from an 8 MB-capped shell (crun EPERM).
  systemd.services.podman-openvino.serviceConfig.LimitMEMLOCK = "infinity";

  # World-writable: the container runs as an unprivileged uid.
  systemd.tmpfiles.rules = [ "d /var/cache/openvino-npu-v2 0777 root root -" ];

  # Nothing prunes rootless storage, so pull = "always" piles up each superseded :latest-gpu; named images and volumes survive.
  systemd.user.services.podman-dangling-prune = {
    description = "Remove dangling container images";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.podman}/bin/podman image prune -f";
    };
  };
  systemd.user.timers.podman-dangling-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      RandomizedDelaySec = "4h";
      Persistent = true; # a laptop is not on when the week turns
    };
  };

  # The NPU experiment keeps its own names now that llm-* means Strata (strata.nix).
  environment.shellAliases = {
    ovms-start = "systemctl start podman-openvino";
    ovms-stop = "systemctl stop podman-openvino";
    ovms-status = "systemctl is-active podman-openvino";
    ovms-update = "podman pull docker.io/openvino/model_server:latest-gpu";
  };
}
