# zero-touch-nixos

**A NixOS installer ISO that installs itself. No keyboard, no screen, no questions.**

Boot the stick and it joins your Wi‑Fi, wipes the internal disk, installs a preconfigured NixOS system, and powers off. Remove the stick, power on, and SSH in.

> [!WARNING]
> The installer **erases an entire disk without asking**. Only boot it on machines where losing all data is acceptable. On machines with several internal disks, unplug the ones you want to keep (see [Target disk selection](#target-disk-selection)).

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What gets installed](#what-gets-installed)
- [How it works](#how-it-works)
- [Customization](#customization)
- [Security](#security)
- [Troubleshooting](#troubleshooting)

## Requirements

| | |
|---|---|
| Target machine | `x86_64`, UEFI boot (no legacy BIOS) |
| Target disk | At least ~17 GiB (512 MiB ESP + 16 GiB swap + root); 32 GiB or more recommended |
| Network | WPA‑PSK Wi‑Fi in range, with internet access |
| USB stick | 1 GB or larger |
| Build machine | Nix (flakes are enabled on the command line below) |

## Quick start

### 1. Set your credentials

Credentials live in `secrets.nix`, which is git‑ignored. Start from the template:

```bash
cp secrets.example.nix secrets.nix
chmod 600 secrets.nix
mkpasswd -m yescrypt   # paste the output into hashedPassword
```

```nix
{
  ssid           = "YourWifiName";
  psk            = "YourWifiPassword";
  hashedPassword = "$y$j9T$...";
  sshKeys        = [ "ssh-ed25519 AAAA... you@host" ];
}
```

| Variable | Used for |
|---|---|
| `ssid`, `psk` | Wi‑Fi on both the live ISO and the installed system |
| `hashedPassword` | Password hash of the user `sv` on the installed system (console login and `sudo`; SSH is key‑only) |
| `sshKeys` | Authorized for `root` on the live ISO and for `sv` on the installed system |

The build fails with an assertion if `hashedPassword` isn't a crypt hash or `sshKeys` is empty.

> [!CAUTION]
> The Wi‑Fi password ends up in plain text in the ISO. Read [Security](#security) before you share anything.

### 2. Build the ISO

```bash
nix build --extra-experimental-features "nix-command flakes" \
  path:.#nixosConfigurations.unattended-iso.config.system.build.isoImage
```

The image lands in `result/iso/`. The `path:` prefix matters: a plain `.#` flake only sees git‑tracked files, so it wouldn't find the git‑ignored `secrets.nix`.

### 3. Write it to a USB stick

Find the stick with `lsblk` first. Writing to the wrong device destroys it.

```bash
sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

### 4. Boot and wait

1. Plug the stick into the target machine and boot from it (you may need to change the boot order once).
2. Progress shows on screen as `[1/7]` … `[7/7]`. Step 6 downloads packages and takes the longest.
3. The machine powers off when done. **Remove the stick**, then power on.
4. Log in:

   ```bash
   ssh sv@<machine-ip>
   ```

   SSH accepts your key only. The password from `hashedPassword` is for `sudo` and the console.

### Watching remotely

The live ISO runs SSH (key only), so you can follow the install from another machine:

```bash
ssh root@<machine-ip>
journalctl -u unattended-installer -f
```

## What gets installed

**Disk layout** (GPT):

| # | Size | Filesystem | Label |
|---|---|---|---|
| 1 | 512 MiB | FAT32 (EFI System Partition) | `BOOT` |
| 2 | 16 GiB | swap | `swap` |
| 3 | rest of disk | ext4 | `nixos` |

**System configuration** (on top of what `nixos-generate-config` produces):

- `systemd-boot` bootloader
- Wi‑Fi through `wpa_supplicant` with the same network as the installer; NetworkManager disabled. The Wi‑Fi password is kept in `/etc/wpa_supplicant-secrets` (mode `0600`), not in the world‑readable Nix store
- Redistributable firmware enabled (covers most Wi‑Fi chips)
- OpenSSH: key only, no password or keyboard‑interactive login, no `root` login
- User `sv` in `wheel`; `sudo` asks for the password
- `root` has no password and no SSH access (use `sudo`)

The generated `/etc/nixos/configuration.nix` imports an extra module, `/etc/nixos/extra.nix`, which holds the settings above (and no secrets). Edit either file and run `nixos-rebuild switch` to change the installed system.

## How it works

The ISO is the minimal NixOS installer plus a `systemd` oneshot service, `unattended-installer`, that runs at boot:

| Step | Action |
|---|---|
| 1 | Wait until `cache.nixos.org` is reachable |
| 2 | Pick the target disk (see below) |
| 3 | Wipe and partition it |
| 4 | Format the partitions |
| 5 | Mount them, run `nixos-generate-config`, add `extra.nix` and the Wi‑Fi secrets file |
| 6 | Run `nixos-install` |
| 7 | Power off |

### Target disk selection

The installer picks the **first non‑removable disk** that isn't the USB stick it booted from. Loop, optical, zram and RAM devices are skipped. On a machine with several internal disks, there's no guarantee which one comes first, so disconnect any disk you want to keep.

### Re-run protection

- The root partition is labeled `nixos-installing` during installation and renamed to `nixos` only after `nixos-install` succeeds.
- On boot, if the target disk already has a partition labeled `nixos`, the installer does nothing.
- So an interrupted install is retried on the next boot, while a finished one is left alone.
- The machine **powers off instead of rebooting**, so a machine that boots from USB first can't loop into another wipe.

> [!NOTE]
> The check only looks at the label. Any disk with a partition labeled `nixos` (including a manual install that followed the NixOS manual) is skipped.

## Customization

Credentials live in `secrets.nix`; everything else in `configuration.nix`:

| To change | Edit |
|---|---|
| Username | `users.users.sv` inside `targetModule` |
| Packages and services on the installed system | `targetModule` |
| Swap size | The `mkpart swap` and `mkpart root` lines in step 3 (both boundaries must move together) |
| nixpkgs channel | `inputs.nixpkgs.url` in `flake.nix` (default: `nixos-unstable`), pinned by `flake.lock`; update with `nix flake update` |

## Security

What the defaults protect:

- **No credentials in the repository.** `secrets.nix` is git‑ignored; only `secrets.example.nix` is tracked.
- **SSH is key‑only everywhere.** The live ISO allows `root` by key only; the installed system allows `sv` by key only and refuses `root`.
- **No plain‑text login password.** `sv` gets a password hash, and `sudo` requires that password.
- **The installed system's Wi‑Fi password stays out of the Nix store**, in a root‑only file.
- **nixpkgs is pinned** by `flake.lock`, so a build uses the exact revision you reviewed.

What you still have to handle:

- **Treat the ISO as a secret.** It contains the Wi‑Fi password in plain text and your password hash. Don't share it, and wipe the stick when you're done.
- **Credentials pushed before this change are public.** Earlier commits contain a Wi‑Fi password and a login password. Deleting or rewriting commits doesn't remove them from clones or caches: change the Wi‑Fi password on the router and never reuse the old login password.
- **Anyone with physical access to the running live ISO** gets a root shell on its console, as with any NixOS installer.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `secrets.nix not found` | Copy `secrets.example.nix` to `secrets.nix`, and build with `path:.#…` rather than `.#…`. |
| `Failed assertions: secrets.nix: …` | Fix the named value in `secrets.nix`, as the message says. |
| Stuck on `Waiting for network...` | Wrong SSID or password, network out of range, or the Wi‑Fi chip needs firmware the ISO doesn't include. |
| `already contains a NixOS install; skipping` | The target disk has a partition labeled `nixos`. This is intended. Wipe the disk manually to reinstall. |
| `ERROR: No target internal disk discovered!` | No non‑removable disk found other than the USB stick. Some NVMe‑over‑USB or SD setups are reported as removable. |
| The wrong disk was wiped | The installer takes the first non‑removable disk. Unplug the disks you want to keep. |
| `experimental Nix feature 'flakes' is disabled` | Pass `--extra-experimental-features "nix-command flakes"` when building, as in the command above. |
| `You can not use networking.networkmanager with networking.wireless` | The installed‑system module already forces NetworkManager off with `lib.mkForce false`. If you see this, check that your own changes don't re‑enable it. |
| Evaluation error during step 6 | Read the lines under `Failed assertions:` on screen, or run `journalctl -u unattended-installer` over SSH on the live system. |

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
