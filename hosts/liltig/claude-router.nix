{ pkgs, ... }:

# qwen* go to halogen on :8731, the rest to api.anthropic.com. Source: ./claude-router.
{
  environment.sessionVariables.ANTHROPIC_BASE_URL = "http://127.0.0.1:8090";

  systemd.services.claude-router = {
    description = "Claude Code model router (qwen* -> local halogen, else Anthropic)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = builtins.concatStringsSep " " [
        "${pkgs.python3}/bin/python3"
        "${./claude-router/router.py}"
        "--listen 127.0.0.1:8090"
        "--local http://127.0.0.1:8731"
        "--default https://api.anthropic.com"
        "--local-prefix qwen"
      ];
      Restart = "on-failure";
      RestartSec = 2;

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
