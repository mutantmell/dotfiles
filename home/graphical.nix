{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.firefox = {
    enable = true;
  };

  wayland.windowManager.sway = {
    enable = true;
    config = {
      terminal = "foot";
      modifier = "Mod4";
      fonts = {
        names = ["JetBrains Mono"];
        size = 11.0;
      };
      input."type:touchpad" = {
        tap = "enabled";
        natural_scroll = "enabled";
      };
      keybindings = let
        mod = "Mod4";
      in {
        "${mod}+Return" = "exec foot";
        "${mod}+d" = "exec ${pkgs.wmenu}/bin/wmenu-run";
        "${mod}+Shift+q" = "kill";
        "${mod}+Shift+e" = "exec swaymsg exit";
        "${mod}+h" = "focus left";
        "${mod}+j" = "focus down";
        "${mod}+k" = "focus up";
        "${mod}+l" = "focus right";
        "${mod}+Shift+h" = "move left";
        "${mod}+Shift+j" = "move down";
        "${mod}+Shift+k" = "move up";
        "${mod}+Shift+l" = "move right";
        "${mod}+1" = "workspace number 1";
        "${mod}+2" = "workspace number 2";
        "${mod}+3" = "workspace number 3";
        "${mod}+4" = "workspace number 4";
        "${mod}+5" = "workspace number 5";
        "${mod}+6" = "workspace number 6";
        "${mod}+7" = "workspace number 7";
        "${mod}+8" = "workspace number 8";
        "${mod}+9" = "workspace number 9";
        "${mod}+0" = "workspace number 10";
        "${mod}+Shift+1" = "move container to workspace number 1";
        "${mod}+Shift+2" = "move container to workspace number 2";
        "${mod}+Shift+3" = "move container to workspace number 3";
        "${mod}+Shift+4" = "move container to workspace number 4";
        "${mod}+Shift+5" = "move container to workspace number 5";
        "${mod}+Shift+6" = "move container to workspace number 6";
        "${mod}+Shift+7" = "move container to workspace number 7";
        "${mod}+Shift+8" = "move container to workspace number 8";
        "${mod}+Shift+9" = "move container to workspace number 9";
        "${mod}+Shift+0" = "move container to workspace number 10";
        "${mod}+b" = "splith";
        "${mod}+v" = "splitv";
        "${mod}+f" = "fullscreen toggle";
        "${mod}+s" = "layout stacking";
        "${mod}+w" = "layout tabbed";
        "${mod}+e" = "layout toggle split";
        "${mod}+Shift+space" = "floating toggle";
        "${mod}+space" = "focus mode_toggle";
        "${mod}+r" = "mode resize";

        # Lock screen
        "${mod}+Escape" = "exec ${pkgs.swaylock}/bin/swaylock -f";

        # Media keys
        "XF86AudioRaiseVolume" = "exec ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+";
        "XF86AudioLowerVolume" = "exec ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
        "XF86AudioMute" = "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        "XF86AudioMicMute" = "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle";
        "XF86MonBrightnessUp" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 5%+";
        "XF86MonBrightnessDown" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 5%-";
      };
      bars = [
        {
          statusCommand = "${pkgs.i3status}/bin/i3status";
        }
      ];
    };
  };

  programs.foot = {
    enable = true;
    settings.main = {
      font = "JetBrains Mono:size=11";
    };
  };

  programs.swaylock.enable = true;

  services.swayidle = {
    enable = true;
    events = {
      before-sleep = "${pkgs.swaylock}/bin/swaylock -f";
    };
  };

  services.gammastep = {
    enable = true;
    provider = "manual";
    latitude = 40.0;
    longitude = -74.0;
  };

  programs.i3status = {
    enable = true;
    general = {
      colors = true;
      interval = 5;
    };
    modules = {
      "battery 0" = {
        position = 1;
        settings = {
          format = "%status %percentage %remaining";
          path = "/sys/class/power_supply/BAT0/uevent";
        };
      };
      "wireless _first_" = {
        position = 2;
        settings = {
          format_up = "W: %essid %quality";
          format_down = "W: down";
        };
      };
      "volume master" = {
        position = 3;
        settings = {
          format = "Vol: %volume";
          format_muted = "Vol: muted";
        };
      };
      "tztime local" = {
        position = 4;
        settings = {
          format = "%Y-%m-%d %H:%M";
        };
      };
    };
  };

  home.packages = with pkgs; [
    waypipe
    wl-clipboard
    zed-editor
  ];
}
