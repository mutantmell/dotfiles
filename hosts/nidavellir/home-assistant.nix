{ config, ... }: {

  services.home-assistant = {
    enable = true;
    extraComponents = [
      # Components required to complete the onboarding
      "esphome"
      "met"
      "radio_browser"
      # Aded components
      "androidtv_remote"
      "brother"
      "cast"
      "google_translate"
      "ipp"
      "mqtt"
      "snmp"
      "spotify"
      "zha"
      "zwave_js"
    ];
    config = {
      # Includes dependencies for a basic setup
      # https://www.home-assistant.io/integrations/default_config/
      default_config = {};
    };
    openFirewall = true;
  };

  services.zwave-js = {
    enable = true;
    serialPort = "/dev/ttyUSB0";
    secretsConfigFile = config.sops.secrets."zwavejs.secrets".path;
  };

}
