{ lanIfaces }: # the interface allowlist configuration.nix builds for halogen and strixDash
{ lib, ... }:

# Open WebUI (https://github.com/open-webui/open-webui) as the chat front end for halogen: UI on :8788.
# Rootless like the halogen container -- podman.user pins the unit to cvandesande, layers in the per-user store.
let
  # 87xx, after halogen's 8731 and strixDash's 8787: this unit starts at boot and a dev box hands out 8080 daily.
  port = 8788;

  # Bind-mounted, not a named volume: rootless maps container root to cvandesande, so the SQLite db and the
  # auto-generated .webui_secret_key survive a recreate -- losing that key logs every browser out. No +C: live db.
  dataDir = "/home/cvandesande/.local/share/openwebui";

  # Every OpenAI-shaped client needs this spelled out on its own; see RAG_OPENAI_API_BASE_URL below.
  halogenUrl = "http://host.containers.internal:8731/v1";
in
{
  networking.firewall.interfaces = lib.genAttrs lanIfaces (_: {
    allowedTCPPorts = [ port ];
  });

  # Both levels named: tmpfiles makes an unmentioned intermediate root-owned and then refuses the transition.
  systemd.tmpfiles.rules = [
    "d /home/cvandesande/.local/share 0700 cvandesande users -"
    "d ${dataDir} 0700 cvandesande users -"
  ];

  virtualisation.oci-containers.containers.openwebui = {
    # Upstream's rolling tag; :main-slim is a twentieth the size but its only vector store is pgvector.
    image = "ghcr.io/open-webui/open-webui:main";
    pull = "always";
    autoStart = true; # unlike halogen, this is a web app rather than a 63 GB model load
    podman.user = "cvandesande";
    ports = [ "${toString port}:8080" ]; # LAN-only via the firewall, as everywhere else on this box
    volumes = [ "${dataDir}:/app/backend/data" ];
    environment = {
      # halogen speaks OpenAI, reached through host.containers.internal -- pasta's host route, not the container loopback.
      OPENAI_API_BASE_URL = halogenUrl;

      # halogen needs no auth; the key only has to be non-empty for the connection to count as active.
      OPENAI_API_KEY = "halogen";

      # ConfigVars: webui.db owns these after the first start, so this file seeds them and the admin panel rules after.
      ENABLE_OLLAMA_API = "false"; # no Ollama here; left on it probes :11434 every refresh and journals the failure

      # flux2-klein-4b answers /v1/images/generations in OpenAI's shape and ignores the extra fields Open WebUI adds.
      IMAGE_GENERATION_ENGINE = "openai";
      IMAGE_GENERATION_MODEL = "flux2-klein-4b";
      ENABLE_IMAGE_GENERATION = "true"; # the admin toggle, and it defaults to off
      IMAGE_SIZE = "512x512"; # flux2's fast path, ~3 s against 9.7 s at 1024x1024; odd sizes are a 400

      # Embeddings go to the NPU too; qwen3-embedding-0.6b is named in HALOGEN_NPU_MODELS in configuration.nix.
      RAG_EMBEDDING_ENGINE = "openai";
      RAG_EMBEDDING_MODEL = "qwen3-embedding-0.6b";

      # Each subsystem needs the URL spelled out even though OPENAI_API_BASE_URL above has it: config.py overwrites
      # that name with api.openai.com at line 357, so the documented "defaults to OPENAI_API_BASE_URL" never lands here.
      RAG_OPENAI_API_BASE_URL = halogenUrl;
      RAG_OPENAI_API_KEY = "halogen";
      IMAGES_OPENAI_API_BASE_URL = halogenUrl;
      IMAGES_OPENAI_API_KEY = "halogen";

      # Kagi search through Open WebUI's own provider: same account as pi's kagi MCP, and it fires on its own and
      # cites. The key stays out of this public repo -- set it in the admin panel, where it lands in webui.db.
      ENABLE_WEB_SEARCH = "true";
      WEB_SEARCH_ENGINE = "kagi";

      # No GitHub version poll (this box updates by pulling) and no HF check for a bundled model nothing uses now.
      ENABLE_VERSION_UPDATE_CHECK = "false";
      RAG_EMBEDDING_MODEL_AUTO_UPDATE = "false";
    };
  };

  # Still unreachable from here: reranking (RAG_RERANKING_MODEL is local-only, so /v1/rerank needs a Function), and
  # voice, whose AUDIO_STT_* and AUDIO_TTS_* would default here but for qwen3-asr and qwen3-tts not being loaded.

  # The module gives podman units TimeoutStartSec=0; with pull = "always" that lets an unreachable registry at boot
  # hold multi-user.target open forever, so budget the start and let the unit fail instead.
  systemd.services.podman-openwebui.unitConfig.TimeoutStartSec = "900";

  environment.shellAliases = {
    ui-logs = "journalctl -u podman-openwebui";
    ui-update = "systemctl restart podman-openwebui"; # the start job pulls, so a restart is the update step
  };
}
