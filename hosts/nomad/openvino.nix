{ config, pkgs, ... }:

# OpenVINO Model Server (OpenAI-compatible API on 127.0.0.1:8000, /v3/chat/completions),
# the nomad counterpart of liltig's halogen container. Not started at boot: use llm-start.
#
# Qwen3-8B-int4-cw on the NPU with a 32768-token prompt window (first compile takes ~16 min, then cached in /var/cache/openvino-npu-v2) (the NPU graph uses
# static shapes, so the window is fixed at compile time). Qwen3-30B-A3B-nf4-ov also runs on
# the NPU but is ~7x slower at this window and needs NPUW_LLM_PREFILL_CHUNK_SIZE=MAX_PROMPT_LEN
# plus NPUW_MOE_TOKEN_CHUNK_SIZE=1024 (see ~/npu-test).
# plugin_config must be flat: the DEVICE_PROPERTIES form from the OVMS docs is silently
# ignored for NPU (window stayed at the 1024 default).
# Prefix caching reuses the KV of a shared prompt prefix (follow-up turns: 8.6s -> 2.9s at
# ~5K tokens). The compile cache does not distinguish some NPUW options and can serve a stale
# blob ("Cannot find tensor for port"), so the cache dir is versioned: bump it when changing them.
# The graph is mounted over the model dir because OVMS only generates graph.pbtxt
# when it downloads the model itself.
let
  image = "docker.io/openvino/model_server:latest-gpu"; # GPU image also ships the NPU driver
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
  virtualisation.oci-containers = {
    backend = "docker";
    containers.openvino = {
      inherit image;
      pull = "always";
      autoStart = false;
      ports = [ "127.0.0.1:8000:8000" ];
      volumes = [
        "/home/cvandesande/models/Qwen3-8B-int4-cw-ov:/model:ro"
        "${graph}:/graph/graph.pbtxt:ro"
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
        "--group-add=${toString config.users.groups.render.gid}" # image has no render group by name
        "--ulimit=memlock=-1:-1"
      ];
    };
  };

  # World-writable: the container runs as an unprivileged uid.
  systemd.tmpfiles.rules = [ "d /var/cache/openvino-npu-v2 0777 root root -" ];

  systemd.services.docker.restartIfChanged = false; # a restart kills the container

  environment.shellAliases = {
    llm-start = "systemctl start docker-openvino";
    llm-stop = "systemctl stop docker-openvino";
    llm-status = "systemctl is-active docker-openvino";
    llm-update = "docker pull docker.io/openvino/model_server:latest-gpu";
  };
}
