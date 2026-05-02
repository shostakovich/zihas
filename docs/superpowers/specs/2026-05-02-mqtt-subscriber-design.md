# MQTT Subscriber Design

**Date:** 2026-05-02
**Status:** Approved

## Overview

Replace HTTP polling for Shelly smart plugs with MQTT subscriptions. Introduce a standalone `bin/ziwoas_collector` process that handles all data ingestion — initially MQTT (Shellies) and Fritz!DECT polling — separate from the Rails web server.

## Goals

- Receive Shelly data push-based via MQTT instead of pull-based HTTP polling
- Unify all data ingestion through a single MQTT pipeline (Fritz!DECT bridged via MQTT too)
- Eliminate the Rails initializer that starts background threads, so `rails console`, `db:migrate`, etc. run cleanly
- Keep the Rails process pure: API + Dashboard only

## Architecture

### Processes

```
Docker Compose
├── web               → Puma (Rails API + Dashboard, no background threads)
└── ziwoas_collector  → bin/ziwoas_collector (MqttSubscriber + FritzMqttBridge + Scheduler)
```

### Data Flow

```
Shelly Plugs  ──MQTT──► shellies/<id>/status/switch:0  ──┐
                                                           ▼
Fritz!DECT ──HTTP──► FritzMqttBridge ──MQTT──► shellies/robbebike/status/switch:0 ──► MqttSubscriber ──► Sample.insert
```

`MqttSubscriber` does not distinguish between real Shelly messages and Fritz!DECT-bridged messages. Both arrive in the same format on the same topic pattern.

## Shelly MQTT Configuration

Each Shelly device must be configured (via Web UI → Settings → MQTT) with a unique topic prefix matching its plug ID:

| Device | MQTT Topic Prefix | Status Topic |
|---|---|---|
| Solar (bkw) | `shellies/bkw` | `shellies/bkw/status/switch:0` |
| Robbe | `shellies/robbe` | `shellies/robbe/status/switch:0` |
| Krabbe | `shellies/krabbe` | `shellies/krabbe/status/switch:0` |
| Kühlschrank (fridge) | `shellies/fridge` | `shellies/fridge/status/switch:0` |
| Spülmaschine (dishwasher) | `shellies/dishwasher` | `shellies/dishwasher/status/switch:0` |
| Leseecke (readingcorner) | `shellies/readingcorner` | `shellies/readingcorner/status/switch:0` |

MQTT broker: `192.168.1.103:1883`

## Components

### `bin/ziwoas_collector`

Standalone Ruby script. Loads `config/environment` (ActiveRecord + Models). Instantiates and starts:

- `MqttSubscriber` thread
- `FritzMqttBridge` thread
- `Ziwoas::Scheduler` thread (existing aggregator, unchanged)

Installs SIGTERM/SIGINT handlers for graceful shutdown (reuses `Ziwoas::SignalHandler`).

### `MqttSubscriber` (`lib/mqtt_subscriber.rb`)

- Subscribes to `shellies/+/status/switch:0`
- Extracts plug ID from topic: `shellies/bkw/status/switch:0` → `"bkw"`
- Parses JSON payload: reads `apower` → `apower_w`, `aenergy.total` → `aenergy_wh`
- Inserts `Sample` record
- Ignores unknown plug IDs with a warning log
- Reconnects on connection loss with exponential backoff

### `FritzMqttBridge` (`lib/fritz_mqtt_bridge.rb`)

- Polls Fritz!DECT via existing `FritzDectClient`
- Publishes normalized message to `shellies/robbebike/status/switch:0`:
  ```json
  {"apower": 42.0, "aenergy": {"total": 1234.5}}
  ```
- Adaptive polling interval:
  - 5 s when `apower > idle_threshold_w` (configurable, default 10 W)
  - 60 s when idle (configurable)
- Has its own MQTT publish connection

### Removed Components

| File | Reason |
|---|---|
| `lib/shelly_client.rb` | HTTP polling replaced by MQTT |
| `lib/poller.rb` | No longer needed |
| `lib/circuit_breaker.rb` | MQTT reconnect handles connectivity |
| `config/initializers/ziwoas.rb` | Worker process takes over |

`Ziwoas::App` is removed. `bin/ziwoas_collector` contains the bootstrap logic directly.

## Configuration

### `config/ziwoas.yml` changes

Add `mqtt` section, add `fritz_poll` section, remove `host` from Shelly plugs:

```yaml
mqtt:
  host: 192.168.1.103
  port: 1883
  topic_prefix: shellies

fritz_poll:
  active_interval_seconds: 5
  idle_interval_seconds: 60
  idle_threshold_w: 10

plugs:
  - id: bkw
    name: Solar
    role: producer
    # no host — MQTT only

  - id: robbebike
    name: Waschmaschine
    role: consumer
    driver: fritz_dect
    ain: "08761 0500475"
    # no host — Fritz!Box config remains in fritz_box section
```

The `poll` section (interval_seconds, timeout_seconds, circuit_breaker_*) is removed.

## Gemfile

Add: `gem "mqtt"`

## Local Development (`bin/dev`)

Create `Procfile.dev`:

```
web:    ./bin/rails server
worker: ./bin/ziwoas_collector
```

Update `bin/dev` to use foreman:

```sh
#!/usr/bin/env sh
exec foreman start --procfile Procfile.dev "$@"
```

Both processes run in the same terminal with prefixed output (`web | worker`).

## Docker Compose

Add `ziwoas_collector` service sharing the same image as `web`, overriding the command to `bin/ziwoas_collector`. Both services mount the same SQLite database volume.

## Cleanup

- Old docs referencing `zihas` (the pre-rename name) in `docs/superpowers/` are updated to `ziwoas` where encountered during this work.

## Out of Scope

- Fritz!DECT reconnect logic (existing FritzDectClient error handling is sufficient)
- MQTT authentication (broker is local, unauthenticated)
- Shelly `events/rpc` topic (partial updates only, not needed when full status messages are available)