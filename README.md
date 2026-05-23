# NixOS config

Starter flake-based NixOS configuration for a Framework Desktop using:

- Disko for declarative disk partitioning
- LUKS full-disk encryption
- Btrfs subvolumes
- `compress=zstd:3`
- periodic `fstrim`
- monthly Btrfs scrub
- zram swap

## Repository layout

```text
.
├── flake.nix
└── hosts
    └── framework-desktop
        ├── configuration.nix
        ├── disk-config.nix
        └── hardware-configuration.nix
```

## Important warning

Disko is destructive. Before running it, edit:

```text
hosts/framework-desktop/disk-config.nix
```

and replace:

```nix
device = "/dev/disk/by-id/YOUR_NVME_DEVICE";
```

with the real Framework Desktop NVMe device path.

Find it from the NixOS installer with:

```bash
ls -l /dev/disk/by-id/ | grep nvme
```

Prefer `/dev/disk/by-id/...` over `/dev/nvme0n1`.

## Fresh install flow

Boot the NixOS installer, then:

```bash
sudo -i
nix-shell -p git vim

git clone https://github.com/cvandesande/nixos-config.git /tmp/config
cd /tmp/config

ls -l /dev/disk/by-id/ | grep nvme
vim hosts/framework-desktop/disk-config.nix
```

Partition, encrypt, format, create Btrfs subvolumes, and mount under `/mnt`:

```bash
nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
  --mode disko \
  --flake .#framework-desktop
```

Generate the initial hardware config:

```bash
nixos-generate-config --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix ./hosts/framework-desktop/hardware-configuration.nix
```

Inspect the generated file:

```bash
vim hosts/framework-desktop/hardware-configuration.nix
```

If it contains duplicate `fileSystems` entries for `/`, `/home`, `/nix`, `/var/log`, `/.snapshots`, or `/boot`, remove the duplicates and let Disko own those mounts.

Install:

```bash
nixos-install --flake .#framework-desktop
reboot
```

## After first boot

Commit the generated hardware configuration from the installed system:

```bash
git status
git add hosts/framework-desktop/hardware-configuration.nix
git commit -m "Add Framework Desktop hardware configuration"
git push
```

## Btrfs layout

The current Disko config creates:

```text
/            @
/home        @home
/nix         @nix
/var/log     @log
/.snapshots  @snapshots
```

Each Btrfs subvolume uses:

```text
compress=zstd:3
noatime
```

## TPM2 unlock later

The base install should use a normal LUKS passphrase first.

After the encrypted system boots successfully, TPM unlock can be enrolled separately. Example:

```bash
sudo systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-pcrs=7 \
  /dev/disk/by-partlabel/luks
```

Then configure the initrd LUKS device using the real LUKS partition UUID:

```nix
boot.initrd.luks.devices."crypted" = {
  device = "/dev/disk/by-uuid/YOUR-LUKS-PARTITION-UUID";
  allowDiscards = true;
  crypttabExtraOpts = [ "tpm2-device=auto" ];
};
```

Keep the passphrase as fallback. TPM unlock is primarily convenience unless paired with a signed or measured boot chain, such as Secure Boot with Lanzaboote.
