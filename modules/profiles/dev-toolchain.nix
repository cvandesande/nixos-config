{ pkgs, pkgsUnstable, ... }:

let
  ha-mcp = pkgs.writeShellApplication {
    name = "ha-mcp";
    runtimeInputs = [
      pkgs.python313
      pkgs.uv
    ];
    text = ''
      if [[ -f /var/lib/ha-mcp/env ]]; then
        set -a
        # shellcheck disable=SC1091
        source /var/lib/ha-mcp/env
        set +a
      fi

      exec uvx --python ${pkgs.python313}/bin/python3.13 ha-mcp@latest "$@"
    '';
  };
in
{
  environment.systemPackages = with pkgs; [
    # Unstable infrastructure tools
    pkgsUnstable.gh
    pkgsUnstable.kubectl
    pkgsUnstable.kubectl-cnpg
    pkgsUnstable.kubernetes-helm
    pkgsUnstable.sops
    pkgsUnstable.talosctl

    # Unstable runtimes and editors
    pkgsUnstable.nodejs
    pkgsUnstable.zed-editor

    # C/C++
    clang
    cmake
    gdb
    gnumake
    pkg-config

    # CLI utilities
    bat
    bubblewrap
    cosign
    curl
    delta
    dnsutils
    fastfetch
    fd
    file
    htop
    jq
    ripgrep
    shellcheck
    shfmt
    socat
    tree
    unzip
    wget
    yq

    # Go
    delve
    go
    gopls

    # Local tools
    ha-mcp

    # Nix tools
    deadnix
    nil
    nix-index
    nixd
    nixfmt
    statix

    # Python
    basedpyright
    (python313.withPackages (
      ps: with ps; [
        pyyaml
      ]
    ))
    ruff
    uv

    # Rust
    cargo
    clippy
    rustPlatform.rustLibSrc
    rustc
    rustfmt
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/ha-mcp 0700 root root -"
  ];

  programs = {
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
    git.enable = true;
    vim.enable = true;
  };

  environment.sessionVariables.RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
}
