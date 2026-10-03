{ pkgs, ... }:

# Model router for Claude Code. Point ANTHROPIC_BASE_URL at it and requests
# whose model name starts with "qwen" go to the local llama-server container
# (see configuration.nix); everything else, including the subscription OAuth
# traffic, passes through unchanged to api.anthropic.com. This lets Claude
# orchestrate while a subagent with `model: qwen3.8-flash-next-coding` runs
# locally:
#   ANTHROPIC_BASE_URL=http://127.0.0.1:8090 claude   # now the default (below)
# Source and tests: ./claude-router (python3 test_router.py).
{
  # Send every Claude Code session through the router by default. Applies to new
  # login sessions. Unset it for a shell to talk to Anthropic directly:
  #   env -u ANTHROPIC_BASE_URL claude
  # CLAUDE_CODE_MAX_CONTEXT_TOKENS is deliberately not set globally: it would
  # apply to the Anthropic models too and delay auto-compaction past their real
  # context window. Export it per shell when running the local model as main.
  environment.sessionVariables.ANTHROPIC_BASE_URL = "http://127.0.0.1:8090";

  systemd.services.claude-router = {
    description = "Claude Code model router (qwen* -> local llama-server, else Anthropic)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = builtins.concatStringsSep " " [
        "${pkgs.python3}/bin/python3"
        "${./claude-router/router.py}"
        "--listen 127.0.0.1:8090"
        "--local http://127.0.0.1:8080"
        "--default https://api.anthropic.com"
        "--local-prefix qwen"
      ];
      Restart = "on-failure";
      RestartSec = 2;

      # Only needs outbound network and a loopback listener.
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
    };
  };
}
