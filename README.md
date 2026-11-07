# NixOS installs

One-time, per-machine setup (ISO, Disko, install, Secure Boot/TPM2, FIDO2 SSH
keys, speaker tuning) lives in [INSTALL.md](INSTALL.md) as sections 1-10. The two
files share one numbering scheme, so `INSTALL section 3` and `README section 11`
each name the file they live in.

The workstation installs use:

- Disko for declarative disk partitioning
- LUKS full-disk encryption
- Optional TPM2 and YubiKey FIDO2 LUKS unlock via `systemd-cryptenroll`
- Btrfs subvolumes
- systemd-boot, with Lanzaboote/Secure Boot where enabled
- KDE Plasma

The `nix-vm-*` targets are intentionally simpler: plain ext4, no LUKS, no Btrfs
subvolumes/compression, and no graphical desktop.

## Host targets

The shared Disko layouts live in:

```text
modules/storage/luks-btrfs.nix
modules/storage/ext4-simple.nix
```
Each host's `configuration.nix` imports one of these layouts and supplies only
its target disk.
During install, set `HOST` to the target being installed. After booting the
installed system, `HOST=$(hostname)` should match one of these flake outputs.

Host roles:

| Host | Role | Storage | Desktop |
| --- | --- | --- | --- |
| `liltig` | Workstation/virtualisation host | LUKS + Btrfs + swap | KDE Plasma |
| `nuc` | Workstation | LUKS + Btrfs + swap | KDE Plasma |
| `nomad` | Laptop workstation (Framework 13 Pro) | LUKS + Btrfs + swap | KDE Plasma |
| `nix-vm-x86_64` | Headless development VM | Plain ext4 | None |
| `nix-vm-aarch64` | Headless development VM | Plain ext4 | None |

Use the Framework Desktop target:

```bash
.#liltig
```

Use the NUC target:

```bash
.#nuc
```

Use the Framework Laptop 13 Pro target:

```bash
.#nomad
```

Use the development VM target for an x86_64 host:

```bash
.#nix-vm-x86_64
```

Use the development VM target for an ARM64 host:

```bash
.#nix-vm-aarch64
```

## 11. Pi agent config (`~/.pi/agent`)

The shareable part of Pi's user config is tracked in `pi/` and symlinked into
`~/.pi/agent`, so Pi can edit its own config and the change shows up in
`git diff` for you to commit later:

| Repo path | Linked to | Notes |
|---|---|---|
| `pi/settings.json` | `~/.pi/agent/settings.json` | Pi rewrites this file itself: `lastChangelogVersion` and `extensionChangelogVersions` move on their own, so expect churn in `git diff`. |
| `pi/models.json` | `~/.pi/agent/models.json` | halogen on `liltig:8731` (reachable from any LAN host) and OpenVINO on `127.0.0.1:8000` (nomad's own NPU). Both `apiKey` fields are dummies — see below. |
| `pi/extensions/halogen-npu.ts` | `~/.pi/agent/extensions/halogen-npu.ts` | flux2 image and decider classifier models on the NPU. Honours `HALOGEN_BASE` if a host must point elsewhere. |

`models.json` is tracked, so it must never carry a real key. Pi keeps real
credentials in the untracked `auth.json`, and the `apiKey` fields here are
dummies for the local servers (`none`, `local`). Pi rewrites the file through the
symlink, so a key typed into a provider dialog can end up in a public
repository — read `git diff` before committing.

One shared file also means two per-host mismatches: `openvino` points at
`127.0.0.1:8000` and only answers on nomad, so `liltig` and `nuc` list a model
that can never connect; and with `defaultProvider: "halogen"`, a host that cannot
reach liltig has a dead default model until another is chosen with `/model`.

Symlinks into this working tree rather than `PI_CODING_AGENT_DIR` aimed at
`/nix/store`: Pi writes into its agent directory (in-place `writeFileSync` on
`settings.json`, a lock file beside it, plus `install/` and `sessions/`), so a
read-only store path fails the first time `/settings` saves. Nothing here is a
NixOS module for the same reason — the repo is the sharing vehicle and a handful
of `ln -sfn` lines wires it up.

Secrets are never in the repo (it is public). They live in `~/.secrets/pi`
(directory 700, files 600); `mcp.json` is linked from there because that is where
Pi looks for it, and `kagi.key` is read in place by a header command:

| Secret | Why it cannot be tracked |
|---|---|
| `mcp.json` | The Home Assistant token is inside the server `url`, and MCP `url` values get no `${VAR}` or `!command` substitution (only `env` and `headers` values do). `/mcp` also saves enable/disable and tool-exposure changes back into this file. Template: `pi/mcp.json.example`. |
| `kagi.key` | Kagi MCP key, read through `"!echo Bearer $(cat $HOME/.secrets/pi/kagi.key)"`. |

Everything per-host and regenerable stays in `~/.pi/agent` untracked: `install/`
(Pi's self-updating release plus its own `rg`), `npm/node_modules` (`settings.json`
`packages` names `npm:pi-lens` and `npm:pi-rtk-optimizer`; Pi installs them),
`sessions/`, `auth.json`, `mcp-auth.json`, `models-store.json`.

On a new host, after installing Pi itself (its installer owns `~/.pi/agent/install`
and the `~/.local/bin/pi` symlink) and cloning this repo:

```bash
# 1. Secrets first. On a host that already had its own settings.json, models.json
#    or mcp.json, move those out of the agent directory now: `ln -sfn` replaces a
#    regular file silently and nothing here backs it up.
mkdir -p ~/.pi/agent/extensions ~/.secrets/pi && chmod 700 ~/.secrets/pi
cp ~/nixos-config/pi/mcp.json.example ~/.secrets/pi/mcp.json   # then fill in the token
printf '%s\n' "$KAGI_KEY" > ~/.secrets/pi/kagi.key
chmod 600 ~/.secrets/pi/mcp.json ~/.secrets/pi/kagi.key

# 2. Link the tracked config in, plus the real mcp.json where Pi looks for it.
ln -sfn ~/nixos-config/pi/settings.json             ~/.pi/agent/settings.json
ln -sfn ~/nixos-config/pi/models.json               ~/.pi/agent/models.json
ln -sfn ~/nixos-config/pi/extensions/halogen-npu.ts ~/.pi/agent/extensions/halogen-npu.ts
ln -sfn ~/.secrets/pi/mcp.json                      ~/.pi/agent/mcp.json

pi mcp list   # both servers should report connected
```

The links survive Pi's own writes, so this is a one-time setup per host. Re-run
the four `ln -sfn` lines only to point `~/.pi/agent` at a different checkout, or
after moving a linked file by hand.

## Daily rebuild flow

For normal config changes on an already-installed system, use this flow:

```bash
cd ~/nixos-config
HOST=$(hostname)
```

Think: **check, build, test, switch**.

```bash
# 1. Check that every flake output evaluates.
nix flake check --no-build

# 2. Dry-run the system build.
nix build ".#nixosConfigurations.$HOST.config.system.build.toplevel" --dry-run

# 3. Build the generation, but do not activate it.
nixos-rebuild build --flake ".#$HOST"

# 4. Activate it temporarily until the next reboot.
sudo nixos-rebuild test --flake ".#$HOST"

# 5. Make it the active and default boot generation.
sudo nixos-rebuild switch --flake ".#$HOST"
```

Most small edits use only:

```bash
nix flake check --no-build
nixos-rebuild build --flake ".#$HOST"
sudo nixos-rebuild switch --flake ".#$HOST"
```

Use `test` when changing services, hardware, boot, networking, or anything
where you want one reboot to roll back automatically if the result is bad.

## Daily update flow

Flakes update in two separate steps:

1. Update `flake.lock`.
2. Rebuild the system from the new lock file.

`flake.nix` chooses the branch, such as `nixos-unstable` or `nixos-25.11`.
`flake.lock` pins the exact commit that actually gets built.

Update all flake inputs:

```bash
cd ~/nixos-config
HOST=$(hostname)
nix flake update
```

Then rebuild with the normal flow, previewing the upgrade before activating it:

```bash
nix flake check --no-build

# Remove any old ./result so a failed build can't leave a stale one to diff.
rm -f result
nixos-rebuild build --flake ".#$HOST"

# Preview what will change (versions added, removed, upgraded).
nvd diff /run/current-system ./result

sudo nixos-rebuild test --flake ".#$HOST"
sudo nixos-rebuild switch --flake ".#$HOST"
```

After switching, audit what changed:

```bash
# Compare the system booted at startup with the currently active generation.
nix store diff-closures /run/booted-system /run/current-system

# Compare adjacent system profile generations.
sudo nix profile diff-closures --profile /nix/var/nix/profiles/system

# Show which modules contributed to environment.systemPackages.
nix eval --json ".#nixosConfigurations.$HOST.options.environment.systemPackages.definitionsWithLocations"
```

To update only `nixpkgs`:

```bash
nix flake lock --update-input nixpkgs
```

Stable branches, such as `nixos-25.11`, mostly receive security fixes, bug
fixes, and conservative package updates. `nixos-unstable` receives newer
kernels, desktop environments, packages, and module changes, with more risk of
temporary breakage.

Memory version:

```text
update lock -> check -> build -> test -> switch
```

Rollback if a switched generation is bad:

```bash
sudo nixos-rebuild switch --rollback
```

Clean up old generations and unreachable store paths after the current system
has been tested:

```bash
# Delete old system generations, then collect unreachable store paths as root.
sudo nix-collect-garbage -d
```
