{ config, pkgs, lib, ... }:

let
  # Credentials live in ./secrets.nix, which is git-ignored (see secrets.example.nix).
  # Flakes only see git-tracked files, so build with a `path:` flake reference.
  secrets =
    if builtins.pathExists ./secrets.nix then import ./secrets.nix
    else throw "secrets.nix not found: copy secrets.example.nix to secrets.nix, fill it in, and build with `nix build path:.#...`";

  inherit (secrets) ssid psk hashedPassword sshKeys;

  # Quote values for safe interpolation into the generated Nix file
  nixStr = lib.strings.escapeNixString;
  nixList = xs: "[ ${lib.concatMapStringsSep " " nixStr xs} ]";

  # Extra module that gets imported by the *installed* system's configuration.nix.
  # (Appending to the generated file doesn't work: it ends with "}", so anything
  # added after it is a syntax error.)
  # It holds no secrets: the Wi-Fi password goes to /etc/wpa_supplicant-secrets
  # (root-only) instead of the world-readable Nix store.
  targetModule = pkgs.writeText "extra.nix" ''
    { lib, ... }: {
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # Needed by most Wi-Fi chips to work after the first reboot
      hardware.enableRedistributableFirmware = true;

      # The generated config may enable NetworkManager, which conflicts with
      # networking.wireless.networks, so force it off on the installed system
      networking.networkmanager.enable = lib.mkForce false;
      networking.wireless.enable = true;
      networking.wireless.secretsFile = "/etc/wpa_supplicant-secrets";
      networking.wireless.networks.${nixStr ssid}.pskRaw = "ext:psk";

      # Key-only SSH, no direct root login
      services.openssh.enable = true;
      services.openssh.settings.PermitRootLogin = "no";
      services.openssh.settings.PasswordAuthentication = false;
      services.openssh.settings.KbdInteractiveAuthentication = false;

      users.users.sv = {
        isNormalUser = true;
        # Hashed password, used for console login and sudo
        initialHashedPassword = ${nixStr hashedPassword};
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = ${nixList sshKeys};
      };
    }
  '';
in
{
  assertions = [
    { assertion = lib.hasPrefix "$" hashedPassword;
      message = "secrets.nix: hashedPassword must be a crypt hash (run `mkpasswd -m yescrypt`), not a plain password."; }
    { assertion = sshKeys != [ ];
      message = "secrets.nix: sshKeys is empty; SSH is key-only, so you would be locked out."; }
  ];

  # ---- Live installer environment ----
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.networkmanager.enable = lib.mkForce false;
  networking.wireless.enable = true;
  networking.wireless.networks.${ssid}.psk = psk;

  # SSH for watching the install remotely: key only, never passwords
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "prohibit-password";
  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.settings.KbdInteractiveAuthentication = false;
  users.users.root.openssh.authorizedKeys.keys = sshKeys;

  systemd.services.unattended-installer = {
    description = "Automated Full-Disk UEFI NixOS Installer (Wi-Fi)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    # Extends the default service PATH (coreutils, findutils, grep, sed, systemd)
    path = with pkgs; [
      nixos-install-tools   # nixos-install + nixos-generate-config
      config.nix.package
      gawk
      util-linux
      e2fsprogs
      parted
      dosfstools
      gptfdisk
      curl
      git
    ];

    environment.HOME = "/root";
    serviceConfig = {
      Type = "oneshot";
      # Show output on the physical screen (console) and keep it in the journal for SSH
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };

    script = ''
      set -euo pipefail

      step() { echo; echo "=================== [$1/7] $2 ==================="; }

      step 1 "Waiting for Wi-Fi / internet"
      # Wait until we can actually reach the binary cache (network.target != online)
      until curl -fsS --max-time 5 -o /dev/null https://cache.nixos.org/nix-cache-info; do
        echo "Waiting for network..."
        sleep 5
      done

      step 2 "Detecting target disk"
      # Work out which disk the installer itself booted from, so we never wipe it
      LIVE_SRC="$(findmnt -no SOURCE /iso || true)"
      LIVE_DISK=""
      if [ -n "$LIVE_SRC" ]; then
        LIVE_DISK="$(lsblk -no PKNAME "$LIVE_SRC" | head -n1 || true)"
        [ -n "$LIVE_DISK" ] || LIVE_DISK="$(basename "$LIVE_SRC")"
      fi

      # First non-removable disk that isn't the installer stick
      TARGET_DISK=""
      for disk in $(lsblk -dno NAME,TYPE,RM | awk '$2=="disk" && $3=="0" {print $1}'); do
        case "$disk" in loop*|sr*|zram*|ram*) continue ;; esac
        [ "$disk" = "$LIVE_DISK" ] && continue
        TARGET_DISK="/dev/$disk"
        break
      done

      if [ -z "$TARGET_DISK" ]; then
        echo "ERROR: No target internal disk discovered!" >&2
        exit 1
      fi

      # Safety net: if this disk already has our install, do nothing
      if lsblk -no LABEL "$TARGET_DISK" | grep -qx nixos; then
        echo "$TARGET_DISK already contains a NixOS install; skipping."
        exit 0
      fi

      echo "Target selected: $TARGET_DISK. Wiping and using the full disk..."
      step 3 "Partitioning $TARGET_DISK"

      wipefs -af "$TARGET_DISK"
      sgdisk --zap-all "$TARGET_DISK"

      parted -s "$TARGET_DISK" -- mklabel gpt
      parted -s "$TARGET_DISK" -- mkpart ESP fat32 1MiB 513MiB
      parted -s "$TARGET_DISK" -- set 1 esp on
      parted -s "$TARGET_DISK" -- mkpart swap linux-swap 513MiB 16897MiB
      parted -s "$TARGET_DISK" -- mkpart root ext4 16897MiB 100%

      # Wait for the kernel/udev to create the partition nodes
      partprobe "$TARGET_DISK" || true
      udevadm settle

      if [[ "$TARGET_DISK" == *nvme* || "$TARGET_DISK" == *mmcblk* ]]; then
        PART_BOOT="''${TARGET_DISK}p1"
        PART_SWAP="''${TARGET_DISK}p2"
        PART_ROOT="''${TARGET_DISK}p3"
      else
        PART_BOOT="''${TARGET_DISK}1"
        PART_SWAP="''${TARGET_DISK}2"
        PART_ROOT="''${TARGET_DISK}3"
      fi

      step 4 "Formatting"
      mkfs.vfat -F 32 -n BOOT "$PART_BOOT"
      mkswap -f -L swap "$PART_SWAP"
      mkfs.ext4 -F -L nixos-installing "$PART_ROOT"
      udevadm settle

      step 5 "Mounting and generating config"
      mount "$PART_ROOT" /mnt
      mkdir -p /mnt/boot
      mount "$PART_BOOT" /mnt/boot
      swapon "$PART_SWAP"

      nixos-generate-config --root /mnt

      # Drop our settings in a separate module and import it from the generated config
      install -m 0644 ${targetModule} /mnt/etc/nixos/extra.nix
      # Wi-Fi password for the installed system, readable by root only
      ( umask 077; printf 'psk=%s\n' ${lib.escapeShellArg psk} > /mnt/etc/wpa_supplicant-secrets )
      sed -i 's|\./hardware-configuration\.nix|./hardware-configuration.nix ./extra.nix|' \
        /mnt/etc/nixos/configuration.nix
      grep -q 'extra.nix' /mnt/etc/nixos/configuration.nix

      step 6 "Installing NixOS (downloads packages - this is the long part)"
      nixos-install --no-root-passwd --no-channel-copy
      # Mark the install as complete so the safety check above skips future runs
      e2label "$PART_ROOT" nixos

      step 7 "DONE"
      echo "Installation complete. Powering off in 10 seconds - unplug the USB stick, then power on."
      sleep 10
      # poweroff (not reboot) so a machine that boots USB first can't loop into another wipe
      systemctl poweroff
    '';
  };
}
