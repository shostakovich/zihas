# govee2mqtt setup

ZiWoAS delegates all Govee lamp I/O to [`wez/govee2mqtt`](https://github.com/wez/govee2mqtt).

## Credentials
Copy `config/govee2mqtt.env.example` to `config/govee2mqtt.env` (gitignored) and fill in
your Govee email/password, API key, and the MQTT broker host/port.

## Development (native binary)
Build once, pinned to a known tag/commit:

    git clone https://github.com/wez/govee2mqtt vendor/govee2mqtt
    cd vendor/govee2mqtt
    git checkout <tag-or-commit>     # pin; record the value in the PR
    cargo build --release

Then `foreman start` (Procfile.dev) runs `bin/govee2mqtt`, which loads
`config/govee2mqtt.env` and launches `govee --hass-discovery-prefix gv2mqtt serve`.
Override the binary path with `GOVEE2MQTT_BIN` if you built it elsewhere.

Note: govee2mqtt also binds an HTTP port (`--http-port`, default 8056). With host
networking, make sure nothing else uses 8056 (pass `--http-port` in `bin/govee2mqtt`
to change it).

## Production (container)
`docker-compose.yml` runs `ghcr.io/wez/govee2mqtt:latest` with `network_mode: host`
and `env_file: config/govee2mqtt.env`. Bring it up with `docker compose up -d`.
