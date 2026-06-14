{ inputs, pkgs, ... }:

let
  unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
  };

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
    # Development and CLI tools
    htop
    unstable.nodejs
    bubblewrap
    cosign
    fastfetch
    file
    yq
    jq
    curl
    tree
    nil
    nixd
    nix-index
    nixfmt
    statix
    deadnix
    dnsutils
    socat
    unstable.zed-editor
    unstable.sops
    unstable.gh
    unstable.talosctl
    unstable.kubectl
    unstable.kubectl-cnpg
    unstable.kubernetes-helm
    ha-mcp
    unzip
    direnv
    git
    ripgrep
    vim
    wget
    shfmt
    shellcheck
    delta
    bat
    fd

    # Rust
    cargo
    clippy
    rustc
    rustPlatform.rustLibSrc
    rustfmt

    # Python
    basedpyright
    (python313.withPackages (
      ps: with ps; [
        pyyaml
      ]
    ))
    ruff
    uv

    # C/C++
    clang
    cmake
    gdb
    gnumake
    pkg-config

    # Go
    delve
    go
    gopls
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
