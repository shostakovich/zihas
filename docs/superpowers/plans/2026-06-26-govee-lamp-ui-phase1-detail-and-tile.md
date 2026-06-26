# Govee Lamp UI — Phase 1: Detail Page & Mirrored List Tile — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give simple (single-zone) Govee lamps a proper detail page (hero on/off + master brightness, Weiß-tab with a colour-temperature slider, Farbe-tab with curated swatches), and make the Schalten-tab lamp tile mirror the plug card so the plush on/off knob sits on the right.

**Architecture:** Pure additive UI on top of the existing, working command/status pipeline. A new `GET /lights/:key` show action renders the detail page; a new `light_detail` Stimulus controller drives it, reusing the established optimistic-send + DashboardChannel-reconcile pattern from `lights_controller.js`. The list tile (`_light_card`) is rewritten to reuse the `sw-plug-card` 2×2 grid. No new MQTT topics, no schema changes — `GoveeCommander.turn/set_brightness/set_color/set_color_temp` and `LightSwitchesController` already cover every command Phase 1 sends.

**Tech Stack:** Rails 8.1, Hotwire/Stimulus, ActionCable (DashboardChannel), Minitest + fixtures, plain CSS in `app/assets/stylesheets/application.css`, MQTT via `GoveeCommander`.

## Global Constraints

- Spec: [docs/superpowers/specs/2026-06-26-govee-lamp-ui-design.md](../specs/2026-06-26-govee-lamp-ui-design.md). Visual reference mockups: [tile-v2.html](../specs/2026-06-26-govee-lamp-ui-mockups/tile-v2.html), [colorpicker.html](../specs/2026-06-26-govee-lamp-ui-mockups/colorpicker.html), [layout.html](../specs/2026-06-26-govee-lamp-ui-mockups/layout.html).
- German UI copy throughout (matches existing app).
- Lights are addressed by `:key`, never `:id` (`Light#to_param` returns `key`). Route param is `param: :key`.
- Theme CSS variables (already defined in `application.css`): `--bg #f8f9fa`, `--card #fff`, `--border #dee2e6`, `--text #212529`, `--muted #6c757d`, `--accent #f59f00`, `--accent-bg` (warm gradient), `--online #40c057`, `--offline #adb5bd`.
- **Design tokens (added in Task 0):** all Phase 1 CSS MUST consume tokens, not new literals — radii `--radius-sm 8px` / `--radius-md 12px` / `--radius-lg 16px` / `--radius-pill 999px`; warm shades `--accent-tint #fff3bf` / `--accent-tint-2 #ffe066` / `--accent-ink #7c5e00`; surfaces `--surface-sunk #eef1f4` / `--surface-hover #f1f3f5`; `--danger #e03131`; `--focus-ring (2px solid var(--accent))`; `--glow-accent` (lamp glow). One-off radii not in the scale (e.g. 10px, 11px) stay literal.
- Commands go to `POST /lights/:light_key/command` (`light_command_url`) with `command` ∈ `turn|brightness|color|color_temp`. Do not invent new commands in Phase 1.
- Colour temperature is sent in **kelvin** to the controller (the controller/GoveeCommander converts to mired). Range: 2700 K (warm) … 6500 K (cold).
- Run the full check with `bin/ci` before declaring done; it must be run with the dev stack **stopped** (SQLite lock). Individual tests: `bin/rails test TEST=path -n test_name`.
- JS and CSS have no unit-test harness in this repo (see `lights_controller.js` — untested). For those steps, "verify" means: render-assert the markup/data-attributes in a controller test where possible, plus a stated manual check. Do not claim JS/CSS behaviour is tested when it is only manually checked.

## Phase boundaries (what is NOT in Phase 1)

- **Phase 2** (separate plan): Szenen-tab — own "Stimmungen" (reuse `Preset` applied to a single light) + reading Govee firmware scenes from gv2mqtt `select` discovery and activating them via an `effect` string (needs `GoveeCommander.set_effect` + `GoveeDiscoveryHandler` select handling). Phase 1 renders a `Szenen` tab stub that links to "kommt bald".
- **Phase 3** (separate plan): Uplighter zones (segment entities, zone model, max-2 rule, protected main zone).
- **Phase 4** (separate plan): per-SKU plush assets. Phase 1 uses a **CSS-rendered glow knob** (no image) as the plush placeholder, so nothing blocks on art.

## File Structure

- Modify `config/routes.rb` — add `:show` to `resources :lights`.
- Modify `app/controllers/lights_controller.rb` — add `show` action + `set_light` for it.
- Modify `app/models/light_row.rb` — add detail/tile view-model helpers.
- Create `test/models/light_row_test.rb` — unit tests for the helpers.
- Create `app/views/lights/show.html.erb` — the detail page.
- Create `app/javascript/controllers/light_detail_controller.js` — drives the detail page.
- Modify `app/views/switches/_light_card.html.erb` — rewrite as mirrored tile.
- Delete `app/views/switches/_light_head.html.erb` — folded into the new tile.
- Modify `app/javascript/controllers/lights_controller.js` — keep `toggle`, drop inline `brightness`/`color` (those live on the detail page now).
- Modify `app/assets/stylesheets/application.css` — detail-page styles, nicer slider, tabs, swatches, white slider, and `.sw-light-card` grid + plush knob.
- Modify `test/controllers/lights_controller_test.rb` (create if missing) — show action.
- Modify `test/controllers/switches_controller_test.rb` (create if missing) — tile renders link + knob.

---

### Task 0: Extract design tokens into `:root`

**Files:**
- Modify: `app/assets/stylesheets/application.css` (the `:root` block + file-wide literal→token migration)

**Interfaces:**
- Produces: the token layer every later CSS task (5, 7) consumes. No markup or behaviour change — this is a **value-preserving** refactor (computed styles identical), so it has no dedicated test; verification is the full suite + rubocop staying green.

**Why ordering matters:** do the literal→`var()` replacements **before** adding the `:root` definitions. The definition lines themselves contain the literals (`--surface-sunk: #eef1f4;`), so adding them first would make a global replace rewrite them to `var(--surface-sunk: var(--surface-sunk))`. Replace first, define last.

- [ ] **Step 1: Migrate repeated colour literals (file-wide)**

In `app/assets/stylesheets/application.css`, replace ALL occurrences (these colours currently appear only in rule bodies and the `--accent-bg` gradient — replacing the gradient's `#fff3bf`/`#ffe066` is intended and yields the token-based gradient automatically):

- `#eef1f4` → `var(--surface-sunk)`
- `#f1f3f5` → `var(--surface-hover)`
- `#7c5e00` → `var(--accent-ink)`
- `#e03131` → `var(--danger)`
- `#fff3bf` → `var(--accent-tint)`
- `#ffe066` → `var(--accent-tint-2)`

- [ ] **Step 2: Migrate repeated radii and the focus ring (file-wide)**

Replace ALL occurrences (substring-exact, so `border-radius: 0 0 8px 0` in `.skip-link` is untouched):

- `border-radius: 8px` → `border-radius: var(--radius-sm)`
- `border-radius: 12px` → `border-radius: var(--radius-md)`
- `border-radius: 16px` → `border-radius: var(--radius-lg)`
- `border-radius: 999px` → `border-radius: var(--radius-pill)`
- `outline: 2px solid var(--accent)` → `outline: var(--focus-ring)`

- [ ] **Step 3: Add the token definitions to `:root`**

In the `:root` block of `app/assets/stylesheets/application.css`, replace the `--accent-bg` line with the expanded token set. Change:

```css
  --accent-bg: linear-gradient(135deg, #fff3bf 0%, #ffe066 100%);
```

(which Step 1 has already turned into `linear-gradient(135deg, var(--accent-tint) 0%, var(--accent-tint-2) 100%)`) so the final `:root` reads:

```css
:root {
  --bg: #f8f9fa;
  --card: #ffffff;
  --border: #dee2e6;
  --text: #212529;
  --muted: #6c757d;
  --accent: #f59f00;
  /* warm accent shades */
  --accent-tint: #fff3bf;
  --accent-tint-2: #ffe066;
  --accent-ink: #7c5e00;
  --accent-bg: linear-gradient(135deg, var(--accent-tint) 0%, var(--accent-tint-2) 100%);
  /* surfaces & state */
  --surface-sunk: #eef1f4;
  --surface-hover: #f1f3f5;
  --danger: #e03131;
  --online: #40c057;
  --offline: #adb5bd;
  --solar: #f59e0b;
  /* radii */
  --radius-sm: 8px;
  --radius-md: 12px;
  --radius-lg: 16px;
  --radius-pill: 999px;
  /* effects */
  --focus-ring: 2px solid var(--accent);
  --glow-accent: 0 0 16px 3px rgba(245, 159, 0, .42);
}
```

- [ ] **Step 4: Verify nothing changed visually (suite + rubocop)**

Run: `bin/rails test`
Expected: PASS (unchanged — no test asserts on these literals).
Run: `bin/rubocop` (or rely on `bin/ci` in Task 8) — CSS is not linted by rubocop, but confirm the suite is green.
Spot-check: `grep -n '#eef1f4\|#7c5e00\|#fff3bf\|border-radius: 16px' app/assets/stylesheets/application.css` should now only match inside the `:root` definitions.

- [ ] **Step 5: Commit**

```bash
git add app/assets/stylesheets/application.css
git commit -m "Extract design tokens (radii, accent shades, surfaces, focus ring) into :root"
```

---

### Task 1: LightRow view-model helpers

**Files:**
- Modify: `app/models/light_row.rb`
- Test: `test/models/light_row_test.rb` (create)

**Interfaces:**
- Consumes: `LightState` columns `on, brightness, color_r, color_g, color_b, color_temp_k, reachable`.
- Produces (used by views in Tasks 3 & 7):
  - `LightRow#color_temp_k -> Integer | nil`
  - `LightRow#rgb -> [Integer,Integer,Integer] | nil`
  - `LightRow#color_hex -> String("#rrggbb") | nil`
  - `LightRow#white? -> Boolean` (true when no RGB set, or a positive colour temp is set)
  - `LightRow#default_tab -> "white" | "color"` (`"color"` only when on AND not white)
  - `LightRow#summary -> String` (tile state line, e.g. `"Aus"`, `"An · Weiß · 60 %"`, `"An · Farbe · 60 %"`)
  - `LightRow#chip -> { swatch: String("#rrggbb"), label: String } | nil` (tile bottom-right chip; nil when off)

- [ ] **Step 1: Write the failing tests**

Create `test/models/light_row_test.rb`:

```ruby
require "test_helper"

class LightRowTest < ActiveSupport::TestCase
  def row(attrs)
    light = Light.new(key: "K1", name: "Lampe")
    state = attrs.nil? ? nil : LightState.new(attrs.merge(light_key: "K1"))
    LightRow.new(light: light, state: state)
  end

  test "off light summarises as Aus and has no chip" do
    r = row(on: false, brightness: 60)
    assert_equal "Aus", r.summary
    assert_nil r.chip
    refute r.on?
  end

  test "white light when colour temp set" do
    r = row(on: true, brightness: 60, color_temp_k: 2700)
    assert r.white?
    assert_equal "white", r.default_tab
    assert_equal "An · Weiß · 60 %", r.summary
    assert_nil r.color_hex
  end

  test "colour light exposes hex and colour tab" do
    r = row(on: true, brightness: 40, color_r: 255, color_g: 107, color_b: 61)
    refute r.white?
    assert_equal "color", r.default_tab
    assert_equal "#ff6b3d", r.color_hex
    assert_equal [ 255, 107, 61 ], r.rgb
    assert_equal "An · Farbe · 40 %", r.summary
    assert_equal "#ff6b3d", r.chip[:swatch]
    assert_equal "40 %", r.chip[:label]
  end

  test "no state defaults to off white" do
    r = row(nil)
    assert_equal "Aus", r.summary
    assert r.white?
    assert_equal "white", r.default_tab
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test TEST=test/models/light_row_test.rb`
Expected: FAIL (e.g. `NoMethodError: undefined method 'color_temp_k' for #<LightRow>` / `summary`).

- [ ] **Step 3: Implement the helpers**

Replace the body of `app/models/light_row.rb` with:

```ruby
# Per-light view model for the "Schalten" tab tile and the detail page.
class LightRow
  attr_reader :light, :state

  def self.build_all(lights)
    lights = lights.to_a
    states = LightState.where(light_key: lights.map(&:key)).index_by(&:light_key)
    lights.map { |l| new(light: l, state: states[l.key]) }
  end

  def initialize(light:, state:)
    @light = light
    @state = state
  end

  def on?           = !!state&.on
  def brightness    = state&.brightness || 0
  def reachable?    = !!state&.reachable
  def color_temp_k  = state&.color_temp_k

  def rgb
    return nil unless state&.color_r
    [ state.color_r, state.color_g, state.color_b ]
  end

  def color_hex
    return nil unless rgb
    format("#%02x%02x%02x", *rgb)
  end

  # White when there is no RGB colour, or a positive colour temperature is set.
  def white? = color_temp_k.to_i.positive? || rgb.nil?

  def default_tab = (on? && !white?) ? "color" : "white"

  def summary
    return "Aus" unless on?
    "An · #{white? ? 'Weiß' : 'Farbe'} · #{brightness} %"
  end

  def chip
    return nil unless on?
    { swatch: color_hex || "#ffd9a0", label: "#{brightness} %" }
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test TEST=test/models/light_row_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/models/light_row.rb test/models/light_row_test.rb
git commit -m "Add LightRow detail/tile view-model helpers"
```

---

### Task 2: Detail route + LightsController#show

**Files:**
- Modify: `config/routes.rb:11`
- Modify: `app/controllers/lights_controller.rb`
- Create: `app/views/lights/show.html.erb` (minimal renderable stub so the action is testable green; Task 3 replaces it with the full page)
- Test: `test/controllers/lights_controller_test.rb` (create)

**Interfaces:**
- Consumes: `LightRow.build_all` (Task 1), `Light.find_by!(key:)`.
- Produces: route helper `light_url(key)` / `light_path(key)` → `GET /lights/:key` rendering `lights/show` with `@row` (a `LightRow`) and `@light`.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/lights_controller_test.rb`:

```ruby
require "test_helper"

class LightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Light.delete_all
    @light = Light.create!(key: "ABCDEF01", name: "Wohnzimmer Stehlampe",
                           supports_color: true, supports_color_temp: true)
  end

  test "show renders the detail page for a light by key" do
    LightState.record_state(@light.key, on: true, brightness: 60, color_temp_k: 2700)
    get light_url(@light.key)
    assert_response :success
    assert_match "Wohnzimmer Stehlampe", @response.body
    assert_select "[data-controller='light-detail']"
    assert_select "[data-light-detail-key-value=?]", @light.key
  end

  test "show 404s for unknown key" do
    assert_raises(ActiveRecord::RecordNotFound) { get light_url("NOPE") }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test TEST=test/controllers/lights_controller_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'light_url'` (route missing) or `UnknownAction`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, change line 11 from:

```ruby
  resources :lights, param: :key, only: %i[index edit update destroy]
```

to:

```ruby
  resources :lights, param: :key, only: %i[index show edit update destroy]
```

- [ ] **Step 4: Add the controller action**

In `app/controllers/lights_controller.rb`, update the `before_action` and add `show`:

```ruby
class LightsController < ApplicationController
  before_action :set_light, only: %i[show edit update destroy]

  def index = (@lights = Light.includes(:room).order(:name))

  def show
    @row = LightRow.new(light: @light, state: LightState.find_by(light_key: @light.key))
  end

  def edit; end
```

(Leave the rest of the controller unchanged.)

- [ ] **Step 5: Add a minimal renderable view stub**

So the action renders green now; Task 3 replaces this stub with the full page. Create `app/views/lights/show.html.erb`:

```erb
<% content_for :title, @light.name %>
<% content_for :body_class, "page-light-detail" %>

<div class="ld" data-controller="light-detail"
     data-light-detail-key-value="<%= @light.key %>"
     data-light-detail-tab-value="<%= @row.default_tab %>">
  <div class="ld-topbar">
    <%= link_to "←", switches_path, class: "ld-back", "aria-label": "Zurück" %>
    <span class="ld-title"><%= @light.name %></span>
  </div>
</div>
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test TEST=test/controllers/lights_controller_test.rb`
Expected: PASS (2 runs, 0 failures — the stub satisfies the `data-controller`/`data-light-detail-key-value`/name assertions; richer hero/tab assertions are added in Task 3).

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/lights_controller.rb app/views/lights/show.html.erb test/controllers/lights_controller_test.rb
git commit -m "Add lights#show route, action and a minimal detail view"
```

---

### Task 3: Detail page view (hero + tabs, server-rendered)

**Files:**
- Modify: `app/views/lights/show.html.erb` (replace the Task 2 stub with the full page)
- Test: `test/controllers/lights_controller_test.rb` (extend — assert structure)

**Interfaces:**
- Consumes: `@row` (`LightRow`), `@light`. Route helpers `switches_path`, `light_command_url`.
- Produces: DOM the `light_detail` Stimulus controller (Task 4) binds to. Stable hooks:
  - root `[data-controller="light-detail"]` with `data-light-detail-key-value`, `data-light-detail-tab-value` (initial tab).
  - power buttons `[data-action="light-detail#on"]`, `[data-action="light-detail#off"]`.
  - brightness `input[type=range][data-light-detail-target="brightness"]`.
  - tab buttons `[data-action="light-detail#tab"][data-tab-param="white|color|scenes"]`.
  - panels `[data-light-detail-target="panel"][data-tab="white|color|scenes"]`.
  - white slider `input[type=range][data-light-detail-target="temp"]` (min 2700 max 6500).
  - colour swatches `[data-action="light-detail#swatch"][data-color-param="#rrggbb"]` and `input[type=color][data-light-detail-target="wheel"]`.

- [ ] **Step 1: Write the view**

Replace the Task 2 stub at `app/views/lights/show.html.erb` with the full page:

```erb
<% content_for :title, @light.name %>
<% content_for :body_class, "page-light-detail" %>

<div class="ld" data-controller="light-detail"
     data-light-detail-key-value="<%= @light.key %>"
     data-light-detail-tab-value="<%= @row.default_tab %>">

  <div class="ld-topbar">
    <%= link_to "←", switches_path, class: "ld-back", "aria-label": "Zurück" %>
    <span class="ld-title"><%= @light.name %></span>
  </div>

  <div class="ld-hero<%= ' is-off' unless @row.on? %>">
    <div class="ld-lamp" data-light-detail-target="lamp"></div>
    <div class="ld-power">
      <button class="ld-pill<%= ' on' if @row.on? %>" data-action="light-detail#on">An</button>
      <button class="ld-pill<%= ' on' unless @row.on? %>" data-action="light-detail#off">Aus</button>
    </div>
  </div>

  <div class="ld-card">
    <p class="ld-label">Helligkeit</p>
    <input class="ld-range" type="range" min="1" max="100" value="<%= [@row.brightness, 1].max %>"
           data-light-detail-target="brightness" data-action="light-detail#brightness"
           aria-label="Helligkeit">
  </div>

  <div class="ld-tabs">
    <button class="ld-tab" data-action="light-detail#tab" data-tab-param="white">Weiß</button>
    <% if @light.supports_color %>
      <button class="ld-tab" data-action="light-detail#tab" data-tab-param="color">Farbe</button>
    <% end %>
    <button class="ld-tab" data-action="light-detail#tab" data-tab-param="scenes">Szenen</button>
  </div>

  <div class="ld-panel" data-light-detail-target="panel" data-tab="white">
    <div class="ld-card">
      <p class="ld-label">Lichtfarbe</p>
      <input class="ld-range ld-white" type="range" min="2700" max="6500" step="100"
             value="<%= @row.color_temp_k || 2700 %>"
             data-light-detail-target="temp" data-action="light-detail#temp"
             aria-label="Lichtfarbe (Kelvin)">
      <div class="ld-scale"><span>2700 K · warm</span><span>6500 K · kalt</span></div>
      <div class="ld-presets">
        <button class="ld-preset" data-action="light-detail#temp" data-tab-param="2700" data-temp-param="2700">Gemütlich</button>
        <button class="ld-preset" data-action="light-detail#temp" data-tab-param="4000" data-temp-param="4000">Neutral</button>
        <button class="ld-preset" data-action="light-detail#temp" data-tab-param="6000" data-temp-param="6000">Arbeiten</button>
      </div>
    </div>
  </div>

  <% if @light.supports_color %>
    <div class="ld-panel" data-light-detail-target="panel" data-tab="color" hidden>
      <div class="ld-card">
        <p class="ld-label">Farbe</p>
        <div class="ld-swatches">
          <% %w[#ff4d4d #ff7a3d #ffd43b #43d97f #22b8cf #4d7cff #7c5cff #ff6bd6].each do |hex| %>
            <button class="ld-sw" style="background: <%= hex %>"
                    data-action="light-detail#swatch" data-color-param="<%= hex %>"
                    aria-label="Farbe <%= hex %>"></button>
          <% end %>
          <label class="ld-sw ld-more" aria-label="Weitere Farbe">⊕
            <input type="color" data-light-detail-target="wheel"
                   data-action="light-detail#wheel" value="<%= @row.color_hex || '#ff7a3d' %>">
          </label>
        </div>
      </div>
    </div>
  <% end %>

  <div class="ld-panel" data-light-detail-target="panel" data-tab="scenes" hidden>
    <div class="ld-card ld-soon">Szenen kommen in Phase 2.</div>
  </div>

  <div class="ld-error" data-light-detail-target="error"></div>
</div>
```

- [ ] **Step 2: Extend the controller test**

Append to `test/controllers/lights_controller_test.rb` (inside the class):

```ruby
  test "show has hero, brightness, white slider and tabs" do
    get light_url(@light.key)
    assert_response :success
    assert_select "button[data-action='light-detail#on']"
    assert_select "input[type=range][data-light-detail-target='brightness']"
    assert_select "input[type=range][data-light-detail-target='temp'][min='2700'][max='6500']"
    assert_select "button[data-tab-param='white']"
    assert_select "button[data-tab-param='color']"
  end

  test "show hides colour tab when the light has no colour support" do
    @light.update!(supports_color: false)
    get light_url(@light.key)
    assert_select "button[data-tab-param='color']", count: 0
  end
```

- [ ] **Step 3: Run the tests to verify they pass**

Run: `bin/rails test TEST=test/controllers/lights_controller_test.rb`
Expected: PASS (4 runs incl. Task 2's, 0 failures).

- [ ] **Step 4: Commit**

```bash
git add app/views/lights/show.html.erb test/controllers/lights_controller_test.rb
git commit -m "Add lamp detail page view (hero, brightness, Weiß/Farbe tabs)"
```

---

### Task 4: light_detail Stimulus controller

**Files:**
- Create: `app/javascript/controllers/light_detail_controller.js`

**Interfaces:**
- Consumes: DOM hooks from Task 3; `POST /lights/:key/command` with `command` ∈ `turn|brightness|color|color_temp`; DashboardChannel `{ lights: [...] }` broadcasts (shape from `GoveeStatusHandler`: `light_key, on, brightness, color_r/g/b, color_temp_k, reachable`).
- Produces: none (leaf UI controller). Auto-registered by `eagerLoadControllersFrom` (file name = identifier `light-detail`).

- [ ] **Step 1: Write the controller**

Create `app/javascript/controllers/light_detail_controller.js`:

```javascript
// Connects to data-controller="light-detail". Drives the lamp detail page:
// power, brightness, colour-temperature (Weiß) and colour swatches (Farbe).
// Optimistic send + reconcile against DashboardChannel { lights:[...] }.
import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static values = { key: String, tab: String }
  static targets = ["panel", "brightness", "temp", "wheel", "error", "lamp"]

  connect() {
    this.showTab(this.tabValue || "white")
    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => this.onBroadcast(data),
    })
  }

  disconnect() { this.subscription?.unsubscribe() }

  // --- tabs ---
  tab(event) { this.showTab(event.params.tab) }

  showTab(name) {
    this.tabValue = name
    this.panelTargets.forEach((p) => { p.hidden = p.dataset.tab !== name })
    this.element.querySelectorAll(".ld-tab").forEach((b) => {
      b.classList.toggle("active", b.dataset.tabParam === name)
    })
  }

  // --- commands ---
  on() { this.send({ command: "turn", on: "true" }) }
  off() { this.send({ command: "turn", on: "false" }) }

  brightness(event) {
    this.debounce(() => this.send({ command: "brightness", value: event.target.value }))
  }

  temp(event) {
    const k = event.params.temp ?? event.target.value
    if (this.hasTempTarget && event.params.temp) this.tempTarget.value = k
    this.debounce(() => this.send({ command: "color_temp", temp_k: k }))
  }

  swatch(event) { this.applyHex(event.params.color) }
  wheel(event) { this.applyHex(event.target.value) }

  applyHex(hex) {
    const r = parseInt(hex.slice(1, 3), 16)
    const g = parseInt(hex.slice(3, 5), 16)
    const b = parseInt(hex.slice(5, 7), 16)
    this.debounce(() => this.send({ command: "color", r, g, b }))
  }

  // --- plumbing ---
  debounce(fn) { clearTimeout(this._d); this._d = setTimeout(fn, 250) }

  send(body) {
    this.element.classList.add("pending")
    fetch(`/lights/${this.keyValue}/command`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      },
      body: new URLSearchParams(body).toString(),
    })
    clearTimeout(this._timeout)
    this._timeout = setTimeout(() => this.unconfirmed(), 5000)
  }

  onBroadcast(data) {
    if (!Array.isArray(data.lights)) return
    const light = data.lights.find((l) => l.light_key === this.keyValue)
    if (!light) return
    clearTimeout(this._timeout)
    this.element.classList.remove("pending", "unconfirmed")
    if (this.hasErrorTarget) this.errorTarget.textContent = ""
    this.element.classList.toggle("is-off", light.on === false)
    this.element.querySelectorAll(".ld-pill").forEach((b) => {
      const wantsOn = b.dataset.action.includes("#on")
      b.classList.toggle("on", wantsOn === (light.on === true))
    })
    if (typeof light.brightness === "number" && this.hasBrightnessTarget) {
      this.brightnessTarget.value = light.brightness
    }
    if (typeof light.color_temp_k === "number" && this.hasTempTarget) {
      this.tempTarget.value = light.color_temp_k
    }
  }

  unconfirmed() {
    this.element.classList.remove("pending")
    this.element.classList.add("unconfirmed")
    if (this.hasErrorTarget) this.errorTarget.textContent = "Nicht bestätigt"
  }
}
```

- [ ] **Step 2: Verify it registers (no build errors)**

Run: `bin/rails test TEST=test/controllers/lights_controller_test.rb` (importmap is checked on boot; a syntax error would surface). Expected: PASS.

- [ ] **Step 3: Manual check (stated, not automated)**

With the dev stack running (`bin/dev -m all=1`) and a discovered light, open `/lights/<key>`: toggling An/Aus, dragging brightness, switching to Weiß and dragging the temperature slider, and tapping a colour swatch each send a command (Network tab shows `POST /lights/<key>/command`) and the card stops "pending" when the broadcast returns. Note in the commit body that this was manually verified.

- [ ] **Step 4: Commit**

```bash
git add app/javascript/controllers/light_detail_controller.js
git commit -m "Add light_detail Stimulus controller (power/brightness/temp/colour)"
```

---

### Task 5: Detail-page CSS

**Files:**
- Modify: `app/assets/stylesheets/application.css` (append a new section)

**Interfaces:** Styles the classes emitted in Task 3. No behaviour.

- [ ] **Step 1: Append the styles**

Add to the end of `app/assets/stylesheets/application.css`:

```css
/* ---- Lamp detail page ---- */
body.page-light-detail { max-width: 560px; }
.ld-topbar { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
.ld-back { width: 34px; height: 34px; border-radius: 10px; border: 1px solid var(--border);
           background: var(--card); display: inline-flex; align-items: center; justify-content: center;
           font-size: 17px; text-decoration: none; color: var(--text); }
.ld-title { font-weight: 600; font-size: 18px; }
.ld-card { background: var(--card); border: 1px solid var(--border); border-radius: var(--radius-lg);
           padding: 14px; margin-bottom: 12px; }
.ld-hero { display: flex; align-items: center; gap: 14px; background: var(--card);
           border: 1px solid var(--border); border-radius: var(--radius-lg); padding: 14px; margin-bottom: 12px; }
.ld-lamp { width: 58px; height: 58px; border-radius: 50%; flex-shrink: 0;
           background: radial-gradient(circle at 50% 38%, var(--accent-tint) 0%, var(--accent-tint-2) 45%, var(--accent) 100%);
           box-shadow: var(--glow-accent); }
.ld-hero.is-off .ld-lamp { background: var(--surface-sunk); box-shadow: none; filter: grayscale(.4); }
.ld-power { display: flex; gap: 8px; flex: 1; }
.ld-pill { flex: 1; padding: 10px 0; border-radius: 11px; font-weight: 600; font-size: 13px;
           border: 1px solid var(--border); background: var(--card); color: var(--muted); cursor: pointer; }
.ld-pill.on { background: var(--accent-bg); border-color: var(--accent); color: var(--accent-ink); }
.ld-label { font-size: 11px; text-transform: uppercase; letter-spacing: .5px; color: var(--muted);
            margin: 0 0 9px; }
/* nicer slider (replaces bare range) */
.ld-range { -webkit-appearance: none; appearance: none; width: 100%; height: 34px; border-radius: var(--radius-pill);
            background: linear-gradient(90deg, var(--accent-tint), var(--accent)); outline: none; }
.ld-range.ld-white { background: linear-gradient(90deg, #ffb24d, #ffe7c2, #fff, #dcebff, #bcd6ff); }
.ld-range::-webkit-slider-thumb { -webkit-appearance: none; appearance: none; width: 28px; height: 28px;
            border-radius: 50%; background: #fff; border: 2px solid var(--accent);
            box-shadow: 0 1px 4px rgba(0,0,0,.3); cursor: pointer; }
.ld-range::-moz-range-thumb { width: 28px; height: 28px; border-radius: 50%; background: #fff;
            border: 2px solid var(--accent); box-shadow: 0 1px 4px rgba(0,0,0,.3); cursor: pointer; }
.ld-range:focus-visible { outline: 3px solid var(--accent); outline-offset: 3px; }
.ld-scale { display: flex; justify-content: space-between; font-size: 11px; color: var(--muted);
            margin-top: 6px; }
.ld-presets { display: flex; gap: 8px; margin-top: 12px; }
.ld-preset { flex: 1; padding: 8px 0; border-radius: 10px; border: 1px solid var(--border);
             background: var(--card); color: var(--text); font-size: 12px; cursor: pointer; }
.ld-tabs { display: flex; gap: 6px; margin-bottom: 12px; }
.ld-tab { flex: 1; padding: 9px 0; border-radius: 11px; font-size: 12px; font-weight: 600;
          border: 1px solid var(--border); background: var(--card); color: var(--muted); cursor: pointer; }
.ld-tab.active { background: var(--accent-bg); border-color: var(--accent); color: var(--accent-ink); }
.ld-swatches { display: grid; grid-template-columns: repeat(5, 1fr); gap: 10px; }
.ld-sw { aspect-ratio: 1; border-radius: 10px; border: 1px solid rgba(0,0,0,.12); cursor: pointer;
         display: inline-flex; align-items: center; justify-content: center; }
.ld-sw:focus-visible { outline: var(--focus-ring); outline-offset: 2px; }
.ld-more { background: conic-gradient(red,#ff0,#0f0,#0ff,#00f,#f0f,red); color: #fff; font-size: 17px;
           text-shadow: 0 0 3px rgba(0,0,0,.6); position: relative; overflow: hidden; }
.ld-more input[type=color] { position: absolute; inset: 0; opacity: 0; cursor: pointer; }
.ld-soon { color: var(--muted); font-size: 14px; }
.ld-error { font-size: 12px; color: var(--danger); margin-top: 2px; min-height: 16px; }
.ld.pending { opacity: .85; }
.ld.unconfirmed .ld-hero { border-color: var(--danger); }
```

- [ ] **Step 2: Manual check (stated, not automated)**

Reload `/lights/<key>`: the slider is a filled rounded pill with a round thumb; the Weiß slider shows the warm→cold gradient; tabs highlight the active one; swatches form a 5-column grid; the ⊕ tile opens the native colour input. Note manual verification in the commit body.

- [ ] **Step 3: Commit**

```bash
git add app/assets/stylesheets/application.css
git commit -m "Style the lamp detail page (slider, tabs, swatches, white gradient)"
```

---

### Task 6: Trim lights_controller.js to the list knob

**Files:**
- Modify: `app/javascript/controllers/lights_controller.js`

**Interfaces:**
- Consumes: list tile DOM (Task 7) — `[data-light-key]`, `button.sw-knob`, DashboardChannel `{ lights:[...] }`.
- Produces: `toggle(event)` action (knob on/off) only. Brightness/colour now live on the detail page (Task 4), so they are removed here.

- [ ] **Step 1: Replace the controller**

Replace the whole of `app/javascript/controllers/lights_controller.js` with:

```javascript
// Connects to data-controller="lights" on the Schalten list. Only the plush
// knob toggles power here; brightness/colour live on the lamp detail page.
// Optimistic toggle, reconciled by DashboardChannel { lights:[...] }.
import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  connect() {
    this.timeouts = {}
    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => this.handleBroadcast(data),
    })
  }

  disconnect() { this.subscription?.unsubscribe() }

  toggle(event) {
    event.preventDefault()
    const key = event.params.key
    const card = this.cardFor(key)
    if (!card) return
    const on = !card.querySelector("button.sw-knob").classList.contains("off")
    this.send(key, { command: "turn", on: (!on).toString() })
  }

  send(key, body) {
    const card = this.cardFor(key)
    if (card) card.classList.add("pending")
    fetch(`/lights/${key}/command`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      },
      body: new URLSearchParams(body).toString(),
    })
    clearTimeout(this.timeouts[key])
    this.timeouts[key] = setTimeout(() => this.markUnconfirmed(key), 5000)
  }

  handleBroadcast(data) {
    if (!Array.isArray(data.lights)) return
    data.lights.forEach((light) => this.applyState(light))
  }

  applyState(light) {
    const card = this.cardFor(light.light_key)
    if (!card) return
    clearTimeout(this.timeouts[light.light_key])
    card.classList.remove("pending", "unconfirmed")
    if (typeof light.on === "boolean") {
      const knob = card.querySelector("button.sw-knob")
      if (knob) knob.classList.toggle("off", !light.on)
    }
    const error = card.querySelector(".sw-error")
    if (error) error.textContent = ""
  }

  markUnconfirmed(key) {
    const card = this.cardFor(key)
    if (!card) return
    card.classList.remove("pending")
    card.classList.add("unconfirmed")
    const error = card.querySelector(".sw-error")
    if (error) error.textContent = "Nicht bestätigt"
  }

  cardFor(key) { return this.element.querySelector(`[data-light-key="${key}"]`) }
}
```

- [ ] **Step 2: Verify boot/tests still pass**

Run: `bin/rails test TEST=test/controllers/switches_controller_test.rb` (created in Task 7) — or, before Task 7, `bin/rails test TEST=test/controllers/lights_controller_test.rb`. Expected: PASS (no JS error on boot).

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/lights_controller.js
git commit -m "Trim lights list controller to the power knob only"
```

---

### Task 7: Rewrite the list tile to mirror the plug card

**Files:**
- Modify: `app/views/switches/_light_card.html.erb`
- Delete: `app/views/switches/_light_head.html.erb`
- Modify: `app/assets/stylesheets/application.css` (add `.sw-light-card` rules)
- Test: `test/controllers/switches_controller_test.rb` (create)

**Interfaces:**
- Consumes: `row` (`LightRow`, Task 1) — `light.key`, `light.name`, `on?`, `summary`, `chip`. Route helper `light_path(key)`. The `data-controller="lights"` wrapper (already in `switches/index.html.erb`) provides the `toggle` action (Task 6).
- Produces: a tile with the `sw-plug-card` grid: `info` (top-left), `sw-knob` (top-right), `Anpassen ›` link (bottom-left), chip (bottom-right). Card surface links to `light_path`; the knob toggles and stops propagation.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/switches_controller_test.rb`:

```ruby
require "test_helper"

class SwitchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Light.delete_all
    @light = Light.create!(key: "ABCDEF01", name: "Wohnzimmer Stehlampe")
    LightState.record_state(@light.key, on: true, brightness: 60, color_temp_k: 2700)
  end

  test "lamp tile links to the detail page and exposes a toggle knob" do
    get switches_url
    assert_response :success
    assert_select "a.sw-light-link[href=?]", light_path(@light.key)
    assert_select ".sw-light-card[data-light-key=?] button.sw-knob", @light.key
    assert_match "Wohnzimmer Stehlampe", @response.body
    assert_match "An · Weiß · 60 %", @response.body
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test TEST=test/controllers/switches_controller_test.rb`
Expected: FAIL (no `a.sw-light-link`; current tile renders a slider/colour input instead).

- [ ] **Step 3: Rewrite the partial**

Replace the whole of `app/views/switches/_light_card.html.erb` with:

```erb
<%# app/views/switches/_light_card.html.erb %>
<div class="sw-card sw-light-card<%= ' sw-offline' unless row.on? %>"
     id="light_card_<%= row.light.key %>" data-light-key="<%= row.light.key %>">
  <%= link_to light_path(row.light.key), class: "sw-light-link", "aria-label": "#{row.light.name} Details" do %>
    <div class="sw-info">
      <span class="sw-name"><%= row.light.name %></span>
      <div class="sw-state"><%= row.summary %></div>
      <div class="sw-error" id="light_error_<%= row.light.key %>"></div>
    </div>
  <% end %>

  <button class="sw-knob sw-lamp-knob<%= ' off' unless row.on? %>"
          data-action="lights#toggle" data-lights-key-param="<%= row.light.key %>"
          aria-label="<%= row.light.name %> umschalten"></button>

  <%= link_to "Anpassen ›", light_path(row.light.key), class: "sw-light-sub" %>

  <% if (chip = row.chip) %>
    <span class="sw-watt-chip">
      <span class="sw-swatch" style="background: <%= chip[:swatch] %>"></span><%= chip[:label] %>
    </span>
  <% end %>
</div>
```

- [ ] **Step 4: Delete the now-unused head partial**

```bash
git rm app/views/switches/_light_head.html.erb
```

- [ ] **Step 5: Add the tile CSS**

Append to `app/assets/stylesheets/application.css` (near the other `.sw-*` rules):

```css
/* lamp tile mirrors the plug card 2x2 grid */
.sw-light-card { display: grid; grid-template-columns: 1fr auto;
                 column-gap: 14px; row-gap: 8px; align-items: center;
                 grid-template-areas: "info knob" "sub aux"; }
.sw-light-link { grid-area: info; min-width: 0; text-decoration: none; color: inherit; display: block; }
.sw-light-card .sw-knob { grid-area: knob; justify-self: end; }
.sw-state { font-size: 13px; color: var(--muted); margin-top: 3px; }
.sw-light-sub { grid-area: sub; align-self: start; font-size: 13px; color: var(--muted);
                text-decoration: none; }
.sw-light-card .sw-watt-chip { grid-area: aux; }
.sw-swatch { width: 13px; height: 13px; border-radius: 4px; border: 1px solid rgba(0,0,0,.15); }
/* plush placeholder: a glowing knob, tinted via CSS (real assets in Phase 4) */
.sw-lamp-knob { border-color: var(--accent);
                background: radial-gradient(circle at 50% 38%, var(--accent-tint), var(--accent-tint-2) 55%, var(--accent));
                background-image: none; box-shadow: var(--glow-accent); }
.sw-lamp-knob.off { border-color: var(--offline);
                    background: var(--surface-sunk); box-shadow: none; filter: grayscale(.35); }
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test TEST=test/controllers/switches_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/views/switches/_light_card.html.erb app/assets/stylesheets/application.css test/controllers/switches_controller_test.rb
git commit -m "Rewrite lamp list tile to mirror plug card (plush knob right, links to detail)"
```

---

### Task 8: Full check & cleanup

**Files:** none (verification).

- [ ] **Step 1: Run the full suite**

Ensure the dev stack is stopped (SQLite lock), then run:

Run: `bin/ci`
Expected: Rubocop clean, Brakeman clean, all Rails tests pass (existing + the new LightRow/Lights/Switches tests).

- [ ] **Step 2: Manual end-to-end check (stated)**

`bin/dev -m all=1`, open Schalten: lamp tiles show the plush knob on the right aligned with plug knobs, with `An · … · NN %` and a colour/brightness chip. Tap the knob → toggles. Tap the card / "Anpassen ›" → detail page. On the detail page exercise power, brightness, Weiß slider + presets, Farbe swatches + ⊕. Confirm broadcasts clear the "pending" state.

- [ ] **Step 3: Commit any rubocop autofixes**

If `bin/ci` reported rubocop offences, fix them and:

```bash
git add -A
git commit -m "Fix rubocop offences in lamp UI Phase 1"
```

---

## Self-Review

**Spec coverage (Phase 1 slice):**
- Detail page with Back-nav + hero (on/off + master brightness) → Tasks 2, 3, 4, 5. ✓
- Nicer brightness slider → Task 5 (`.ld-range`). ✓
- Weiß-tab default + temperature slider 2700–6500 K + 3 presets → Tasks 3, 4, 5; `default_tab` (Task 1) makes Weiß the default unless the light is currently in colour. ✓
- Farbe-tab with curated swatches + ⊕ (native colour input as the "more" fallback; the full HSV wheel is deliberately deferred and flagged) → Tasks 3, 4, 5. ✓
- List tile mirrors plug card, plush knob right, card→detail, knob→toggle → Tasks 6, 7. ✓
- Plush = CSS-tinted glow placeholder; real per-SKU assets explicitly deferred to Phase 4. ✓
- Szenen, Stimmungen, zones → explicitly out of Phase 1 (stub tab only), tracked as Phases 2–3.

**Placeholder scan:** No "TBD/TODO" in steps; every code step shows complete code. The `⊕` native-colour-input and the CSS-glow plush are real, working implementations (not placeholders) with their richer successors scheduled in later phases — called out so they are not mistaken for finished scope.

**Type/selector consistency:** Stimulus identifier `light-detail` matches the file `light_detail_controller.js` and `data-controller="light-detail"`. Targets used in Task 4 (`panel, brightness, temp, wheel, error, lamp`) all exist in Task 3's markup. Command names (`turn|brightness|color|color_temp`) and the broadcast field names (`light_key, on, brightness, color_temp_k`) match `LightSwitchesController` and `GoveeStatusHandler` verbatim. `light_path`/`light_url` is enabled by adding `:show` (Task 2). `row.summary`/`row.chip` (Task 1) are the exact methods the tile (Task 7) calls.

**Token consistency:** every token used in Tasks 5 & 7 (`--radius-lg`, `--radius-pill`, `--accent-tint`, `--accent-tint-2`, `--accent-ink`, `--surface-sunk`, `--danger`, `--focus-ring`, `--glow-accent`) is defined in Task 0's `:root` block. Task 0 runs first, so the tokens exist before any consumer. One-off radii (10px, 11px) and the multi-stop white-slider gradient stay literal by design (not part of the scale / single-use).

## Follow-up plans (not this plan)

- **Phase 2 — Szenen & Stimmungen:** reuse `Preset` for per-lamp "Stimmungen" (add a per-light apply path), read Govee firmware scenes from gv2mqtt `select` discovery (extend `GoveeDiscoveryHandler`), add `GoveeCommander.set_effect` + a `scene`/`effect` command in `LightSwitchesController`, fill the Szenen tab.
- **Phase 3 — Zonen (Uplighter):** segment-entity discovery + zone model, zone cards, max-2 rule with protected main zone + undo toast, adaptive detail page (zones tab default, no master slider).
- **Phase 4 — Plüsch-Assets:** per-SKU plush webp (uplighter/floorlamp/sconce/ceiling/generic), on/off, CSS-tinted glow; SKU→asset map; replace the Phase 1 CSS-glow placeholder.
