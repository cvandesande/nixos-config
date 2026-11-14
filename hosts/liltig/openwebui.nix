{ lanIfaces }: # the interface allowlist configuration.nix builds for halogen and Open WebUI
{ lib, ... }:
# Open WebUI (https://github.com/open-webui/open-webui) as halogen's chat front end: UI on :8788.
# Rootless like the halogen container -- podman.user pins the unit to cvandesande, so the layers
# land in the per-user store.
#
# Port. 87xx, after halogen's 8731: this unit starts at boot and a dev box hands out 8080 daily.
# The firewall rules below keep it on the LAN NIC, as everywhere else on this box.
#
# State. Bind-mounted, not a named volume: rootless maps container root to cvandesande, so the
# SQLite db and the auto-generated .webui_secret_key survive a recreate -- losing that key logs
# every browser out. No +C, it is a live db. tmpfiles names both levels because an unmentioned
# intermediate comes out root-owned and the transition is then refused. These are ConfigVars, so
# this file seeds them and the admin panel owns them after the first start.
#
# Endpoints. halogen speaks OpenAI and is reached through host.containers.internal, pasta's host
# route rather than the container loopback. It needs no auth, so a key only has to be non-empty
# for the connection to count as active. Every OpenAI-shaped client gets the URL spelled out on
# its own: config.py overwrites OPENAI_API_BASE_URL with api.openai.com at line 357, so the
# documented "defaults to OPENAI_API_BASE_URL" never lands here. Ollama stays off, since left on
# it probes :11434 every refresh and journals the failure.
#
# Models. flux2-klein-4b answers /v1/images/generations in OpenAI's shape and ignores the extra
# fields Open WebUI adds; the admin toggle defaults to off, so it is set here, and 512x512 is
# flux2's fast path, ~3 s against 9.7 s at 1024x1024, with odd sizes a 400. Knowledge search
# embeds on the NPU with qwen3-embedding-0.6b, the name HALOGEN_NPU_MODELS carries in halogen.nix.
#
# Search. Kagi through Open WebUI's own provider: same account as pi's kagi MCP, and it fires on
# its own and cites. The key stays out of this public repo -- set it in the admin panel, where it
# lands in webui.db.
#
# Telemetry. No GitHub version poll, since this box updates by pulling, and no HF check for a
# bundled model nothing uses now.
#
# Image and boot. Upstream's rolling tag; :main-slim is a twentieth the size but its only vector
# store is pgvector. autoStart unlike halogen, because this is a web app rather than a 63 GB model
# load. The module gives podman units TimeoutStartSec=0, which with pull = "always" lets an
# unreachable registry at boot hold multi-user.target open forever, so the start is budgeted at
# 900 s and the unit fails instead.
#
# Out of reach: reranking (RAG_RERANKING_MODEL is local-only, so /v1/rerank needs a Function), and
# voice, whose AUDIO_STT_* and AUDIO_TTS_* would default here but for qwen3-asr and qwen3-tts not
# being loaded.
let
  port = 8788;

  # Holds the live db and the auto-generated key; see State above.
  dataDir = "/home/cvandesande/.local/share/openwebui";

  halogenUrl = "http://host.containers.internal:8731/v1";
in
{
  networking.firewall.interfaces = lib.genAttrs lanIfaces (_: {
    allowedTCPPorts = [ port ];
  });

  systemd.tmpfiles.rules = [
    "d /home/cvandesande/.local/share 0700 cvandesande users -"
    "d ${dataDir} 0700 cvandesande users -"
  ];

  virtualisation.oci-containers.containers.openwebui = {
    image = "ghcr.io/open-webui/open-webui:main";
    pull = "always";
    autoStart = true;
    podman.user = "cvandesande";
    ports = [ "${toString port}:8080" ];
    volumes = [ "${dataDir}:/app/backend/data" ];
    environment = {
      OPENAI_API_BASE_URL = halogenUrl;
      OPENAI_API_KEY = "halogen"; # no auth on halogen; non-empty is enough

      ENABLE_OLLAMA_API = "false"; # no Ollama here

      IMAGE_GENERATION_ENGINE = "openai";
      IMAGE_GENERATION_MODEL = "flux2-klein-4b";
      ENABLE_IMAGE_GENERATION = "true";
      IMAGE_SIZE = "512x512"; # flux2's fast path

      RAG_EMBEDDING_ENGINE = "openai";
      RAG_EMBEDDING_MODEL = "qwen3-embedding-0.6b";

      # config.py overwrites the name above, so each subsystem gets its own copy.
      RAG_OPENAI_API_BASE_URL = halogenUrl;
      RAG_OPENAI_API_KEY = "halogen";
      IMAGES_OPENAI_API_BASE_URL = halogenUrl;
      IMAGES_OPENAI_API_KEY = "halogen";

      ENABLE_WEB_SEARCH = "true";
      WEB_SEARCH_ENGINE = "kagi";

      ENABLE_VERSION_UPDATE_CHECK = "false";
      RAG_EMBEDDING_MODEL_AUTO_UPDATE = "false";
    };
  };

  systemd.services.podman-openwebui.unitConfig.TimeoutStartSec = "900";

  environment.shellAliases = {
    ui-logs = "journalctl -u podman-openwebui";
    ui-update = "systemctl restart podman-openwebui"; # the start job pulls, so a restart is the update
  };
}
