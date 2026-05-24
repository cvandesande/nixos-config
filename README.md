# NixOS installs

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
Each host has a small `disk-config.nix` that supplies only its target disk.
During install, set `HOST` to the target being installed. After booting the
installed system, `HOST=$(hostname)` should match one of these flake outputs.

Host roles:

| Host | Role | Storage | Desktop |
| --- | --- | --- | --- |
| `liltig` | Workstation/virtualisation host | LUKS + Btrfs + swap | KDE Plasma |
| `nuc` | Workstation | LUKS + Btrfs + swap | KDE Plasma |
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

Use the development VM target for an x86_64 host:

```bash
.#nix-vm-x86_64
```

Use the development VM target for an ARM64 host:

```bash
.#nix-vm-aarch64
```

## 1. Boot the minimal NixOS ISO

Boot the NixOS minimal installer in UEFI mode, then become root:

```bash
sudo -i
```

Confirm networking works:

```bash
ping -c 3 cache.nixos.org
```

Install temporary tools in the live environment:

```bash
nix-shell -p git vim
```

## 2. Clone the config

```bash
cd /tmp
git clone https://github.com/cvandesande/nixos-config.git
cd nixos-config

# Pick the host being installed.
HOST=liltig
```

## 3. Verify the target disk

Confirm the selected host and inspect its disk config before running Disko:

```bash
echo "$HOST"
cat "hosts/$HOST/disk-config.nix"
```

## 4. Partition, format, and mount

For `liltig` and `nuc`, this partitions the disk, creates LUKS, formats Btrfs,
creates swap, and mounts the new system. For `nix-vm-*`, this creates only an EFI
system partition and a plain ext4 root filesystem.

```bash
nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
  --mode disko \
  --flake ".#$HOST"
```

After this, the new system should be mounted under `/mnt`.

## 5. Copy the repo into the installed system

```bash
mkdir -p /mnt/etc/nixos
cp -a . /mnt/etc/nixos/
cd /mnt/etc/nixos
```

## 6. Generate hardware configuration

Disko owns the filesystem layout, so generate hardware config without
filesystem entries:

```bash
nixos-generate-config --no-filesystems --root /mnt
cp hardware-configuration.nix "hosts/$HOST/hardware-configuration.nix"
rm configuration.nix hardware-configuration.nix
```

Inspect the generated host hardware config:

```bash
cat "hosts/$HOST/hardware-configuration.nix"
```

## 7. Install NixOS

```bash
nixos-install --flake ".#$HOST"
```

Set the normal user password before rebooting:

```bash
nixos-enter --root /mnt -c 'passwd cvandesande'
```

Then reboot:

```bash
reboot
```

## 8. After first boot

For day-to-day work, manage this flake from the user's home directory. Copy the
installed repo there after the first boot:

```bash
cp -a /etc/nixos ~/nixos-config
sudo chown -R "$USER:$(id -gn)" ~/nixos-config
cd ~/nixos-config
```

If `/etc/nixos` is missing or you prefer a fresh checkout, clone the repo
instead:

```bash
git clone https://github.com/cvandesande/nixos-config.git ~/nixos-config
cd ~/nixos-config
```

If a generated hardware configuration was created during install, commit it from
the home-directory clone:

```bash
git status
HOST=$(hostname)
git add "hosts/$HOST/hardware-configuration.nix" flake.lock
git commit -m "Add $HOST hardware configuration"
git push
```

## 9. Workstation only: enable Secure Boot, then enroll TPM2 unlock

Skip this section for `nix-vm-*`; it does not use Lanzaboote, Secure Boot
signing, LUKS, TPM2 unlock, or FIDO2 unlock.

The base install keeps the normal LUKS passphrase. Keep that passphrase even
after TPM2 unlock works; it is the fallback when firmware, Secure Boot policy,
or TPM state changes.

TPM2 enrollment uses PCR 7 in this config. PCR 7 measures Secure Boot policy, so
enable and verify Secure Boot before enrolling the TPM2 LUKS token. If Secure
Boot is enabled, disabled, reset, or re-keyed later, expect to re-enroll the
TPM2 token using the passphrase.

### Build the Secure Boot generation

Set `HOST` to the flake host being configured:

```bash
cd ~/nixos-config
HOST=$(hostname)
```

The host config uses Lanzaboote and stores Secure Boot signing keys in
`/var/lib/sbctl`. Create the keys before the first successful Lanzaboote switch:

```bash
nix build nixpkgs#sbctl
sudo ./result/bin/sbctl create-keys
rm result
```

Build and switch to the signed generation:

```bash
sudo nixos-rebuild switch --flake ".#$HOST"
sudo sbctl verify
```

`sbctl verify` should show the bootloader and
`/boot/EFI/Linux/nixos-generation-*.efi` files as signed. An unsigned
`/boot/EFI/nixos/kernel-*.efi` file is not the boot path Lanzaboote uses.

### Enroll Secure Boot keys in firmware

Reboot into firmware setup with `F2`. Put Secure Boot into setup/custom mode if
keys are not enrolled yet, then boot back into NixOS and run:

```bash
sudo sbctl enroll-keys --microsoft
```

Reboot again, enable Secure Boot in firmware if needed, and verify from NixOS:

```bash
sudo sbctl status
bootctl status
```

Expected state:

```text
Setup Mode:  Disabled
Secure Boot: Enabled
```

If Secure Boot is disabled but setup mode is also disabled, the keys are usually
still enrolled; enable Secure Boot in firmware and verify again. Only re-run
`sbctl enroll-keys --microsoft` if setup mode is enabled or the firmware keys
were cleared.

### Find the LUKS partition

Disko should create the encrypted partition at:

```text
/dev/disk/by-partlabel/disk-main-luks
```

Confirm before enrolling anything:

```bash
LUKS=/dev/disk/by-partlabel/disk-main-luks
readlink -f "$LUKS"
sudo cryptsetup luksDump "$LUKS" | less
```

If that path does not exist, list the partition labels and pick the LUKS
container partition, not `/dev/mapper/crypted`:

```bash
lsblk -o NAME,TYPE,SIZE,FSTYPE,PARTLABEL,MOUNTPOINTS
```

For example, on the NUC test install the LUKS partition is usually:

```bash
LUKS=/dev/sda2
```

### Verify TPM2

The TPM must be visible and usable before LUKS enrollment:

```bash
ls -l /dev/tpm*
sudo tpm2_getcap properties-fixed
```

Expect `/dev/tpmrm0` and successful `tpm2_getcap` output.

### Enroll TPM2 unlock

With Secure Boot enabled and verified, enroll TPM2 unlock bound to PCR 7:

```bash
sudo systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-pcrs=7 \
  "$LUKS"
```

Check that LUKS now has a `systemd-tpm2` token:

```bash
sudo cryptsetup luksDump "$LUKS" | less
```

The initrd must include the TPM2 crypttab option:

```nix
boot.initrd.luks.devices.crypted.crypttabExtraOpts = [
  "tpm2-device=auto"
  "fido2-device=auto"
];
```

Rebuild and reboot:

```bash
sudo nixos-rebuild switch --flake ".#$HOST"
sudo reboot
```

Normal boot should unlock through TPM2. If it falls back to the passphrase, boot
with the passphrase and inspect:

```bash
sudo journalctl -b | grep -iE 'tpm|crypt|luks'
```

### Optional FIDO2 unlock

Insert the YubiKey. Set a FIDO2 PIN if one is not already configured:

```bash
ykman fido info
ykman fido access change-pin
```

Then enroll it for LUKS unlock:

```bash
sudo systemd-cryptenroll \
  --fido2-device=auto \
  --fido2-with-client-pin=yes \
  --fido2-with-user-presence=yes \
  "$LUKS"
```

Do not remove the passphrase slot until every intended unlock path has been
tested.

## 10. Workstation only: YubiKey SSH agent

Skip this section for `nix-vm-*`.

The system is configured to use `gpg-agent` as the SSH agent and includes the
YubiKey/FIDO2 tools. After adding or importing an SSH-capable GPG key onto the
YubiKey, verify it with:

```bash
gpg --card-status
gpg-connect-agent updatestartuptty /bye
ssh-add -L
```

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

Then rebuild with the normal flow:

```bash
nix flake check --no-build
nixos-rebuild build --flake ".#$HOST"
sudo nixos-rebuild test --flake ".#$HOST"
sudo nixos-rebuild switch --flake ".#$HOST"
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
