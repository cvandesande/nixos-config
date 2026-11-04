{
  pkgs,
  pkgsUnstable,
  ...
}:

{
  environment.systemPackages = with pkgs; [
    # Unstable infrastructure tools
    pkgsUnstable.kubectl
    pkgsUnstable.kubectl-cnpg
    pkgsUnstable.kubernetes-helm
    pkgsUnstable.talosctl

    # Runtimes and editors
    nodejs_26
    pkgsUnstable.zed-editor

    # CLI utilities
    android-tools
    bubblewrap
    cosign
    crane
    curl
    dnsutils
    fastfetch
    gh
    gnumake
    fd
    file
    htop
    openssl
    jq
    scrcpy
    sops
    tio
    tree
    unzip
    wget
    yq

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

  ];

  programs = {
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
    # Identity for unattended flake.lock commits; per-user ~/.gitconfig still wins.
    git = {
      enable = true;
      config.user = {
        name = "CVan";
        email = "cvandesande@opendmz.com";
      };
    };
    tmux = {
      enable = true;
      extraConfig = "set -g mouse on";
    };
    vim.enable = true;
  };

  environment.sessionVariables.RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
}
