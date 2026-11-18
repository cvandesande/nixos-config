{ lib, pkgs, ... }:

# Audio proxy for Open WebUI's voice on :8765, in front of halogen (:8731), for the two things
# halogen cannot do: it ffmpeg-decodes the browser's webm/opus to the WAV Qwen3-ASR takes, and
# answers the GET /v1/audio/voices that fills Open WebUI's dropdown and has no halogen route,
# relaying /v1/audio/speech untouched. Source: ./stt-proxy/stt_proxy.py. It retires when halogen
# grows opus input (issue #223) and a voices route: both AUDIO_*_OPENAI_API_BASE_URL values then
# point back at :8731 and this unit comes out.
#
# A host service, not a third container -- claude-router's pattern, and deliberately not folded
# into it, since that one stays loopback-only for Claude Code. Bound 0.0.0.0 because containers
# reach the host through pasta on a non-loopback address; no firewall rule, as nothing off-box
# needs it and it exposes nothing halogen's already-LAN-wide :8731 does not.

let
  port = 8765;
in
{
  systemd.services.stt-wav-proxy = {
    description = "Halogen audio proxy (mic WAV for Qwen3-ASR; voice list and speech relay for TTS)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = builtins.concatStringsSep " " [
        "${pkgs.python3}/bin/python3"
        "${./stt-proxy/stt_proxy.py}"
        "--listen 0.0.0.0:${toString port}"
        "--upstream http://127.0.0.1:8731"
      ];
      Restart = "on-failure";
      RestartSec = 2;

      # ffmpeg off PATH, systemd's own PATH kept so the unit still finds the usual tools.
      Environment = "PATH=${lib.makeBinPath [ pkgs.ffmpeg ]}:/run/current-system/sw/bin";

      # claude-router's set, less MemoryDenyWriteExecute: ffmpeg maps writable-executable memory,
      # and that setting turns it into a decode error that looks like a broken microphone.
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true; # ffmpeg's scratch space, and the proxy unlinks its files
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
    };
  };

  environment.shellAliases = {
    stt-health = "curl -s localhost:${toString port}/healthz";
    # what fills Open WebUI's dropdown, and the cheapest proof the relay is up
    tts-voices = "curl -s localhost:${toString port}/v1/audio/voices";
    # a 440 Hz tone is not speech: a 200 with any text back means webm reached ffmpeg and WAV
    # reached halogen. ffmpeg is spelled out because only this unit carries it.
    stt-test = ''
      ${pkgs.ffmpeg}/bin/ffmpeg -hide_banner -loglevel error -f lavfi -i sine=frequency=440:duration=1 -c:a libopus -y /tmp/stt-probe.webm \
      && curl -s localhost:${toString port}/v1/audio/transcriptions -F model=qwen3-asr-1.7b -F file=@/tmp/stt-probe.webm'';
  };
}
