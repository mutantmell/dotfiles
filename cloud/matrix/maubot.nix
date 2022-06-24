{ config, pkgs, ... }:
{
  config.docker-containers = {
    maubot = {
      image = "dock.mau.dev/maubot/maubot:f52f8988f4047e3c4242263c861d3de798ce27de-amd64";
      ports = ["127.0.0.1:29316:29316"];
    }
  };
}
