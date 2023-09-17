{ config, ... }: {

  services.home-assistant = {
    enable = true;
    extraComponents = [
      # Components required to complete the onboarding
      "esphome"
      "met"
      "radio_browser"
      # Aded components
      "google_translate"
      "zha"
      # zwave-js support not yet merged: https://github.com/NixOS/nixpkgs/pull/230380
    ];
    config = {
      # Includes dependencies for a basic setup
      # https://www.home-assistant.io/integrations/default_config/
      default_config = {};
    };
    openFirewall = true;
  };

}
