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

    # Rust
    cargo
    clippy
    rustc
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
}
