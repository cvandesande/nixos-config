{ pkgs, ... }:

# strixDash (https://github.com/craiu/strixDash): read-only dashboard for halogen on :8731.
# UI at http://<liltig>:8787. Upstream has no auth/TLS, so it listens on all addresses but
# the firewall only opens the port on the LAN NIC (not wifi, docker bridges, etc.).
# Upstream has no LICENSE file, hence fetched at a pinned rev rather than vendored here.
let
  # server.py hardcodes the NIC to graph and the unit halogen runs under; point both at this box.
  nic = "enp196s0f3u1u2"; # USB ethernet; `ip -br link` if the name ever changes
  unit = "docker-halogen.service";

  strixdash = pkgs.runCommand "strixdash" { } ''
    mkdir -p $out
    cp -r ${src}/server.py ${src}/web $out/
    chmod -R u+w $out
    # Engine allocations: read halogen's startup report from journald (docker log driver)
    # instead of `podman logs`, scoped to the current run and re-read after a restart.
    patch -p1 -d $out < ${./strixdash-journal.patch}
    substituteInPlace $out/server.py \
      --replace-fail "('eno1', 'ctidao')" "('${nic}',)" \
      --replace-fail "rates.get('eno1', {})" "rates.get('${nic}', {})" \
      --replace-fail "'qwen.service'" "'${unit}'"
  '';

  src = pkgs.fetchFromGitHub {
    owner = "craiu";
    repo = "strixDash";
    rev = "fcc92961d06e97847751a4e404bcaa19f79de148";
    hash = "sha256-LRDxZ4IDsEPScrAd4FzLTG4z/eJ0acuB3yFTvLxugas=";
  };
in
{
  networking.firewall.interfaces.${nic}.allowedTCPPorts = [ 8787 ];

  systemd.services.strixdash = {
    description = "strixDash halogen/Strix Halo dashboard";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = builtins.concatStringsSep " " [
        "${pkgs.python3}/bin/python3"
        "${strixdash}/server.py"
        "--bind 0.0.0.0"
        "--port 8787"
        "--model-url http://127.0.0.1:8731"
        "--data-dir /var/lib/strixdash"
        "--node-name liltig"
        "--disk-path /"
      ];
      Restart = "on-failure";
      RestartSec = 5;
      MemoryMax = "192M";
      CPUQuota = "10%";

      DynamicUser = true;
      SupplementaryGroups = [ "systemd-journal" ]; # read halogen's journald container log
      StateDirectory = "strixdash"; # SQLite history, 7 day retention
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      # AF_UNIX: `systemctl show` for the halogen unit state
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
    };
  };
}
