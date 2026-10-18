# Copy to secrets.nix (git-ignored) and fill in. Never commit secrets.nix.
{
  # Wi-Fi used by the live ISO and the installed system (WPA-PSK)
  ssid = "YourWifiName";
  psk  = "YourWifiPassword";

  # Password hash for the user `sv` (console login and sudo; SSH is key-only).
  # Generate with: mkpasswd -m yescrypt
  hashedPassword = "$y$j9T$...";

  # Public keys allowed to SSH in: `root` on the live ISO, `sv` on the installed system
  sshKeys = [
    "ssh-ed25519 AAAA... you@host"
  ];
}
