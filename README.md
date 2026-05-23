# NixOS installs

The install uses:

- Disko for declarative disk partitioning
- LUKS full-disk encryption
- Optional TPM2 and YubiKey FIDO2 LUKS unlock via `systemd-cryptenroll`
- Btrfs subvolumes
- systemd-boot
- KDE Plasma

## Host targets

The shared Disko layout lives in:

```text
modules/disko/luks-btrfs.nix
```
Each host has a small `disk-config.nix` that supplies only its target disk.

Use the Framework Desktop target for the real install:

```bash
.#liltig
```

Use the NUC target for test installs:

```bash
.#nuc
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
cd /tmp/nixos-config
git clone https://github.com/cvandesande/nixos-config.git
```

## 3. Verify the target disk

This config currently targets:

```text
/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4086d232
```

## 4. Partition, encrypt, format, and mount

```bash
nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
  --mode disko \
  --flake .#liltig
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
cp hardware-configuration.nix hosts/liltig/hardware-configuration.nix
rm configuration.nix hardware-configuration.nix
```

Inspect the generated host hardware config:

```bash
cat hosts/liltig/hardware-configuration.nix
```

## 7. Install NixOS

```bash
nixos-install --flake .#liltig
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

The installed config lives at:

```text
/etc/nixos
```

Commit the generated hardware configuration:

```bash
cd /etc/nixos
git status
git add hosts/liltig/hardware-configuration.nix flake.lock
git commit -m "Add liltig hardware configuration"
git push
```

## 9. Enroll TPM2 and YubiKey unlock for LUKS

The base install keeps the LUKS passphrase. Enroll hardware unlock methods only
after the system boots successfully with the passphrase.

This config already enables systemd stage 1 and the LUKS crypttab options for
TPM2 and FIDO2:

```nix
boot.initrd.luks.devices.crypted.crypttabExtraOpts = [
  "tpm2-device=auto"
  "fido2-device=auto"
];
```

> **Security note:** TPM2 auto-unlock is convenient, but by itself it mainly
> protects against a stolen bare drive, not a stolen whole computer. Keep the
> passphrase/recovery key, and prefer Secure Boot/measured boot before relying
> on TPM2 as a strong physical-security boundary.

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
ls -l /dev/disk/by-partlabel/
```

### Add a recovery key

Store this offline. It remains usable anywhere a LUKS passphrase is accepted.

```bash
sudo systemd-cryptenroll --recovery-key "$LUKS"
```

### Enroll TPM2

PCR 7 binds the TPM enrollment to the Secure Boot policy state. If Secure Boot
is later enabled/disabled or its keys change, expect to re-enroll the TPM slot
using the passphrase or recovery key.

```bash
sudo systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-pcrs=7 \
  "$LUKS"
```

### Enroll a YubiKey as a FIDO2 unlock method

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

Check the resulting LUKS slots/tokens:

```bash
sudo cryptsetup luksDump "$LUKS" | less
```

Rebuild so the booted generation definitely contains the current initrd
settings:

```bash
cd /etc/nixos
sudo nixos-rebuild switch --flake .#liltig
```

Reboot and verify:

1. Normal boot should unlock through TPM2 if the PCR policy still matches.
2. The original passphrase remains a fallback.
3. To test the YubiKey path independently, temporarily remove
   `"tpm2-device=auto"` from `crypttabExtraOpts`, rebuild, reboot with the
   YubiKey inserted, then restore the TPM2 option.

Do not remove the passphrase slot until both TPM2, YubiKey, and recovery-key
unlock paths have been tested.

## 10. YubiKey SSH agent

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
cd /etc/nixos
```

Think: **check, build, test, switch**.

```bash
# 1. Check that every flake output evaluates.
nix flake check --no-build

# 2. Dry-run the NUC system build.
nix build .#nixosConfigurations.nuc.config.system.build.toplevel --dry-run

# 3. Build the NUC generation, but do not activate it.
nixos-rebuild build --flake .#nuc

# 4. Activate it temporarily until the next reboot.
sudo nixos-rebuild test --flake .#nuc

# 5. Make it the active and default boot generation.
sudo nixos-rebuild switch --flake .#nuc
```

Most small edits use only:

```bash
nix flake check --no-build
nixos-rebuild build --flake .#nuc
sudo nixos-rebuild switch --flake .#nuc
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
cd /etc/nixos
nix flake update
```

Then rebuild with the normal flow:

```bash
nix flake check --no-build
nixos-rebuild build --flake .#nuc
sudo nixos-rebuild test --flake .#nuc
sudo nixos-rebuild switch --flake .#nuc
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
