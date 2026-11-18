{ lanIfaces }: # the interface allowlist configuration.nix builds for halogen and Open WebUI
{ lib, ... }:
# Open WebUI (https://github.com/open-webui/open-webui) as halogen's chat front end: UI on :8788,
# rootless like the halogen container, limited to the LAN NICs by the rules below. State is
# bind-mounted in dataDir, not a named volume, so the live db and its auto-generated
# .webui_secret_key survive a recreate -- losing that key logs every browser out.
#
# Endpoints. halogen speaks OpenAI and is reached on pasta's host route (host.containers.internal)
# with no auth, so a key only has to be non-empty. Every subsystem gets its base URL spelled out
# because config.py overwrites OPENAI_API_BASE_URL with api.openai.com. Voice goes through
# stt-wav-proxy on both halves -- see stt-proxy.nix for the reason, and its --voices list for the
# nine names below, since Open WebUI accepts only a voice it was offered.
#
# Config rows beat env. Env is persisted into webui.db at first boot and only *missing* rows are
# filled after, so editing a value here changes nothing once a row exists. Check the row, not env:
#   sqlite3 ~/.local/share/openwebui/webui.db "select key,value from config where key like 'audio%'"
let
  port = 8788; # 87xx after halogen's 8731; a dev box hands out 8080 daily

  # Holds the live db and the auto-generated key; no +C, it is a live db.
  dataDir = "/home/cvandesande/.local/share/openwebui";

  halogenUrl = "http://host.containers.internal:8731/v1";

  # Both halves of voice go through stt-wav-proxy (stt-proxy.nix) on the host; the rest is direct.
  audioUrl = "http://host.containers.internal:8765/v1";
in
{
  networking.firewall.interfaces = lib.genAttrs lanIfaces (_: {
    allowedTCPPorts = [ port ];
  });

  # Both levels named: an unmentioned intermediate comes out root-owned, and the transition is
  # then refused.
  systemd.tmpfiles.rules = [
    "d /home/cvandesande/.local/share 0700 cvandesande users -"
    "d ${dataDir} 0700 cvandesande users -"
  ];

  virtualisation.oci-containers.containers.openwebui = {
    # main is the rolling tag; :main-slim is much smaller but ships no embedded vector store
    image = "ghcr.io/open-webui/open-webui:main";
    pull = "always";
    autoStart = true;
    podman.user = "cvandesande";
    ports = [ "${toString port}:8080" ];
    volumes = [ "${dataDir}:/app/backend/data" ];
    environment = {
      OPENAI_API_BASE_URL = halogenUrl;
      OPENAI_API_KEY = "halogen"; # no auth on halogen; non-empty is enough

      # left on, Ollama is probed on :11434 at every refresh and the failure is journaled
      ENABLE_OLLAMA_API = "false";

      ENABLE_IMAGE_GENERATION = "false"; # flux2-klein-4b is off the NPU

      RAG_EMBEDDING_ENGINE = "openai";
      RAG_EMBEDDING_MODEL = "qwen3-embedding-0.6b"; # the name halogen.nix loads on the NPU

      # config.py overwrites the name above, so each subsystem gets its own copy.
      RAG_OPENAI_API_BASE_URL = halogenUrl;
      RAG_OPENAI_API_KEY = "halogen";
      IMAGES_OPENAI_API_BASE_URL = halogenUrl;
      IMAGES_OPENAI_API_KEY = "halogen";

      # Kagi, on the same account as pi's kagi MCP. The key is set in the admin panel, so it
      # lands in webui.db and stays out of this public repo.
      ENABLE_WEB_SEARCH = "true";
      WEB_SEARCH_ENGINE = "kagi";

      # neither base URL is rewritten like OPENAI_API_BASE_URL, so each gets its own copy
      AUDIO_STT_ENGINE = "openai";
      AUDIO_STT_MODEL = "qwen3-asr-1.7b"; # a name halogen does not know reaches it too
      AUDIO_STT_OPENAI_API_BASE_URL = audioUrl; # proxy: writes the WAV, lists the voices
      AUDIO_STT_OPENAI_API_KEY = "halogen";

      AUDIO_TTS_ENGINE = "openai";
      AUDIO_TTS_MODEL = "qwen3-tts-1.7b-customvoice";
      AUDIO_TTS_VOICE = "ryan"; # one of the nine names the proxy offers
      AUDIO_TTS_OPENAI_API_BASE_URL = audioUrl; # same proxy: it answers the voices list
      AUDIO_TTS_OPENAI_API_KEY = "halogen";

      # no version poll (this box updates by pulling) and no HF check for a bundled model
      ENABLE_VERSION_UPDATE_CHECK = "false";
      RAG_EMBEDDING_MODEL_AUTO_UPDATE = "false";
    };
  };

  # The module gives podman units TimeoutStartSec=0, which with pull = "always" lets an
  # unreachable registry at boot hold multi-user.target open forever.
  systemd.services.podman-openwebui.unitConfig.TimeoutStartSec = "900";

  environment.shellAliases = {
    ui-logs = "journalctl -u podman-openwebui";
    ui-update = "systemctl restart podman-openwebui"; # the start job pulls
  };
}
