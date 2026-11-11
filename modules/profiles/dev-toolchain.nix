{
  config,
  lib,
  pkgs,
  pkgsUnstable,
  ...
}:

{
  # Both btop builds install bin/btop, so only one of them can ever be installed; liltig overrides this to btop-rocm, whose rocm-smi is the only way btop sees an AMD GPU.
  options.devToolchain.btop.package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.btop;
    defaultText = lib.literalExpression "pkgs.btop";
    description = "Which btop build to install.";
  };

  config = {
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
      config.devToolchain.btop.package
      htop
      openssl
      jq
      # marksman (markdown LSP) deliberately NOT installed: it keeps crashing, so pi-lens reports every markdown write as "incomplete, not clean".
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
  };
}
