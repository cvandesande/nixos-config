{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Core CLI
    curl
    direnv
    git
    htop
    jq
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
    python3
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
