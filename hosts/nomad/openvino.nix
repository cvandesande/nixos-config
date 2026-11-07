{ pkgs, ... }:

# OpenVINO Model Server, the nomad counterpart of liltig's halogen: OpenAI API on 127.0.0.1:8000/v3/chat/completions. Started by llm-start, not at boot.
# Qwen3-8B-int4-cw on the NPU; Qwen3-30B-A3B-nf4-ov also runs but is ~7x slower here and needs the NPUW prefill/token chunk sizes (see ~/npu-test).
let
  image = "docker.io/openvino/model_server:latest-gpu"; # GPU image also ships the NPU driver
  # Mounted over the model dir below: OVMS only generates graph.pbtxt itself when it downloads the model.
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
          # Flat form required (the DEVICE_PROPERTIES form in the OVMS docs is silently ignored for NPU); static shapes fix the window at compile time.
          # Prefix caching reuses the KV of a shared prompt prefix: 8.6s -> 2.9s on follow-up turns at ~5K tokens. First compile ~16 min.
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
  # Rootless podman: the oci-containers module reads the uid for RequiresMountsFor, and linger keeps the user session alive.
  users.users.cvandesande = {
    uid = 1000;
    linger = true;
  };

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
        # Versioned: the compile cache ignores some NPUW options and can serve a stale blob ("Cannot find tensor for port") -- bump it when they change.
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
        # No --group-add: renderD128 and accel0 are 0666, so rootless needs no gid. No --ulimit=memlock either (see LimitMEMLOCK below).
      ];
    };
  };

  # Inherited by the container, unlike --ulimit=memlock=-1:-1, which podman exec then fails to re-apply from an 8 MB-capped shell (crun EPERM).
  systemd.services.podman-openvino.serviceConfig.LimitMEMLOCK = "infinity";

  # World-writable: the container runs as an unprivileged uid.
  systemd.tmpfiles.rules = [ "d /var/cache/openvino-npu-v2 0777 root root -" ];

  # Nothing prunes rootless storage, so pull = "always" piles up each superseded :latest-gpu; dangling images only, named images and volumes survive.
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

  environment.shellAliases = {
    llm-start = "systemctl start podman-openvino";
    llm-stop = "systemctl stop podman-openvino";
    llm-status = "systemctl is-active podman-openvino";
    llm-update = "podman pull docker.io/openvino/model_server:latest-gpu";
  };
}
