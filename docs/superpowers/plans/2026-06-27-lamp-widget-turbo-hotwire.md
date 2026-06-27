# Lampen-Detail-Widget: Turbo + Hotwire — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Das Lampen-Detail-Widget von JS-getriebenem DOM-Mutieren auf server-gerenderte Turbo Streams umstellen; Stimulus nur noch für Slider, Tabs und einen Toast-Timer. Als Nebeneffekt: Zonen-Zustand wird server-seitig persistiert und übersteht Reload.

**Architecture:** Veränderliche UI-Fragmente werden Partials (`_power`, `_zone`, `_toast`), die `show.html.erb` initial und die Command-Antworten/Broadcasts identisch rendern. Buttons werden `button_to` (Turbo-Forms), die mit `turbo_stream`-Replace antworten. Externe Änderungen kommen über einen per-Lampe-Turbo-Stream (`light_<key>`), den der Collector via `Turbo::StreamsChannel.broadcast_replace_to` füttert. Der bestehende rohe `"dashboard"`-Kanal (Switches-Seite) bleibt unangetastet.

**Tech Stack:** Rails 7, Hotwire (turbo-rails bereits im Gemfile + importmap), Stimulus (importmap eager-load), solid_cable (DB-backed ActionCable), Minitest/`ActionDispatch::IntegrationTest`.

## Global Constraints

- Scope: nur das Detail-Widget. Der `"dashboard"`-ActionCable-Broadcast in `GoveeStatusHandler`/`GoveeZoneStateHandler` bleibt erhalten — nur ergänzen, nie ersetzen.
- Opfer-Wahl bei max-2-auto-off: **deterministisch die andere an-Seiten-Zone** (Entscheidung B). Keine Aktivierungs-Reihenfolge mitführen.
- Zonen-Toggle ist server-driven: kein optimistisches DOM. Reihenfolge im Command-Pfad immer: **persistieren (`LightState.record_zone_state`) → MQTT (`GoveeCommander.set_zone`)**.
- Zonen-Instanzen und Rollen kommen aus `Light::ZONE_META` (`{ "bottomLightToggle" => {label:"Leselicht", role:"main"}, "rippleLightToggle" => {label:"Welle", role:"side"}, "sideLightToggle" => {label:"Seite", role:"side"}, ... }`).
- Partials sind ausschließlich locals-basiert (kein `@row`/`@light`), damit der Collector sie ohne Controller-Kontext rendern kann.
- Tests laufen mit `bin/rails test test/...`. Mindest-Coverage (test_helper): line 70 / branch 71 — nicht unterschreiten.
- Commit am Ende jeder Task. Branch ist `feature/govee-lights` (kein PR/Push ohne Aufforderung).

---

### Task 1: Zonen-Zustand im Command-Pfad persistieren (Bug-Fix)

Kleinster wertvoller Schritt, der den Reload-Bug allein behebt — unabhängig vom View-Umbau.

**Files:**
- Modify: `app/controllers/light_switches_controller.rb` (Branch `when "zone"`, Z. 16-18)
- Test: `test/controllers/light_switches_controller_test.rb`

**Interfaces:**
- Consumes: `LightState.record_zone_state(light_key, instance, on) -> Boolean` (existiert, `app/models/light_state.rb:22`), `GoveeCommander.set_zone(light, zone:, on:, mqtt_config:, mqtt_factory:)` (existiert).
- Produces: keine neuen Signaturen.

- [ ] **Step 1: Failing test — Zonen-Command schreibt zone_states**

In `test/controllers/light_switches_controller_test.rb` ans Ende der Klasse einfügen:

```ruby
  test "zone command persists the zone state" do
    Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle rippleLightToggle])
    GoveeCommander.stub(:set_zone, ->(*, **) {}) do
      post light_command_url(light_key: "UP1"), params: { command: "zone", zone: "rippleLightToggle", on: "true" }
    end
    assert_response :accepted
    assert_equal({ "rippleLightToggle" => true }, LightState.find_by(light_key: "UP1").zone_states)
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb -n "/zone command persists/"`
Expected: FAIL — `zone_states` is `{}`, not `{"rippleLightToggle" => true}`.

- [ ] **Step 3: Persist in the controller**

In `app/controllers/light_switches_controller.rb` den `when "zone"`-Branch ersetzen:

```ruby
    when "zone"
      return head :unprocessable_entity unless light.zones.include?(params[:zone])
      on = cast_bool(params[:on])
      LightState.record_zone_state(light.key, params[:zone], on)
      GoveeCommander.set_zone(light, zone: params[:zone], on: on, **opts)
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb`
Expected: PASS (alle Tests grün, inkl. der bestehenden "zone command toggles a valid zone").

- [ ] **Step 5: Commit**

```bash
git add app/controllers/light_switches_controller.rb test/controllers/light_switches_controller_test.rb
git commit -m "fix(lights): persist zone_states on zone command so it survives reload"
```

---

### Task 2: Partials extrahieren (`_power`, `_zone`, `_toast`)

Reiner Refactor: `show.html.erb` rendert dieselben Fragmente aus Partials. Noch kein Verhaltenswechsel, JS bleibt vorerst dran. Liefert die einzige Render-Quelle für spätere Streams.

**Files:**
- Create: `app/views/lights/_power.html.erb`
- Create: `app/views/lights/_zone.html.erb`
- Create: `app/views/lights/_toast.html.erb`
- Modify: `app/views/lights/show.html.erb` (Z. 14-20 Hero, Z. 42-55 Zonen, Z. 123-126 Toast)
- Test: `test/controllers/lights_controller_test.rb`

**Interfaces:**
- Produces (Partial-Locals-Verträge, von Task 3/7 genutzt):
  - `lights/power` locals: `light:` (Light), `row:` (LightRow). DOM-ID `light_power`.
  - `lights/zone` locals: `zone:` (LightRow::Zone), `light_key:` (String). DOM-ID `zone_<zone.key>`.
  - `lights/toast` locals: `message:` (String|nil), `undo:` (Hash{light_key,victim,added}|nil). DOM-ID `light_toast`.

- [ ] **Step 1: Failing test — show rendert Zonen-Karte mit DOM-ID aus persistiertem State**

In `test/controllers/lights_controller_test.rb` ans Ende der Klasse:

```ruby
  test "show renders a zone card with id and reflects persisted zone_states" do
    light = Light.create!(name: "Up", key: "UP9", zones: %w[bottomLightToggle rippleLightToggle])
    LightState.record_zone_state("UP9", "rippleLightToggle", true)
    get light_url(key: "UP9")
    assert_response :success
    assert_select "#zone_rippleLightToggle"
    assert_select "#zone_rippleLightToggle.ld-zone:not(.off)"
    assert_select "#zone_bottomLightToggle.ld-zone.off"
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bin/rails test test/controllers/lights_controller_test.rb -n "/show renders a zone card/"`
Expected: FAIL — kein Element mit `id=zone_rippleLightToggle` (IDs gibt es noch nicht).

- [ ] **Step 3: `_power.html.erb` anlegen**

```erb
<%# locals: light (Light), row (LightRow) %>
<div id="light_power" class="ld-hero<%= ' is-off' unless row.on? %>">
  <div class="ld-lamp plush-<%= light.plush_type %><%= ' off' unless row.on? %>"></div>
  <div class="ld-power">
    <%= button_to "An", light_command_path(light_key: light.key),
          params: { command: "turn", on: "true" },
          class: "ld-pill#{' on' if row.on?}", form_class: "ld-inline-form" %>
    <%= button_to "Aus", light_command_path(light_key: light.key),
          params: { command: "turn", on: "false" },
          class: "ld-pill#{' on' unless row.on?}", form_class: "ld-inline-form" %>
  </div>
</div>
```

- [ ] **Step 4: `_zone.html.erb` anlegen**

```erb
<%# locals: zone (LightRow::Zone), light_key (String) %>
<div id="zone_<%= zone.key %>"
     class="ld-zone<%= ' main' if zone.role == 'main' %><%= ' off' unless zone.on %>"
     data-zone-key="<%= zone.key %>" data-zone-role="<%= zone.role %>">
  <span class="ld-zone-dot"></span>
  <span class="ld-zone-nm"><%= zone.label %></span>
  <% if zone.role == "main" %><span class="ld-zone-badge">Haupt</span><% end %>
  <span class="ld-zone-spacer"></span>
  <%= button_to "".html_safe, light_command_path(light_key: light_key),
        params: { command: "zone", zone: zone.key, on: (!zone.on).to_s },
        class: "ld-zone-toggle#{' on' if zone.on}", form_class: "ld-inline-form",
        "aria-label": "#{zone.label} an/aus" %>
</div>
```

- [ ] **Step 5: `_toast.html.erb` anlegen**

```erb
<%# locals: message (String|nil), undo (Hash|nil) %>
<div id="light_toast" class="ld-toast" data-controller="toast"<%= " hidden".html_safe unless message %>>
  <% if message %>
    <span><%= message %></span>
    <%= button_to "Rückgängig", light_command_path(light_key: undo[:light_key]),
          params: { command: "zone_undo", victim: undo[:victim], added: undo[:added] },
          class: "ld-toast-undo", form_class: "ld-inline-form" %>
  <% end %>
</div>
```

- [ ] **Step 6: `show.html.erb` auf Partials umstellen**

Hero-Block (Z. 14-20) ersetzen durch:

```erb
  <%= render "lights/power", light: @light, row: @row %>
```

Den Zonen-`each` (Z. 42-55) ersetzen durch:

```erb
      <% @row.zones.each do |zone| %>
        <%= render "lights/zone", zone: zone, light_key: @light.key %>
      <% end %>
```

Den Toast-Block (Z. 123-126) ersetzen durch:

```erb
  <%= render "lights/toast", message: nil, undo: nil %>
```

> Hinweis: `data-light-detail-target="lamp"` entfällt mit dem Hero-Umbau (Reconcile kommt ab Task 7 per Stream). Power-Pills sind jetzt `button_to`.

- [ ] **Step 7: CSS — Inline-Forms dürfen Layout nicht brechen**

In der Lampen-Detail-Stylesheet-Datei (suchen: `grep -rl "ld-zone-toggle" app/assets`) ergänzen:

```css
.ld-inline-form { display: contents; }
```

- [ ] **Step 8: Run tests, verify pass**

Run: `bin/rails test test/controllers/lights_controller_test.rb`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add app/views/lights/ test/controllers/lights_controller_test.rb app/assets
git commit -m "refactor(lights): extract power/zone/toast partials with stable DOM ids"
```

---

### Task 3: Zonen-Command antwortet mit Turbo Stream

Der Klick auf den Zonen-Toggle (jetzt `button_to`) sendet einen Turbo-Stream-Accept; der Controller antwortet mit Replace der Karte.

**Files:**
- Modify: `app/controllers/light_switches_controller.rb` (`when "zone"`-Branch + private Helper)
- Test: `test/controllers/light_switches_controller_test.rb`

**Interfaces:**
- Consumes: Partial `lights/zone` (Task 2), `LightRow#zones -> [Zone]` (existiert, `app/models/light_row.rb:38`).
- Produces: private `respond_zone(light, *zone_keys, toast: nil)` rendert `turbo_stream`-Replace pro `zone_key` (+ optional Toast). Von Task 4/5 genutzt.

- [ ] **Step 1: Failing test — Zonen-Command liefert Turbo-Stream-Replace**

In `test/controllers/light_switches_controller_test.rb`:

```ruby
  test "zone command responds with a turbo stream replacing the card" do
    Light.create!(name: "Up", key: "UP2", zones: %w[bottomLightToggle rippleLightToggle])
    GoveeCommander.stub(:set_zone, ->(*, **) {}) do
      post light_command_url(light_key: "UP2"),
           params: { command: "zone", zone: "rippleLightToggle", on: "true" },
           as: :turbo_stream
    end
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", @response.media_type
    assert_select "turbo-stream[action=replace][target=zone_rippleLightToggle]"
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb -n "/responds with a turbo stream/"`
Expected: FAIL — Antwort ist `head :accepted`, kein turbo-stream.

- [ ] **Step 3: Branch auf `respond_zone` umstellen**

`when "zone"`-Branch:

```ruby
    when "zone"
      return head :unprocessable_entity unless light.zones.include?(params[:zone])
      on = cast_bool(params[:on])
      LightState.record_zone_state(light.key, params[:zone], on)
      GoveeCommander.set_zone(light, zone: params[:zone], on: on, **opts)
      return respond_zone(light, params[:zone])
```

Private Helper ergänzen (am Ende der Klasse, vor `end`):

```ruby
  def respond_zone(light, *zone_keys, toast: nil)
    zones = LightRow.new(light: light, state: LightState.find_by(light_key: light.key)).zones.index_by(&:key)
    streams = zone_keys.map { |k|
      turbo_stream.replace("zone_#{k}", partial: "lights/zone", locals: { zone: zones[k], light_key: light.key })
    }
    streams << turbo_stream.replace("light_toast", partial: "lights/toast",
      locals: { message: toast&.dig(:message), undo: toast&.dig(:undo) }) if toast
    render turbo_stream: streams
  end
```

Oben in der Datei sicherstellen, dass `LightRow` geladen ist (Autoload greift; kein `require` nötig).

- [ ] **Step 4: Run test, verify it passes**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb`
Expected: PASS (die alte "zone command toggles a valid zone" bleibt grün, da sie ohne `as: :turbo_stream` postet → `respond_zone` rendert trotzdem turbo_stream mit Status 200; falls sie auf `:accepted` prüft, anpassen).

> Falls die bestehende "zone command toggles a valid zone" auf `assert_response :accepted` prüft: auf `assert_response :success` ändern.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/light_switches_controller.rb test/controllers/light_switches_controller_test.rb
git commit -m "feat(lights): zone command responds with turbo_stream card replace"
```

---

### Task 4: Server-getriebenes max-2-auto-off + Toast

Die Eviction-Logik wandert komplett in den Controller (Opfer = andere an-Seite, Entscheidung B). Bei Eviction werden beide Karten + der Toast als Stream geliefert.

**Files:**
- Modify: `app/controllers/light_switches_controller.rb` (`when "zone"`-Branch + Helper)
- Test: `test/controllers/light_switches_controller_test.rb`

**Interfaces:**
- Consumes: `Light::ZONE_META`, `Light#max_active_zones -> Integer|nil`, `respond_zone` (Task 3).
- Produces: private `evict_for(light, zone) -> String|nil` (Opfer-Key oder nil).

> **Wichtig — Semantik (aus dem alten JS abgeleitet):** Das Limit `max_active_zones`
> kommt aus dem `sku` (`Light::MAX_ACTIVE_ZONES["H60B0"] == 2`), ist **kein**
> Spalten-Attribut. Gegen das Limit zählen **alle** an-Zonen (inkl. Haupt/Leselicht),
> nicht nur Seiten. Evictet wird aber nur eine **Seiten**-Zone. Bei H60B0 (Leselicht +
> Welle + Seite, Limit 2) heißt das: Leselicht an + eine Seite an = 2 → das Einschalten
> der zweiten Seite überschreitet und evictet die andere an-Seite.

- [ ] **Step 1: Failing test — Eviction schaltet Opfer aus und rendert Toast**

```ruby
  test "turning on a side zone over the limit evicts an on side and shows a toast" do
    light = Light.create!(name: "Up", key: "UP3", sku: "H60B0",
                          zones: %w[bottomLightToggle rippleLightToggle sideLightToggle])
    LightState.record_zone_state("UP3", "bottomLightToggle", true) # Haupt an
    LightState.record_zone_state("UP3", "rippleLightToggle", true) # eine Seite an -> 2 an == Limit
    calls = []
    GoveeCommander.stub(:set_zone, ->(l, zone:, on:, **) { calls << [ zone, on ] }) do
      post light_command_url(light_key: "UP3"),
           params: { command: "zone", zone: "sideLightToggle", on: "true" }, as: :turbo_stream
    end
    assert_response :success
    state = LightState.find_by(light_key: "UP3")
    assert_equal false, state.zone_states["rippleLightToggle"], "old side switched off"
    assert_equal true,  state.zone_states["sideLightToggle"],   "new side switched on"
    assert_equal true,  state.zone_states["bottomLightToggle"], "main untouched"
    assert_includes calls, [ "rippleLightToggle", false ]
    assert_includes calls, [ "sideLightToggle", true ]
    assert_select "turbo-stream[action=replace][target=zone_rippleLightToggle]"
    assert_select "turbo-stream[action=replace][target=zone_sideLightToggle]"
    assert_select "turbo-stream[action=replace][target=light_toast]"
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb -n "/evicts the other side/"`
Expected: FAIL — Opfer wird nicht ausgeschaltet, kein Toast-Stream.

- [ ] **Step 3: Eviction-Logik einbauen**

`when "zone"`-Branch erweitern:

```ruby
    when "zone"
      return head :unprocessable_entity unless light.zones.include?(params[:zone])
      on = cast_bool(params[:on])
      evicted = on ? evict_for(light, params[:zone]) : nil
      if evicted
        LightState.record_zone_state(light.key, evicted, false)
        GoveeCommander.set_zone(light, zone: evicted, on: false, **opts)
      end
      LightState.record_zone_state(light.key, params[:zone], on)
      GoveeCommander.set_zone(light, zone: params[:zone], on: on, **opts)
      if evicted
        toast = { message: "#{Light::ZONE_META.dig(evicted, :label)} ausgeschaltet · max. #{light.max_active_zones} Zonen",
                  undo: { light_key: light.key, victim: evicted, added: params[:zone] } }
        return respond_zone(light, params[:zone], evicted, toast: toast)
      end
      return respond_zone(light, params[:zone])
```

Privaten Helper ergänzen (zählt **alle** an-Zonen gegen das Limit, evictet eine an-Seite):

```ruby
  def evict_for(light, zone)
    return nil unless Light::ZONE_META.dig(zone, :role) == "side"
    max = light.max_active_zones.to_i
    return nil unless max.positive?
    bits = LightState.find_by(light_key: light.key)&.zone_states || {}
    on_zones = light.zones.select { |z| bits[z] } - [ zone ]
    return nil if on_zones.size < max
    on_zones.find { |z| Light::ZONE_META.dig(z, :role) == "side" }
  end
```

> Hash-Key-Typen (verifiziert in `app/models/light.rb:14`): `ZONE_META` hat **String**-
> Außenkeys (`"rippleLightToggle"`) und **Symbol**-Innenkeys (`:label`, `:role`) →
> `dig(zone, :role)` / `dig(evicted, :label)` ist korrekt.

- [ ] **Step 4: Run tests, verify pass**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/light_switches_controller.rb test/controllers/light_switches_controller_test.rb
git commit -m "feat(lights): server-driven max-zone auto-off with toast"
```

---

### Task 5: `zone_undo`-Command

Macht die Eviction rückgängig: Opfer wieder an, neue Zone aus, Toast leeren.

**Files:**
- Modify: `app/controllers/light_switches_controller.rb` (`case`-Block: neuer `when "zone_undo"`)
- Test: `test/controllers/light_switches_controller_test.rb`

**Interfaces:**
- Consumes: `respond_zone` mit `toast: { message: nil, undo: nil }` zum Leeren.
- Produces: keine neuen.

- [ ] **Step 1: Failing test — Undo kehrt Eviction um und leert Toast**

```ruby
  test "zone_undo restores the victim, turns off the added zone and clears the toast" do
    light = Light.create!(name: "Up", key: "UP4", zones: %w[rippleLightToggle sideLightToggle])
    LightState.record_zone_state("UP4", "sideLightToggle", true)
    calls = []
    GoveeCommander.stub(:set_zone, ->(l, zone:, on:, **) { calls << [ zone, on ] }) do
      post light_command_url(light_key: "UP4"),
           params: { command: "zone_undo", victim: "rippleLightToggle", added: "sideLightToggle" },
           as: :turbo_stream
    end
    assert_response :success
    state = LightState.find_by(light_key: "UP4")
    assert_equal true,  state.zone_states["rippleLightToggle"]
    assert_equal false, state.zone_states["sideLightToggle"]
    assert_includes calls, [ "rippleLightToggle", true ]
    assert_includes calls, [ "sideLightToggle", false ]
    assert_select "turbo-stream[action=replace][target=light_toast]"
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb -n "/zone_undo restores/"`
Expected: FAIL — `when "zone_undo"` existiert nicht → 422.

- [ ] **Step 3: `when "zone_undo"` ergänzen**

Im `case params[:command]` vor dem `else` einfügen:

```ruby
    when "zone_undo"
      victim = params[:victim]; added = params[:added]
      return head :unprocessable_entity unless light.zones.include?(victim) && light.zones.include?(added)
      LightState.record_zone_state(light.key, victim, true)
      GoveeCommander.set_zone(light, zone: victim, on: true, **opts)
      LightState.record_zone_state(light.key, added, false)
      GoveeCommander.set_zone(light, zone: added, on: false, **opts)
      return respond_zone(light, victim, added, toast: { message: nil, undo: nil })
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/light_switches_controller.rb test/controllers/light_switches_controller_test.rb
git commit -m "feat(lights): zone_undo command reverses auto-off and clears toast"
```

---

### Task 6: Power-Command antwortet mit Turbo Stream (optimistisch)

Power-Pills sind seit Task 2 `button_to`. Jetzt antwortet `turn` mit Replace von `light_power`; der `on`-Zustand wird optimistisch persistiert (Device-Echo korrigiert später via Broadcast).

**Files:**
- Modify: `app/controllers/light_switches_controller.rb` (`when "turn"`-Branch)
- Test: `test/controllers/light_switches_controller_test.rb`

**Interfaces:**
- Consumes: Partial `lights/power` (Task 2), `LightState.record_state(light_key, attrs) -> Boolean` (existiert, `app/models/light_state.rb:12`).
- Produces: private `respond_power(light)`.

- [ ] **Step 1: Failing test — turn persistiert on optimistisch und liefert power-Stream**

```ruby
  test "turn optimistically persists on and replaces the power partial" do
    @light = Light.create!(name: "Lampe", key: "S2", zones: [])
    GoveeCommander.stub(:turn, ->(*, **) {}) do
      post light_command_url(light_key: "S2"),
           params: { command: "turn", on: "true" }, as: :turbo_stream
    end
    assert_response :success
    assert_equal true, LightState.find_by(light_key: "S2").on
    assert_select "turbo-stream[action=replace][target=light_power]"
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb -n "/optimistically persists on/"`
Expected: FAIL — `on` nicht gesetzt, kein power-Stream.

- [ ] **Step 3: `when "turn"` umstellen**

```ruby
    when "turn"
      on = cast_bool(params[:on])
      if light.zone_lamp?
        GoveeCommander.set_zone(light, zone: "powerSwitch", on: on, **opts)
      else
        GoveeCommander.turn(light, on: on, **opts)
      end
      LightState.record_state(light.key, on: on)
      return respond_power(light)
```

Privaten Helper ergänzen:

```ruby
  def respond_power(light)
    row = LightRow.new(light: light, state: LightState.find_by(light_key: light.key))
    render turbo_stream: turbo_stream.replace("light_power", partial: "lights/power", locals: { light: light, row: row })
  end
```

> Die bestehenden Tests "turn calls GoveeCommander and responds 202", "turn routes a zone lamp through powerSwitch", "turn still uses the light command for a simple lamp" prüfen `assert_response :accepted`. Auf `assert_response :success` ändern (Antwort ist jetzt turbo_stream 200).

- [ ] **Step 4: Run tests, verify pass**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb`
Expected: PASS (mit angepassten Status-Assertions).

- [ ] **Step 5: Commit**

```bash
git add app/controllers/light_switches_controller.rb test/controllers/light_switches_controller_test.rb
git commit -m "feat(lights): turn command optimistically persists on + replaces power partial"
```

---

### Task 7: Per-Lampe-Turbo-Stream — Subscription + Collector-Broadcast

Externe Änderungen (Power) sollen offene Detailseiten live aktualisieren. Die Seite abonniert `light_<key>`; `GoveeStatusHandler` broadcastet das `power`-Partial dorthin — zusätzlich zum bestehenden `"dashboard"`-Broadcast.

**Files:**
- Modify: `app/views/lights/show.html.erb` (Subscription-Tag oben einfügen)
- Modify: `lib/govee_status_handler.rb` (`broadcast`-Methode erweitern)
- Test: `test/govee_status_handler_test.rb`

**Interfaces:**
- Consumes: `Turbo::StreamsChannel.broadcast_replace_to(stream, target:, partial:, locals:)`, Partial `lights/power`, `LightRow`, `Light.find_by(key:)`.
- Produces: Stream-Name-Konvention `"light_#{key}"`, Target `light_power`.

- [ ] **Step 1: Subscription in show.html.erb**

Direkt nach der öffnenden `<div class="ld" ...>` (nach Z. 7) einfügen:

```erb
  <%= turbo_stream_from "light_#{@light.key}" %>
```

- [ ] **Step 2: Failing test — Status-Handler broadcastet power-Stream**

In `test/govee_status_handler_test.rb` (Pattern der bestehenden Tests übernehmen) ergänzen:

```ruby
  test "broadcasts a turbo stream replacing the power partial for the light" do
    Light.create!(name: "Lampe", key: "BCAST1", zones: [])
    handler = GoveeStatusHandler.new(logger: Logger.new(IO::NULL))
    streams = []
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(stream, **kw) { streams << [ stream, kw[:target] ] }) do
      handler.handle("gv2mqtt/light/BCAST1/state", %({"state":"ON","brightness":50}))
    end
    assert_includes streams, [ "light_BCAST1", "light_power" ]
  end
```

- [ ] **Step 3: Run test, verify it fails**

Run: `bin/rails test test/govee_status_handler_test.rb -n "/turbo stream replacing the power/"`
Expected: FAIL — kein `broadcast_replace_to`-Aufruf.

- [ ] **Step 4: Collector-Broadcast ergänzen**

In `lib/govee_status_handler.rb` am Ende von `handle_state` (nach dem bestehenden `broadcast(key, attrs)`) bzw. in einer neuen privaten Methode ergänzen:

```ruby
  def broadcast_turbo(key)
    light = Light.find_by(key: key)
    return unless light
    row = LightRow.new(light: light, state: LightState.find_by(light_key: key))
    Turbo::StreamsChannel.broadcast_replace_to("light_#{key}",
      target: "light_power", partial: "lights/power", locals: { light: light, row: row })
  rescue => e
    @logger.warn("GoveeStatusHandler: turbo broadcast failed: #{e.message}")
  end
```

Und in `handle_state` aufrufen:

```ruby
  def handle_state(topic, payload)
    key   = topic.split("/")[2]
    data  = JSON.parse(payload)
    attrs = parse_state(data).merge(last_seen_at: Time.current)
    LightState.record_state(key, attrs)
    broadcast(key, attrs)
    broadcast_turbo(key)
  rescue JSON::ParserError => e
    @logger.warn("GoveeStatusHandler: invalid JSON on #{topic}: #{e.message}")
  end
```

- [ ] **Step 5: Run tests, verify pass**

Run: `bin/rails test test/govee_status_handler_test.rb`
Expected: PASS (bestehende `"dashboard"`-Broadcast-Tests bleiben grün).

- [ ] **Step 6: Commit**

```bash
git add app/views/lights/show.html.erb lib/govee_status_handler.rb test/govee_status_handler_test.rb
git commit -m "feat(lights): per-light turbo stream for live power reconcile"
```

---

### Task 8: `light_detail_controller.js` abspecken + `toast_controller.js`

Zonen-, Toast-, Undo-, `send()`-Reconcile- und `onBroadcast()`-Logik aus dem Stimulus-Controller entfernen. Übrig: Tabs + Slider (Helligkeit, Farbtemperatur) + Color-Wheel als debounced fire-and-forget-POST. Neuer winziger Toast-Timer.

**Files:**
- Modify: `app/javascript/controllers/light_detail_controller.js` (komplett ersetzen)
- Create: `app/javascript/controllers/toast_controller.js`
- Modify: `app/controllers/light_switches_controller.rb` (Slider-Befehle → `head :no_content`)
- Modify: `app/views/lights/show.html.erb` (entferne `data-...-target="lamp"`, falls noch vorhanden; Slider behalten ihre `data-action`)
- Test: manuell (System) + `test/controllers/light_switches_controller_test.rb` für `:no_content`

**Interfaces:**
- Consumes: bestehende `data-action="light-detail#brightness|temp|swatch|wheel|tab"` aus `show.html.erb`.
- Produces: Stimulus-Controller `light-detail` (Tabs+Slider) und `toast` (Timer).

- [ ] **Step 1: Slider-Befehle auf `:no_content` (failing test)**

In `test/controllers/light_switches_controller_test.rb` die bestehenden Tests "brightness forwards the integer value" und "effect forwards the scene name" und "mood ..." auf den neuen Status anpassen; zusätzlich neuer Test:

```ruby
  test "brightness responds 204 no_content for fire-and-forget" do
    @light = Light.create!(name: "L", key: "S3", zones: [])
    GoveeCommander.stub(:set_brightness, ->(*, **) {}) do
      post light_command_url(light_key: "S3"), params: { command: "brightness", value: "42" }
    end
    assert_response :no_content
  end
```

In den bestehenden Tests `assert_response :accepted` → `assert_response :no_content` ändern für: brightness, effect, mood, color, color_temp (alle fire-and-forget-Befehle).

- [ ] **Step 2: Run test, verify it fails**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb -n "/204 no_content/"`
Expected: FAIL — Antwort ist `:accepted`.

- [ ] **Step 3: Controller — fire-and-forget-Endung auf `head :no_content`**

In `app/controllers/light_switches_controller.rb` die letzte Zeile des `create` (`head :accepted`) auf `head :no_content` ändern. Sicherstellen, dass nur `turn`/`zone`/`zone_undo`/`mood`-422 eigene `return`s haben und alle Slider-Befehle (`brightness`, `color`, `color_temp`, `effect`) durch zum finalen `head :no_content` fallen. `mood` (erfolgreich) fällt ebenfalls durch zu `:no_content`.

- [ ] **Step 4: `light_detail_controller.js` ersetzen**

Kompletten Inhalt ersetzen durch:

```javascript
// Connects to data-controller="light-detail". Slim: tab switching + debounced
// fire-and-forget sliders/wheel. Zone/power/toast state is server-rendered via
// Turbo Streams (see lights/_zone, _power, _toast partials).
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { key: String, tab: String }
  static targets = ["panel"]

  connect() { this.showTab(this.tabValue || "white") }

  tab(event) { this.showTab(event.params.tab) }

  showTab(name) {
    this.tabValue = name
    this.panelTargets.forEach((p) => { p.hidden = p.dataset.tab !== name })
    this.element.querySelectorAll(".ld-tab").forEach((b) => {
      b.classList.toggle("active", b.dataset.lightDetailTabParam === name)
    })
  }

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

  debounce(fn) { clearTimeout(this._d); this._d = setTimeout(fn, 250) }

  send(body) {
    fetch(`/lights/${this.keyValue}/command`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      },
      body: new URLSearchParams(body).toString(),
    })
  }
}
```

> Anmerkung: `static targets = ["temp"]` wird in `temp()` via `hasTempTarget` genutzt — `temp` zur Target-Liste hinzufügen: `static targets = ["panel", "temp"]`.

- [ ] **Step 5: `toast_controller.js` anlegen**

```javascript
// Connects to data-controller="toast". Auto-dismisses the toast after 5s by
// hiding it. The undo button inside is a server-driven button_to form.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    if (this.element.hidden) return
    this._t = setTimeout(() => { this.element.hidden = true }, 5000)
  }

  disconnect() { clearTimeout(this._t) }
}
```

- [ ] **Step 6: View-Cleanup**

In `show.html.erb` sicherstellen: keine Referenzen mehr auf entfernte Targets/Actions (`#on`, `#off`, `#zone`, `#undoZone`, `target="lamp|toast|toastMsg|error|brightness|wheel"` außer `brightness`/`temp` Slidern und `panel`). Das `data-light-detail-max-zones-value` und `error`/`toast`-Targets am Wurzel-`div` entfernen (Z. 4-7 sowie der alte `ld-error`-Div Z. 128). Power/Zonen/Toast kommen jetzt aus Partials.

- [ ] **Step 7: Run tests + Asset-Check**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb`
Expected: PASS.
Run: `bin/rails test` (Gesamtsuite, Coverage-Gate)
Expected: PASS, Coverage ≥ line 70 / branch 71.

- [ ] **Step 8: Commit**

```bash
git add app/javascript/controllers/ app/controllers/light_switches_controller.rb app/views/lights/show.html.erb test/controllers/light_switches_controller_test.rb
git commit -m "refactor(lights): slim light-detail JS to tabs+sliders, add toast timer, no_content for fire-and-forget"
```

---

### Task 9: Manuelle Verifikation am echten Stack + Aufräumen

Server-driven Turbo-Stream-Flows lassen sich nur teilweise per Unit-Test absichern; ein realer Durchlauf bestätigt den Round-Trip (Command → Stream → DOM) und den Reload-Fix.

**Files:**
- Keine Code-Änderung erwartet; ggf. kleine Fixes aus Beobachtung.

- [ ] **Step 1: Dev-Stack starten**

Run: `bin/dev` (oder die im Projekt übliche Startroutine; Collector muss laufen für Reconcile). Sicherstellen, dass nur eine SQLite-schreibende Instanz läuft (siehe Memory `govee2mqtt-migration-followup`: `bin/ci` braucht gestoppten Dev-Stack).

- [ ] **Step 2: Detailseite öffnen und Zonen togglen**

`http://localhost:5000/lights/14ABDB4844064B60` öffnen. Eine Zone an/aus schalten → Karte schaltet via Turbo Stream um. **Reload** → Zustand bleibt erhalten (Bug behoben).

- [ ] **Step 3: max-2-auto-off + Undo prüfen**

Zwei Seiten-Zonen aktivieren bis Limit; weitere Seite an → andere geht aus, Toast erscheint mit „Rückgängig". Undo klicken → Zustand kehrt um, Toast verschwindet. Toast verschwindet sonst nach 5s von selbst.

- [ ] **Step 4: Power + Slider**

An/Aus togglen (Power-Pill via Turbo Stream). Helligkeit/Farbtemperatur-Slider ziehen → Lampe reagiert (fire-and-forget, kein UI-Sprung).

- [ ] **Step 5: Tote Referenzen suchen**

Run: `grep -rn "onBroadcast\|undoZone\|maxZones\|toastMsg\|light-detail-target=\"lamp\"\|DashboardChannel" app/ | grep -i light`
Expected: keine Treffer im Detail-Widget mehr (DashboardChannel-Nutzung der Switches-Seite darf bestehen bleiben).

- [ ] **Step 6: Final commit (falls Fixes)**

```bash
git add -A
git commit -m "chore(lights): finalize turbo+hotwire lamp widget"
```

---

## Self-Review

**Spec-Coverage:**
- Partials als einzige Render-Quelle → Task 2. ✓
- Commands → Turbo Stream (zone/power) → Task 3, 6. ✓
- Server-driven max-2 + Toast + Undo (Opfer = andere Seite, B) → Task 4, 5. ✓
- Bug-Fix `record_zone_state` im Command-Pfad → Task 1. ✓
- Per-Lampe-Reconcile via `broadcast_replace_to`, `dashboard` bleibt → Task 7. ✓
- Reconcile-Granularität eng (nur Power + Zonen, keine Slider) → Task 7 broadcastet nur `light_power`; Zonen-Reconcile extern nicht nötig (govee2mqtt liefert keinen Zonen-State) → bewusst ausgelassen. ✓
- Schlankes JS (Tabs+Slider+Wheel) + Toast-Timer → Task 8. ✓
- Keine Migration → bestätigt (nur bestehende Spalten/Methoden). ✓
- TDD inkl. Reload-Regression → Task 2 Step 1. ✓

**Placeholder-Scan:** Keine TBD/TODO; jeder Code-Step zeigt vollständigen Code. ✓

**Typ-Konsistenz:** `respond_zone(light, *zone_keys, toast:)` einheitlich in Task 3/4/5. `LightRow::Zone` Felder `key/label/role/on` wie `app/models/light_row.rb:3`. `Light::ZONE_META` verifiziert: String-Außenkeys, Symbol-Innenkeys → `dig(zone, :role)`/`dig(evicted, :label)`. `max_active_zones` ist aus `sku` abgeleitet (kein Spalten-Attribut) → Tests setzen `sku: "H60B0"`. Partial-Locals-Verträge in Task 2 definiert und in 3/6/7 unverändert genutzt. ✓

**Geprüfte Annahmen (erledigt):** `ZONE_META`-Key-Typen (String außen / Symbol innen, `light.rb:14`); `max_active_zones` aus `sku` (`light.rb:43`, H60B0→2); `sku`/`zones` sind Spalten (`schema.rb:49,53`); Limit zählt alle an-Zonen, evictet nur Seiten (aus `light_detail_controller.js` `onZoneCards()`).
