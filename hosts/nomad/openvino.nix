{ pkgs, ... }:

# OpenVINO Model Server on nomad's NPU: Qwen3-8B-int4-cw, OpenAI API on
# 127.0.0.1:8000/v3/chat/completions, started by ovms-start. Qwen3-30B-A3B-nf4-ov runs here too but
# is ~7x slower and needs the NPUW prefill/token chunk sizes (see ~/npu-test).
#
# Graph. OVMS only generates graph.pbtxt itself when it downloads the model, so the one below is
# mounted over the model dir. The DEVICE_PROPERTIES form in the OVMS docs is silently ignored for
# NPU, and static shapes are what fix the window at compile time: MAX_PROMPT_LEN 32768 with
# MIN_RESPONSE_LEN 4096. NPUW_LLM_ENABLE_PREFIX_CACHING reuses a shared prompt prefix: 8.6 s ->
# 2.9 s on follow-up turns at ~5K tokens; the first compile takes ~16 min.
#
# Cache. The compile cache ignores some NPUW options and can serve a stale blob ("Cannot find
# tensor for port"), so the directory carries a version and gets bumped when those options change.
# It is world-writable because the container runs as an unprivileged uid.
#
# Naming. `ovms-*` keeps the NPU experiment's own names now that `llm-*` means Strata (strata.nix),
# and linger comes from there too: this file needs the uid only, which podman reads for
# RequiresMountsFor.
let
  image = "docker.io/openvino/model_server:latest-gpu"; # the GPU image also ships the NPU driver

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

  # Inherited by the container: --ulimit memlock would be re-applied by podman exec from an
  # 8 MB-capped shell, which fails with crun EPERM.
  systemd.services.podman-openvino.serviceConfig.LimitMEMLOCK = "infinity";

  systemd.tmpfiles.rules = [ "d /var/cache/openvino-npu-v2 0777 root root -" ];

  # Nothing prunes rootless storage, so pull = "always" piles up each superseded :latest-gpu; named
  # images and volumes survive.
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
    ovms-start = "systemctl start podman-openvino";
    ovms-stop = "systemctl stop podman-openvino";
    ovms-status = "systemctl is-active podman-openvino";
    ovms-update = "podman pull docker.io/openvino/model_server:latest-gpu";
  };
}
