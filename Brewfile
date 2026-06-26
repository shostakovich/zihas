# Brewfile — System-Abhängigkeiten für die ZiWoAS-Entwicklung.
# Installieren mit:  brew bundle
#
# Ruby selbst wird über rbenv verwaltet (siehe .ruby-version), NICHT über Homebrew.

# Rust-Toolchain — nötig, um die govee2mqtt-Bridge aus dem Source zu bauen
# (vendor/govee2mqtt, siehe docs/govee2mqtt-setup.md). Liefert cargo + rustc.
brew "rust"

# MQTT-Broker. ZiWoAS spricht standardmäßig einen externen Broker an
# (config/ziwoas.yml -> mqtt.host); auskommentiert lassen, wenn extern.
# Zum lokalen Betrieb einkommentieren:
# brew "mosquitto"
