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

  # NumLock on at the login screen (KDE: 0 = on, 1 = off, 2 = leave unchanged).
  environment.etc."plasmalogin/kcminputrc".text = ''
    [Keyboard]
    NumLock=0
  '';

  # SDDM and Plasma Login Manager both substack `login`, where pam_fprintd runs
  # first. The greeter never shows its prompt, so a typed password waits out
  # fprintd's 30 s timeout. sudo and the Plasma lock screen keep fingerprint.
  security.pam.services.login.fprintAuth = false;

  # i2c-dev + /dev/i2c-* so Plasma/KWin can set external monitor brightness over DDC/CI.
  users.users.cvandesande.extraGroups = [ "i2c" ];

  services = {
    fwupd.enable = true;

    displayManager = {
      plasma-login-manager.enable = true;

      autoLogin = {
        enable = false;
        user = "cvandesande";
      };
    };
    desktopManager.plasma6.enable = true;

    # udev rules for the YubiKey
    udev.packages = [
      pkgs.libfido2
      pkgs.yubikey-personalization
    ];
  };

  systemd = {
    tmpfiles.rules = [
      "d /var/lib/plasmalogin/.config 0755 plasmalogin plasmalogin -"
      "C+ /var/lib/plasmalogin/.config/kcminputrc 0644 plasmalogin plasmalogin - /etc/plasmalogin/kcminputrc"
    ];

    services.fwupd-refresh.serviceConfig.User = lib.mkForce "root";

    user = {
      # The greeter's kwin already runs with --inputmethod plasma-keyboard.
      # This unit only runs for the plasmalogin greeter user.
      services.plasma-login-kwin_wayland = {
        overrideStrategy = "asDropin";
        # Don't let NixOS inject its minimal PATH into the drop-in: kwin is
        # told to launch a bare `plasma-keyboard`, found via the system PATH.
        path = lib.mkForce [ ];
      };

      services.notify-reboot-required = {
        description = "Notify when NixOS updates are installed";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = notifyRebootRequired;
        };
      };

      # Store paths in pinned launcher entries go stale on every rebuild and
      # render as question marks; rewrite them to applications: URIs first.
      services.fix-plasma-pins = {
        description = "Rewrite nix-store launcher pins to applications: URIs";
        wantedBy = [ "plasma-core.target" ];
        before = [ "plasma-plasmashell.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          f="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
          [ -f "$f" ] || exit 0
          ${pkgs.gnused}/bin/sed -i -E \
            's#file:///nix/store/[a-z0-9]+-system-path/share/applications/([^,]+\.desktop)#applications:\1#g' "$f"
        '';
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
  };

  hardware = {
    i2c.enable = true;

    bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          # Battery status on supported adapters; faster connect at higher power cost.
          Experimental = true;
          FastConnectable = true;
        };
      };
    };

    sane = {
      enable = true;
      extraBackends = [ pkgs.epsonscan2 ];
    };
  };

  system.userActivationScripts.notify-reboot-required = ''
    # --no-block: notify-send can stall ~25s per call before the notification daemon is up.
    ${pkgs.systemd}/bin/systemctl --user --no-block start notify-reboot-required.service || true
  '';
}
