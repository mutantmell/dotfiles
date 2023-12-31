{
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        users.root = {
          acl = [ "readwrite #" ];
          hashedPassword = "$7$101$0/w3EJ/3LayGnKGF$4CQM1qT7z7vM+AzHPPHepl23c2p+yamNEQ3LoAT6/jrszpE+czfS/syYMJDQ2vpk0lu4nl+HKJwblZqs9wlEvA==";
        };
      }
    ];
  };

  services.home-assistant = {
    extraComponents = [ "mqtt" ];
    config.mqtt = {};
  };

  networking.firewall = {
    allowedTCPPorts = [ 1883 ];
  };
}
