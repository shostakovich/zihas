# Govee Lampen-UI — Design

**Datum:** 2026-06-26
**Status:** Entwurf (brainstormed, freigegeben)
**Branch:** `feature/govee-lights`
**Verwandt:** [2026-06-24-govee-lights-design.md](2026-06-24-govee-lights-design.md), [2026-06-26-govee2mqtt-migration-design.md](2026-06-26-govee2mqtt-migration-design.md)

## Visuelle Referenz (Brainstorming-Mockups)

Detailliertere Layout-/Interaktions-Vorlage als dieser Text — beim Planen als Grounding nutzen.
HTML im Ordner [`2026-06-26-govee-lamp-ui-mockups/`](2026-06-26-govee-lamp-ui-mockups/) (im Browser öffnen):

- [`layout.html`](2026-06-26-govee-lamp-ui-mockups/layout.html) — Seitenarchitektur (Hero + Tabs, gewählt: B).
- [`uplighter-v2.html`](2026-06-26-govee-lamp-ui-mockups/uplighter-v2.html) — Zonen-Lampe: Hauptzonen-Schutz,
  „max. 2"-Automatik mit Toast (finale Variante; der frühere Nachfrage-Dialog wurde verworfen).
- [`colorpicker.html`](2026-06-26-govee-lamp-ui-mockups/colorpicker.html) — Picker-Stile (gewählt: C =
  Swatches + „⊕"-Rad) und der Weiß-Tab (Wärme-Regler + Presets). Reihenfolge final: **Weiß vor Farbe**.
- [`scenes-and-tile.html`](2026-06-26-govee-lamp-ui-mockups/scenes-and-tile.html) — Szenen-Tab und die
  Lampen-Kachel im Schalten-Tab.

## Ziel

Die heutige Lampensteuerung im „Schalten"-Tab ist roh: ein nackter `range`-Slider,
der native `<input type="color">`-Picker, keine Weißlicht-Steuerung, keine Szenen,
und keine Behandlung mehrteiliger (Zonen-)Lampen. Dieses Design ersetzt das durch
eine **Lampen-Detailseite** mit Back-Navigation und eine aufgeräumte Listen-Kachel.

Erfüllte Wünsche: An/Aus, schickerer Helligkeits-Slider, besserer Farbpicker,
reiner Weißlicht-Modus, Szenen-Vorauswahl, Plüsch-Charakter pro Lampe.

## Hardware-Realität (die 4 vorhandenen Lampen)

| Lampe | SKU | Steuerbare Teile | Besonderheit |
|---|---|---|---|
| Uplighter Floor Lamp | H60B0 | 3 Zonen: Welle (oben, RGB) · Seite (mitte) · Unten/Leselicht (Haupt) | **nur 2 Zonen gleichzeitig**; 6 Govee-Kombi-Modi |
| Floor Lamp 2 | H607C | 2 Zonen (Säule + Sockel), RGBICWW | meist nur Hauptzone relevant |
| Floor Lamp „Krabbe" | H607C | wie Floor Lamp 2 | gleiche SKU wie oben |
| Wall Sconce | (tbd) | RGBICW, Wall-Washing | wird i.d.R. gemeinsam gefahren, nicht einzeln |
| Decken-/Ceiling Light | (tbd) | **121 Mikro-Segmente**, RGBIC+WW | nur über **Szenen** sinnvoll steuerbar |

**Konsequenz:** „Mehrteilig" heißt **Zonen innerhalb eines Geräts** (meist 1–3), nicht mehrere
physische Geräte. Geräte mit sehr vielen Segmenten (Decke, 121) kollabieren auf
„ganze Lampe + Szenen" — keine 121 Einzel-Picker.

## Was govee2mqtt liefert (verankert im Quellcode)

Alles Folgende funktioniert mit **api-key + LAN** (kein Account-Login nötig; Account-Creds
sind wegen 454-Rate-Limit deaktiviert — irrelevant für diese Features):

- **An/Aus, Helligkeit, RGB-Farbe, Farbtemperatur**: Command-Topic `gv2mqtt/light/{id}/command`,
  HA-JSON (`{"state":"ON","brightness":0-100,"color":{r,g,b},"color_temp":<mired>}`).
  `state` ist in jedem Payload Pflicht.
- **Szenen / DIY / Musik-Modi**: als HA-`select`-Entity exponiert; aktivierbar via
  `gv2mqtt/{id}/set-mode-scene` (Payload = Szenenname als String) **oder** bequem über das
  Command-Topic mit `{"state":"ON","effect":"<Szenenname>"}`. Liste kommt aus der Platform-API
  (api-key) + einem no-auth SKU-Endpoint. Musik-Modi heißen `"Music: …"`.
- **Segmente** (z.B. Welle/Seite/Unten, oder Säule/Sockel): jedes Segment erscheint als
  eigene HA-Light-Entity; Steuerung über `gv2mqtt/light/{id}/command/{seg#}` (0-basiert),
  Payload wie beim Haupt-Command. Capability: `segmentedColorRgb`.
- **Farbtemperatur**: Gerät meldet min/max Kelvin; Command in **Mired** (`color_temp`).

Hinweis zur Uplighter: Ob die 3 „Zonen" als `segmentedColorRgb`-Segmente oder als
Govee-Kombi-Modi/Szenen im Discovery erscheinen, ist **empirisch am laufenden Bridge zu
verifizieren**. Das Design verbaut keinen der beiden Fälle.

## UI-Architektur

### Schalten-Tab: Lampen-Liste

Eine Kachel pro Lampe (ersetzt `_light_card`):

- **Plüsch-Lampe** links (Zustand: an = leuchtend, in aktueller Lichtfarbe getönt; aus = grau).
- **Name** + Zustandszeile (z.B. „An · Warmweiß · 60 %", „2 Zonen an · Welle + Leselicht", „Aus").
- **Chevron ›**.

Interaktion:
- **Plüsch-Lampe antippen** → direkt An/Aus (optimistisch, wie der heutige `sw-knob`).
- **Karte antippen** → Detailseite.

### Detailseite (eine Architektur, adaptiv)

Gemeinsam: Top-Bar mit **Back-Pfeil** + Lampenname; **Hero**-Karte oben.

**Variante A — einfache Lampe** (Floor Lamp 2, Wall Sconce, Decke):
- Hero: An/Aus + **Master-Helligkeit**-Slider.
- Tabs: **`Weiß · Farbe · Szenen`** — Default **Weiß**.

**Variante B — Zonen-Lampe** (Uplighter):
- Hero: nur An/Aus (kein Master-Slider — Helligkeit ist pro Zone).
- Tabs: **`Zonen · Szenen`** — Default **Zonen**.
- Tab „Zonen": eine Karte pro Zone mit eigenem Schalter, eigener Helligkeit, eigener Farbe.
  - **Hauptzone** (Uplighter: „Unten/Leselicht") visuell hervorgehoben + „Haupt"-Badge.
  - Pro-Zone-Farbe nutzt denselben Picker wie unten; RGB-fähige Zonen zeigen volle Palette.

Welche Variante greift, ergibt sich aus der **Zonen-Anzahl** der Lampe (1 → A, ≥2 → B),
plus einer Sonderregel für „viele Segmente" (Decke): wie A behandeln, Default-Tab `Szenen`.

### „Max. 2 Zonen"-Regel (Uplighter)

Hardware-Limit: höchstens 2 Zonen gleichzeitig an. Beim Einschalten einer 3. Zone:

1. Automatisch die **zuletzt aktivierte Nebenzone** ausschalten.
2. Die **Hauptzone (Leselicht) wird nie automatisch ausgeschaltet** — außer sie ist
   ohnehin schon aus.
3. Kurzer **Toast** („🌊 Welle ausgeschaltet · max. 2 Zonen") mit **„Rückgängig"**.

Kein Nachfrage-Dialog (verworfen zugunsten weniger Klicks).

### Picker

- **Helligkeit**: gefüllter Slider mit Warm-Gradient + runder Knopf (ersetzt nackten `range`).
- **Weiß-Tab** (Default): Wärme-Regler 2700 K → 6500 K (warm → kalt) als Gradient-Slider,
  plus 3 Schnell-Presets **„Gemütlich / Neutral / Arbeiten"**. Erfüllt „nur im weißen Licht bleiben".
- **Farbe-Tab**: **kuratierte Swatches** zum Ein-Tippen (Raster) + eine „⊕"-Kachel, die ein
  **HSV-Rad** fürs Feintuning öffnet.

### Szenen-Tab

- Oben **eigene „Stimmungen"** (Sonnenuntergang / Lesen / Kino / Party) — aus vorhandenen
  Befehlen (Farbe/Temperatur/Helligkeit) zusammengesetzte Presets, funktionieren auf jeder Lampe.
- Darunter **echte Govee-Szenen** des Geräts (scrollbares Raster, Gradient-Vorschau), aktiviert
  als `effect`-String. Für die 121-Segment-Decke der Hauptweg.

## Plüsch-Assets

- **Pro Lampentyp eine Figur**, modelliert nach den echten Lampen (Uplighter, Floor Lamp 2,
  Wall Sconce, Decke), je **an/aus**. Glow im „an"-Zustand **per CSS** in der aktuellen
  Lichtfarbe getönt (warmweiß → Amber, RGB → farbig), damit ein Asset jede Farbe trägt.
- **Generische Fallback-Lampe** (an/aus) für unbekannte/künftige Lampentypen.
- Zuordnung über **`lights.sku`** → bekannte SKU = passende Figur; unbekannt → Fallback.
- **Asset-Spec** (für externe Generierung): Stil konsistent zu `switch_plush_*.webp` /
  `nav_*_plush.webp`; Format webp, ~256×256, transparenter Hintergrund; je Motiv zwei Zustände
  (leuchtend/wach vs. dunkel/schläfrig).
- Optional: **Empty-State-Plüsch** (schläfriges Lämpchen) für „noch keine Lampen".

Asset-Dateinamen (Vorschlag): `lamp_<typ>_on.webp` / `lamp_<typ>_off.webp` mit
`<typ>` ∈ `uplighter, floorlamp, sconce, ceiling, generic`.

## Backend-Auswirkungen

1. **Zonen-Modell**: „Lampe hat 1..N Zonen". Segment-Entities aus dem gv2mqtt-Discovery
   einer physischen Lampe zuordnen/gruppieren (Haupt-Entity + Segment-Entities). Hauptzone
   markierbar. `last_activated`-Reihenfolge je Zone für die „max. 2"-Regel.
2. **Szenen-Liste einlesen**: gv2mqtt publiziert die Szenen als `select`-Entity im Discovery —
   `GoveeDiscoveryHandler` ignoriert das heute. Szenennamen pro Gerät erfassen und persistieren.
3. **Presets/Stimmungen**: Modell zum Speichern + Anwenden eigener Stimmungen (Sequenz aus
   Farbe/Temperatur/Helligkeit-Befehlen).
4. **`GoveeCommander`** erweitern um:
   - `effect` (Szene aktivieren),
   - Segment-Befehle (`gv2mqtt/light/{id}/command/{seg#}`).
5. **`LightSwitchesController`**: neue Commands `scene`/`effect` und `segment_*` zulassen.
6. **Status**: `GoveeStatusHandler` muss Segment-/Szenen-Zustände in den Broadcast aufnehmen,
   damit die UI Zonen + aktive Szene reflektiert.

## Scope / Reihenfolge (Vorschlag, in Plan zu verfeinern)

1. Detailseite + Listen-Kachel für **einfache Lampen** (An/Aus, schicker Helligkeits-Slider,
   Weiß-Tab, Farbe-Tab mit Swatches+Rad). Plüsch generisch + getönt.
2. **Szenen-Tab** (eigene Stimmungen zuerst, dann Govee-Szenen-Liste einlesen).
3. **Zonen-Lampen** (Uplighter): Zonen-Tab, „max. 2"-Regel, Hauptzonen-Schutz.
4. **Pro-Typ-Plüsch-Assets** (SKU-Map) ersetzen den generischen Platzhalter.

## Offene Punkte / empirisch zu klären

- Wie genau Uplighter-Zonen und Floor-Lamp-2-Zonen im gv2mqtt-Discovery erscheinen
  (Segmente vs. Modi) — am laufenden Bridge prüfen, bevor das Zonen-Modell finalisiert wird.
- SKUs von Wall Sconce + Decke ergänzen (für Plüsch-Map).
- Wie reichhaltig die Govee-Szenen-Liste je Gerät ist (Scroll/Filter nötig?).
