{ lanIfaces }: # the same interface allowlist configuration.nix passes to strixDash
{ lib, ... }:

# Open WebUI (https://github.com/open-webui/open-webui) as the chat front end for halogen:
# UI at http://<liltig>:8788, models and completions from halogen on :8731.
#
# Rootless podman, same shape as the halogen container in configuration.nix -- `backend` is
# already "podman" and `podman.user` pins the unit to cvandesande, so this still emits a
# *system* unit (podman-openwebui) that `systemctl start` reaches over ssh, while the image
# and its layers live in the per-user store under ~/.local/share/containers. The weekly
# dangling-image timer next to halogen's prunes the superseded :main copies this leaves
# behind; it is not duplicated here because it already covers the whole user store.
#
# Two things differ from halogen and strixDash. This one has its own accounts, so the box can
# keep the LAN-only firewall rule and still not hand out an admin panel to whoever is
# connected: the login form is on by default and the first account to sign up becomes admin.
# Turn signup off in the admin panel once that account exists -- see the ConfigVar note on
# OPENAI_API_BASE_URL below for why changing it here later would not take.
#
# Reaching halogen needs no --network=host and no published-port hairpin: pasta routes the
# container to the host and podman writes host.containers.internal into its /etc/hosts, so
# :8731 is an ordinary outbound connection (checked from a rootless container on this box).
# localhost:8731 from inside would be the container's own loopback and would refuse.
let
  # 87xx, after halogen's 8731 and strixDash's 8787, rather than Open WebUI's usual 8080:
  # a dev box grabs 8080 for vite and http.server every day, and this unit starts at boot,
  # so a port someone else took would fail the unit at login instead of on request.
  port = 8788;

  # Open WebUI keeps the SQLite db, uploads, knowledge files and the auto-generated
  # .webui_secret_key in /app/backend/data. Bind-mounted rather than a named volume:
  # rootless podman maps container root to cvandesande, so the files land owned by the user
  # and sessions survive a recreate -- the secret key is regenerated on every start that
  # cannot see it, which logs every browser out. No `+C` here: unlike the image stores, this
  # is a live database, and copy-on-write is what keeps it readable after a power cut.
  # Every OpenAI-shaped client in Open WebUI needs this spelled out separately; see the
  # config.py note where it is used.
  halogenUrl = "http://host.containers.internal:8731/v1";

  dataDir = "/home/cvandesande/.local/share/openwebui";
in
{
  networking.firewall.interfaces = lib.genAttrs lanIfaces (_: {
    allowedTCPPorts = [ port ];
  });

  # Every level named: tmpfiles makes unmentioned intermediates root-owned and then refuses
  # the transition, leaving the container unable to open its data dir.
  systemd.tmpfiles.rules = [
    "d /home/cvandesande/.local/share 0700 cvandesande users -"
    "d ${dataDir} 0700 cvandesande users -"
  ];

  virtualisation.oci-containers.containers.openwebui = {
    # :main is upstream's rolling release tag (v0.13.0 as of writing). The image is ~4.6 GB
    # because :main bundles the local embedding model, Whisper and the document parsers;
    # :main-slim is ~200 MB and identical for plain chat against halogen, but answers 503
    # for uploads and voice unless each is pointed at an external service, and its only
    # vector store is PostgreSQL with pgvector -- so knowledge search here needs :main even
    # though the embeddings themselves now come from the NPU.
    image = "ghcr.io/open-webui/open-webui:main";
    pull = "always";
    autoStart = true; # halogen keeps this off because loading the model is heavy; this is just a web app
    podman.user = "cvandesande";
    ports = [ "${toString port}:8080" ]; # all addresses; the firewall above limits it to the LAN NICs
    volumes = [ "${dataDir}:/app/backend/data" ];
    environment = {
      # OpenAI-compatible is what halogen speaks. ConfigVar: read on the first start and
      # then owned by webui.db, so after that the admin panel is the source of truth and
      # editing this line does nothing until ENABLE_PERSISTENT_CONFIG=false.
      OPENAI_API_BASE_URL = halogenUrl;

      # halogen serves without auth; the field only has to be non-empty for Open WebUI to
      # treat the connection as active, so it carries a name rather than a secret.
      OPENAI_API_KEY = "halogen";

      # No Ollama on this box. Left on, every model-list refresh opens a connection to
      # host.docker.internal:11434 -- the image's default, which resolves to nothing usable
      # under pasta -- and logs a connection error nobody can act on, in between the requests
      # that do matter. Checked against a throwaway container of this exact image.
      ENABLE_OLLAMA_API = "false";

      # flux2-klein-4b, already loaded on the NPU for the image tool in pi's halogen
      # extension, answers /v1/images/generations in the OpenAI shape (created plus
      # data[].b64_json) and ignores the extra fields Open WebUI adds (n, quality,
      # response_format, user) -- checked against the running server, 1024x1024 in 9.7 s.
      # So the plain `openai` image engine works directly, with no proxy in between:
      # IMAGES_OPENAI_API_{BASE_URL,KEY} default to the OPENAI_* pair above, i.e. halogen.
      IMAGE_GENERATION_ENGINE = "openai";
      IMAGE_GENERATION_MODEL = "flux2-klein-4b";
      ENABLE_IMAGE_GENERATION = "true"; # the admin toggle, and it defaults to off
      # Open WebUI's own default, and flux2's fast path (~3 s against 9.7 s at 1024x1024).
      # flux2 only takes the fixed size list in halogen's docs, so an odd size is a 400.
      IMAGE_SIZE = "512x512";

      # Embeddings for knowledge search go to the NPU as well: qwen3-embedding-0.6b is named
      # in HALOGEN_NPU_MODELS in configuration.nix, and RAG_OPENAI_API_{BASE_URL,KEY} default
      # to the halogen connection above, so the engine choice is the whole change. halogen
      # runs one NPU pass at a time beside flux2 and the guard: a whole knowledge base sent at
      # once is queued rather than refused, about 47 ms per short text of up to 512 tokens.
      RAG_EMBEDDING_ENGINE = "openai";
      RAG_EMBEDDING_MODEL = "qwen3-embedding-0.6b";

      # Spell the halogen URL out for each subsystem that needs it, even though
      # OPENAI_API_BASE_URL above already names it. config.py reads the env into
      # OPENAI_API_BASE_URL at line 313 and then overwrites that name at line 357 with
      # api.openai.com -- the pair is the lookup for the api.openai.com entry of the
      # connection list, not the env -- so the "default: ${OPENAI_API_BASE_URL}" the reference
      # page promises for RAG_* and IMAGES_* resolves to the literal instead of this box.
      # Left implicit, chat and the model list work while these seed api.openai.com and answer
      # with an OpenAI auth error nobody can trace back: read back off the running instance,
      # rag.openai.api_base_url and image_generation.openai.api_base_url both landed on
      # api.openai.com with OPENAI_API_BASE_URL pointing here.
      RAG_OPENAI_API_BASE_URL = halogenUrl;
      RAG_OPENAI_API_KEY = "halogen";
      IMAGES_OPENAI_API_BASE_URL = halogenUrl;
      IMAGES_OPENAI_API_KEY = "halogen";

      # Keep the container honest about outbound traffic: no GitHub poll for a newer release
      # (this box updates by pulling the tag), and no Hugging Face version check on every start
      # for the bundled sentence-transformers model, which nothing uses now that embeddings
      # come from halogen.
      ENABLE_VERSION_UPDATE_CHECK = "false";
      RAG_EMBEDDING_MODEL_AUTO_UPDATE = "false";
    };
  };

  # Two halogen capabilities still cannot be pointed at from here. Reranking: its server side is
  # /v1/rerank, but RAG_RERANKING_MODEL only loads a local SentenceTransformer cross-encoder,
  # so reaching it needs an Open WebUI function rather than an environment variable. Voice:
  # AUDIO_STT_* and AUDIO_TTS_* do default to the halogen connection, but qwen3-asr and
  # qwen3-tts are not loaded, and a voice model holds 1.6 to 5 GiB of locked host memory apiece
  # against 0.8 GiB for the embedder.

  # The module starts every podman unit with TimeoutStartSec=0, which is right for halogen,
  # where nothing starts at boot. Here `pull = "always"` runs inside the start job, so an
  # unreachable registry at boot would hold multi-user.target open forever; a finite budget
  # lets the boot finish and the unit fail instead.
  systemd.services.podman-openwebui.unitConfig.TimeoutStartSec = "900";

  environment.shellAliases = {
    ui-logs = "journalctl -u podman-openwebui";
    # Pulls as part of the start job, so a restart is the update step.
    ui-update = "systemctl restart podman-openwebui";
  };
}
