{ lib, pkgs, ... }:

let
  notifyRebootRequired = pkgs.writeShellScript "notify-reboot-required" ''
    set -eu

    booted_system="$(readlink /run/booted-system)"
    current_system="$(readlink /run/current-system)"
    reboot_required=0

    if [ "$booted_system" != "$current_system" ]; then
      reboot_required=1
    fi

    state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nixos-updates"
    diff_file="$state_dir/latest.diff"
    last_notified_file="$state_dir/last-notified-system"
    ${pkgs.coreutils}/bin/mkdir -p "$state_dir"

    last_notified=""
    if [ -f "$last_notified_file" ]; then
      last_notified="$(${pkgs.coreutils}/bin/cat "$last_notified_file")"
    fi

    if [ "$last_notified" = "$current_system" ]; then
      exit 0
    fi

    diff_base="$booted_system"
    if [ -n "$last_notified" ] && [ -e "$last_notified" ]; then
      diff_base="$last_notified"
    fi

    if diff="$(${pkgs.nix}/bin/nix store diff-closures "$diff_base" "$current_system" 2>&1)"; then
      :
    else
      diff="Could not calculate NixOS update diff:
$diff"
    fi

    ${pkgs.coreutils}/bin/printf '%s\n' "$diff" > "$diff_file"

    total_lines="$(${pkgs.coreutils}/bin/printf '%s\n' "$diff" | ${pkgs.gnugrep}/bin/grep -c . || true)"
    change_count="$total_lines"
    max_lines=18
    if [ -n "$diff" ]; then
      summary="$(${pkgs.coreutils}/bin/printf '%s\n' "$diff" | ${pkgs.coreutils}/bin/head -n "$max_lines")"
    else
      summary="No package-level closure changes detected."
    fi

    if [ "$total_lines" -gt "$max_lines" ]; then
      remaining_lines=$((total_lines - max_lines))
      summary="$summary
... $remaining_lines more lines in $diff_file"
    fi

    title="NixOS updates installed"
    if [ "$change_count" -gt 0 ]; then
      title="NixOS updates installed ($change_count package changes)"
    fi

    reboot_message=""
    if [ "$reboot_required" -eq 1 ]; then
      reboot_message="A reboot is recommended because the booted system differs from the active system.

"
    fi

    if ! ${pkgs.libnotify}/bin/notify-send \
      --app-name "NixOS updates" \
      --icon system-software-update \
      --urgency normal \
      "$title" \
      "NixOS updates were installed.

$reboot_message\
$summary"; then
      echo "NixOS updates were installed, but notify-send could not reach the desktop session."
      if [ "$reboot_required" -eq 1 ]; then
        echo "A reboot is recommended because the booted system differs from the active system."
      fi
      echo "Package changes:"
      ${pkgs.coreutils}/bin/printf '%s\n' "$diff"
    else
      ${pkgs.coreutils}/bin/printf '%s\n' "$current_system" > "$last_notified_file"
    fi
  '';
in

{
  environment.etc."xdg/kdeglobals".text = ''
    [Icons]
    Theme=Papirus-Dark
  '';

  environment.etc."sddm/kcminputrc".text = ''
    [Keyboard]
    NumLock=0
  '';

  services = {
    fwupd.enable = true;

    displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
        settings.General.Numlock = "on";
      };

      autoLogin = {
        enable = false;
        user = "cvandesande";
      };
    };
    desktopManager.plasma6.enable = true;

    # YubiKey/FIDO2 support
    udev.packages = [
      pkgs.libfido2
      pkgs.yubikey-personalization
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/sddm/.config 0755 sddm sddm -"
    "C+ /var/lib/sddm/.config/kcminputrc 0644 sddm sddm - /etc/sddm/kcminputrc"
  ];

  systemd.services.fwupd-refresh.serviceConfig.User = lib.mkForce "root";

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          # Shows battery charge of connected devices on supported Bluetooth
          # adapters.
          Experimental = true;
          # Lets other devices connect faster at the cost of increased power
          # consumption.
          FastConnectable = true;
        };
      };
    };

    sane = {
      enable = true;
      extraBackends = [ pkgs.epsonscan2 ];
    };
  };

  systemd.user = {
    services.notify-reboot-required = {
      description = "Notify when NixOS updates are installed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = notifyRebootRequired;
      };
    };

    paths.notify-reboot-required = {
      description = "Watch for active NixOS generation changes";
      wantedBy = [ "default.target" ];
      pathConfig.PathChanged = "/run/current-system";
    };

    timers.notify-reboot-required = {
      description = "Check whether the active NixOS generation needs a reboot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "6h";
        Persistent = true;
      };
    };
  };

  system.userActivationScripts.notify-reboot-required = ''
    ${pkgs.systemd}/bin/systemctl --user start notify-reboot-required.service || true
  '';
}
