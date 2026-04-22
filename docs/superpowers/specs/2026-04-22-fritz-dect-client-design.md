# FritzDectClient — Design Spec

**Status:** Approved, ready for implementation plan
**Date:** 2026-04-22
**Scope:** Add FRITZ!DECT 200 / FRITZ!Smart Energy 200 support alongside the existing Shelly integration.

## Goal

Allow zihas to poll energy data from smart plugs connected to a FRITZ!Box via the Fritz!Home Automation API, using the same polling and circuit-breaker infrastructure already in place for Shelly plugs.

## Approach

Option A from brainstorming: change `fetch(host)` → `fetch(plug)` across both clients so the Poller calls `@client.fetch(plug)` uniformly. Each client extracts the field it needs (`plug.host` for Shelly, `plug.ain` for Fritz!DECT).

## API — validated against live FRITZ!Box 7530 Fritz!OS 8.02

**Authentication (MD5 challenge-response):**

1. `GET http://<host>/login_sid.lua` → XML containing `<Challenge>` and `<SID>`
2. Compute response: `MD5("<challenge>-<password>".encode("UTF-16LE"))` as lowercase hex
3. `GET http://<host>/login_sid.lua?username=<user>&response=<challenge>-<md5hex>` → XML with valid `<SID>`
4. Cache SID on the instance; re-authenticate lazily when SID is nil or a request returns 403.

**Reading power:**
```
GET /webservices/homeautoswitch.lua?switchcmd=getswitchpower&ain=<ain>&sid=<sid>
```
Response: plain-text integer **milliwatts** (e.g. `342000`). Divide by 1000.0 for Watts.

**Reading energy:**
```
GET /webservices/homeautoswitch.lua?switchcmd=getswitchenergy&ain=<ain>&sid=<sid>
```
Response: plain-text integer **Wh** (e.g. `1195175`). Use directly.

**Invalid SID:** returns `HTTP 403 Forbidden`. Trigger: clear `@sid`, re-authenticate once, retry. If second attempt also fails, raise `Error`.

## Files Changed

| File | Change |
|---|---|
| `lib/fritz_dect_client.rb` | New — stateful client with lazy SID caching |
| `lib/shelly_client.rb` | `fetch(host)` → `fetch(plug)`, use `plug.host` internally |
| `lib/config_loader.rb` | Add `FritzBoxCfg` struct; `fritz_box:` section; `PlugCfg` gains `ain:` and `driver:` fields; validation rules below |
| `lib/poller.rb` | Two changes: `@client.fetch(plug)` instead of `@client.fetch(plug.host)`; rescue `ShellyClient::Error, FritzDectClient::Error` |
| `config/ziwoas.example.yml` | Add `fritz_box:` block + example Fritz!DECT plug entry |
| `test/test_fritz_dect_client.rb` | New — mirrors test_shelly_client.rb structure |
| `test/test_shelly_client.rb` | Update stubs: pass plug struct instead of bare host string |
| `test/test_config_loader.rb` | Tests for `fritz_box:` section and AIN/driver validation |

## Config

```yaml
fritz_box:
  host: 192.168.178.1
  user: fritz6584
  password: secret

plugs:
  - id: bkw
    name: Balkonkraftwerk
    role: producer
    host: 192.168.1.192        # Shelly plug — driver defaults to shelly

  - id: krabbencomputer
    name: Krabbencomputer
    role: consumer
    driver: fritz_dect
    ain: "11630 0206224"       # Fritz!DECT plug — no host field
```

### Validation Rules

- `driver:` ∈ `{shelly, fritz_dect}`, defaults to `shelly` when absent.
- `driver: shelly` → `host:` required, `ain:` forbidden.
- `driver: fritz_dect` → `ain:` required, `host:` forbidden.
- `fritz_box:` section required when at least one plug has `driver: fritz_dect`; otherwise optional/ignored.
- `fritz_box.host`, `fritz_box.user`, `fritz_box.password` all required strings when section is present.

## FritzDectClient — Interface

```ruby
client = FritzDectClient.new(host:, user:, password:, timeout: 2)
reading = client.fetch(plug)  # plug.ain used
# => Reading(apower_w: Float, aenergy_wh: Float)
```

Same `Error < StandardError` and `NETWORK_ERRORS` list as `ShellyClient`.

### fetch(plug) — Internal Flow

1. Authenticate if `@sid` is nil.
2. GET `getswitchpower` → parse integer milliwatts.
3. GET `getswitchenergy` → parse integer Wh.
4. On 403: clear `@sid`, re-authenticate, retry once; raise `Error` if second attempt fails.
5. Raise `Error` on non-200, blank body, or non-integer body.

## ShellyClient — Change

`fetch(plug)` replaces `fetch(host)`. Implementation uses `plug.host` internally. Public interface and error behaviour unchanged.

## Poller — Changes

```ruby
# before
reading = @client.fetch(plug.host)
rescue ShellyClient::Error => e

# after
reading = @client.fetch(plug)
rescue ShellyClient::Error, FritzDectClient::Error => e
```

`ziwoas.rb` constructs one `ShellyClient` and one `FritzDectClient` (if any fritz_dect plugs exist) and passes a `plug_id → client` hash to `Poller`. Poller changes `@client` to `@clients` (hash) and looks up `@clients[plug.id].fetch(plug)` per tick.

## Testing

`test/test_fritz_dect_client.rb` (WebMock):

- `test_parses_successful_response` — stubs auth + both endpoints, asserts W and Wh
- `test_raises_on_403_then_reauth` — stubs 403 on first power call, successful reauth, then success
- `test_raises_on_permanent_403` — stubs 403 after reauth, expects `Error`
- `test_raises_on_timeout`
- `test_raises_on_connection_refused`
- `test_raises_on_blank_body`

`test/test_shelly_client.rb` — update stubs to pass a plug struct.
`test/test_config_loader.rb` — add coverage for driver/ain/fritz_box validation.

## Non-Goals

- No support for Fritz!OS < 7 (PBKDF2 auth not implemented).
- No Fritz!DECT device control (switching on/off).
- No batching via `getdevicelistinfos` — two sequential GETs per plug keeps the code simple and mirrors the Shelly pattern.
