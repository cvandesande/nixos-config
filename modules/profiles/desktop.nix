{ pkgs, ... }:

let
  notifyRebootRequired = pkgs.writeShellScript "notify-reboot-required" ''
    set -eu

    if [ "$(readlink /run/booted-system)" = "$(readlink /run/current-system)" ]; then
      exit 0
    fi

    ${pkgs.libnotify}/bin/notify-send \
      --app-name "NixOS updates" \
      --icon system-software-update \
      --urgency normal \
      "Restart required" \
      "NixOS updates were installed, but a reboot is needed to finish applying them."
  '';
in

{
  environment.etc."xdg/kdeglobals".text = ''
    [Icons]
    Theme=Papirus-Dark
  '';

  services = {
    fwupd.enable = true;

    displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
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
      description = "Notify when the active NixOS generation needs a reboot";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = notifyRebootRequired;
      };
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
}
