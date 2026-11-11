# Installation (one-time, per host)

Everything here is done once per machine: booting the installer, Disko,
`nixos-install`, Secure Boot and TPM2 enrolment, FIDO2 SSH keys, and the laptop
speaker preset. Day-to-day work stays in [README.md](README.md).

Section numbers are shared across the two files, so an `INSTALL section N` or
`README section N` reference always names the file it lives in. Host roles and
flake outputs: [README.md, Host targets](README.md#host-targets).

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
cat "hosts/$HOST/configuration.nix"
# the device from configuration.nix must appear here
ls -l /dev/disk/by-path/ | grep -E "nvme|ata"
# and this is the disk you mean, not just the bay
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN
```

`device` uses `/dev/disk/by-path/` (the PCI slot) rather than `/dev/disk/by-id/`,
whose name is the drive's serial: vendor OUI plus unit number, in a public
repository. The slot path says only which bay the drive is in. Disko is the only
consumer — a running system mounts `/dev/disk/by-partlabel/disk-main-*` — so a
drive moved to another bay needs the path updated only before the next Disko
run.

The trade-off is the failure mode: a by-id path follows a drive wherever it ends
up, a by-path path follows the bay, so Disko formats whatever is in that bay.
After a drive swap, or a second drive in an empty bay, the two checks above are
the difference between installing on the intended disk and wiping the other one.

## 4. Partition, format, and mount

For `liltig`, `nuc` and `nomad`, this partitions the disk, creates LUKS,
formats Btrfs, creates swap, and mounts the new system. For `nix-vm-*`, this
creates only an EFI system partition and a plain ext4 root filesystem.

```bash
nix --experimental-features "nix-command flakes" \
  run github:nix-community/disko -- \
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

## 6. Install NixOS

### `nix-vm-*` hosts

These do not use Lanzaboote, so the plain install handles the bootloader:

```bash
nixos-install --flake ".#$HOST"
```

### Workstation hosts (`liltig`, `nuc`, `nomad`)

The workstation profile enables Lanzaboote, and its bootloader installer is
invoked as:

```text
lzbt install --allow-unsigned false \
  --public-key /var/lib/sbctl/keys/db/db.pem \
  --private-key /var/lib/sbctl/keys/db/db.key ...
```

Those keys do not exist yet on a freshly partitioned disk, and
`systemd-boot` is disabled by `modules/profiles/secure-boot-luks.nix`, so there
is no fallback. A plain `nixos-install` fails at the bootloader step. Install
the system first, create the keys inside it, then install the bootloader:

```bash
# 1. Install the system, leaving the bootloader alone.
nixos-install --flake ".#$HOST" --no-bootloader

# 2. Create the Secure Boot signing keys inside the new system.
#    sbctl is already in the system closure, and its default key location
#    (/var/lib/sbctl) is what boot.lanzaboote.pkiBundle expects.
nixos-enter --root /mnt -c '/run/current-system/sw/bin/sbctl create-keys'

# 3. Install the signed bootloader.
NIXOS_INSTALL_BOOTLOADER=1 nixos-enter --root /mnt \
  -c '/run/current-system/bin/switch-to-configuration boot'
```

`NIXOS_INSTALL_BOOTLOADER=1` is required. Without it,
`switch-to-configuration boot` only updates an existing bootloader instead of
installing one, which leaves the ESP without boot entries. This is the same
environment and command `nixos-install` itself uses when it installs the
bootloader.

Absolute paths matter here. `nixos-enter -c` runs `bash -c`, not a login
shell, so `/etc/profile` is never sourced and `PATH` still points at the
installer environment rather than the target's `/run/current-system/sw/bin`.
A bare `sbctl` would fail with "command not found".

If `sbctl create-keys` fails under the chroot, retry it as
`/run/current-system/sw/bin/sbctl --disable-landlock create-keys`.

### Both

Set the normal user password before rebooting:

```bash
nixos-enter --root /mnt -c '/run/current-system/sw/bin/passwd cvandesande'
```

Then reboot:

```bash
reboot
```

## 7. After first boot

For day-to-day work, manage this flake from the user's home directory. Copy the
installed repo there after the first boot:

```bash
cp -a /etc/nixos ~/nixos-config
sudo chown -R "$USER:$(id -gn)" ~/nixos-config
cd ~/nixos-config
```

That copy inherits the installer's HTTPS remote from section 2, which has no
way to authenticate a push. Switch it to SSH:

```bash
git remote set-url origin git@github.com:cvandesande/nixos-config.git
git remote -v
```

If `/etc/nixos` is missing or you prefer a fresh checkout, clone over SSH
directly instead:

```bash
git clone git@github.com:cvandesande/nixos-config.git ~/nixos-config
cd ~/nixos-config
```

Section 2 clones over HTTPS on purpose: the installer has no SSH keys.
Only this home-directory checkout needs to push.

## 8. Workstation only: enable Secure Boot, then enroll TPM2 unlock

Skip this section for `nix-vm-*`; it does not use Lanzaboote, Secure Boot
signing, LUKS, TPM2 unlock, or FIDO2 unlock.

The base install keeps the normal LUKS passphrase. Keep that passphrase even
after TPM2 unlock works; it is the fallback when firmware, Secure Boot policy,
or TPM state changes.

TPM2 enrollment uses PCR 7 in this config. PCR 7 measures Secure Boot policy, so
enable and verify Secure Boot before enrolling the TPM2 LUKS token. If Secure
Boot is enabled, disabled, reset, or re-keyed later, expect to re-enroll the
TPM2 token using the passphrase.

### Verify the signed generation

Nothing to build here. The section 6 install already created the signing keys
and signed the first generation, so just check it:

```bash
sudo sbctl verify
```

Expect the bootloader and `/boot/EFI/Linux/nixos-generation-*.efi` to be signed.

An unsigned `/boot/EFI/nixos/kernel-*.efi` is **expected and correct**.
Lanzaboote does not boot that file. The signed stub carries the kernel and
initrd hashes in its `.linuxh` and `.initrdh` PE sections and verifies them at
boot, so the kernel is covered by the stub's signature and needs none of its
own. sbctl cannot see that second link, so it reports the raw kernel as
unsigned.

Then continue at "Enroll Secure Boot keys in firmware" below.

### Retrofitting Lanzaboote onto an existing install

Skip this if the host was installed with the section 6 flow. It applies only to
a host installed *without* Lanzaboote, which is how `nuc` was originally set up.

```bash
cd ~/nixos-config
HOST=$(hostname)
```

Create the signing keys before the first Lanzaboote switch. `sbctl` is in
`environment.systemPackages`, so no `nix build` is needed. The command is
idempotent: on a host that already has keys it reports "Secure boot keys have
already been created" and leaves them untouched.

```bash
sudo sbctl create-keys
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

(`crypted` there is the LUKS mapper name, set by `encryptedName` in
`modules/storage/luks-btrfs.nix` — not a typo for "encrypted".)

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

## 9. Workstation only: FIDO2 SSH keys

Skip this section for `nix-vm-*`.

SSH keys are hardware-backed `ed25519-sk` key handles (`id_ed25519_sk_yk1`,
`id_ed25519_sk_yk2`, `id_ed25519_sk_nk`). `~/.ssh/config` lists them as
`IdentityFile` entries, so OpenSSH talks to the plugged-in token directly and
asks for the PIN and a touch on each connection (through `ksshaskpass` when
there is no terminal). No agent is involved. On `liltig`, `~/.ssh` is a symlink
into Nextcloud (`~/Nextcloud/Config/ssh`).

On a new host there is no `~/.ssh`. Copy the handles and config from an
existing host. The handles are useless without the physical token. The config's
`ControlPath` needs the `sockets` directory to exist.

```bash
NEWHOST=nomad
ssh "$NEWHOST" 'mkdir -p -m 700 ~/.ssh/sockets'
scp ~/.ssh/id_ed25519_sk_{yk1,yk2,nk}{,.pub} ~/.ssh/config "$NEWHOST":.ssh/
ssh "$NEWHOST" 'chmod 600 ~/.ssh/id_ed25519_sk_{yk1,yk2,nk}'
```

Verify with a token plugged into the new host:

```bash
fido2-token -L
ssh -T git@github.com
```

`liltig` and `nomad` disable password and keyboard-interactive SSH logins, so
they only accept tokens listed in `~/.ssh/authorized_keys`. Authorize at least
two tokens before switching a host to key-only logins, so losing one does not
lock you out of SSH.

## 10. Laptop only: speaker tuning

`nomad` only. The Framework 13 Pro speakers ship with a Dolby Atmos tuning on
Windows. On Linux, [speaker-tuning-to-easyeffects](https://github.com/antoinecellerier/speaker-tuning-to-easyeffects)
converts that tuning into an EasyEffects 8.x preset. It gives the speaker
correction (FIR, EQ, compressor, limiter), not Atmos spatial processing. The
host config only installs `easyeffects`; the preset lives in
`~/.local/share/easyeffects` and is generated once per user.

Download Framework's Windows driver bundle for the Core Ultra Series 3 (an
`.exe` that 7-Zip can unpack, about 1.7 GB) from
<https://resources.frame.work/downloads/laptop-13-pro/intel-core-ultra-3/> and
check its SHA256 against the one on that page. Then, as your normal user (the
script refuses `sudo`):

```bash
git clone https://github.com/antoinecellerier/speaker-tuning-to-easyeffects
cd speaker-tuning-to-easyeffects
nix-shell -p p7zip \
  "python3.withPackages (p: [ p.numpy p.scipy p.rich p.rich-argparse ])"
python3 dolby_to_easyeffects.py --doctor
python3 dolby_to_easyeffects.py \
  ~/Downloads/Framework_Laptop_13_*_driver_bundle_*.exe --autoload
```

The glob stands for the dated bundle name that page offers. Put the path before
`--autoload`: the flag takes an optional preset name and
would swallow the path. The run writes `Dolby-Balanced`, `Dolby-Detailed` and
`Dolby-Warm` to `~/.local/share/easyeffects/output` and autoloads `Dolby-Balanced`
on the built-in speakers.

Launch EasyEffects once from the desktop first (it cannot start from SSH), and
turn on Preferences > Background Service > "Autostart on login", or the preset
only applies while it is open.

If the sound is quieter than expected, re-run with `--enable autogain`; if it is
harsh, disable filters (see the project's `docs/troubleshooting.md`).
`--uninstall` removes what the script installed. The effect can also apply to
HDMI, Bluetooth and headsets until you change the EasyEffects output setup.
