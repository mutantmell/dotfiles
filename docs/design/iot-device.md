# Proposed Pi sensor gateway requirements

Status: deferred target requirements; no deployment is claimed.

Start with a Raspberry Pi 4 SD-boot NixOS profile before attempting full netboot. Confirm actual Bluetooth/PoE hardware and aarch64 package support on the unit. Use registry-owned network identity and only required broker, sensor, monitoring, DNS/NTP and administration paths.

Mosquitto is the proposed local broker. Give the scanner write access only to its sensor topics, an exporter read access only to required topics, and Home Assistant an explicitly reviewed discovery/state/control topic set. Keep password/TLS material in the established secrets workflow. Decide whether retained messages are intentionally RAM-only; if so, scanner republishing after reboot must restore usable state.

The scanner should passively receive SwitchBot Meter Plus advertisements, filter both known identities and supported model payloads, and publish retained JSON temperature/humidity/battery state to `switchbot/<MAC-without-colons>/state`. Use a configurable scan cadence, reconnect backoff and graceful shutdown. Validate payloads with fixtures and physical sensors. Do not combine DynamicUser with firewall rules that assume a stable UID; prove the minimum BlueZ/device privileges rather than copying an untested hardening list.

Metrics must integrate with the fleet's current local-agent/VictoriaMetrics model. Netboot and any Tang/Clevis bootstrap require a separate outage/recovery experiment before removing SD fallback. Zigbee2MQTT, a coordinator purchase, MQTT client certificates, and broader Home Assistant ACLs remain later choices. Historical upstream bug numbers and platform support assertions need fresh verification when work starts.
