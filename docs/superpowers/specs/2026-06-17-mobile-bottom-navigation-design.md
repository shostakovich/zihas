# Mobile Bottom Navigation — Solar Liquid Glass Design

**Datum:** 2026-06-17  
**Status:** Design abgestimmt, bereit für Review/Planung

## Ziel

ZiWoAS bekommt auf Mobilgeräten eine neue, dauerhaft sichtbare Bottom-Navigation. Sie ersetzt dort die bisherige obere Navigation und bleibt am unteren Bildschirmrand fixiert. Desktop bleibt unverändert: Logo und bisherige Pill-Navigation im Header bleiben sichtbar.

Visuelle Richtung: **Frosted Tray / Solar Liquid Glass** mit warmem Gelb-Akzent, leichter Transparenz, Blur und generierten Plüsch-Icons im Stil der bestehenden ZiWoAS-Assets.

## Getroffene Entscheidungen

- Mobile Navigation erscheint **nur auf Mobil**; Desktop-Navigation bleibt wie bisher.
- Mobile Navigation **ersetzt** die obere Navigation auf Mobil, damit keine doppelte Navigation entsteht.
- Es bleiben alle fünf Ziele sichtbar:
  - Home (führt zum Dashboard)
  - Schalten
  - Berichte
  - Wetter
  - Sensoren
- Darstellung: **Icon + kurzer Labeltext** für alle fünf Punkte.
- Stil: Variante **C — Frosted Tray**, also eher ruhiges Glas-Panel mit Solar-Akzent.
- Icons: generierte Plüsch-Icons, zugeschnitten aus dem vom User gelieferten Bild.
- Navi-Icons in der Leiste bewusst kleiner, Labels nicht fett.

## Neue Assets

Die zugeschnittenen WebP-Dateien liegen unter:

- `app/assets/images/nav_dashboard_plush.webp`
- `app/assets/images/nav_switches_plush.webp`
- `app/assets/images/nav_reports_plush.webp`
- `app/assets/images/nav_weather_plush.webp`
- `app/assets/images/nav_sensors_plush.webp`

Hinweis: Die Freistellung wurde aus einem gemeinsamen Bild abgeleitet. Die aktuelle Version ist für helle/gläserne UI geeignet; bei späterem Bedarf können die Icons durch direkt transparent generierte Einzelbilder ersetzt werden.

## Architektur / Umsetzung

Empfohlener Ansatz: **bestehende Navigation im Layout erweitern und per CSS mobil zur Bottom-Bar umformen**.

Aktuell sitzt die Navigation in `app/views/layouts/application.html.erb`:

```erb
<header class="app-header">
  <%= link_to root_path, class: "app-brand" do %>
    <%= image_tag "logo.png", alt: "Ziwoas — Startseite", class: "app-logo", width: 172, height: 64 %>
  <% end %>
  <nav class="app-nav" aria-label="Hauptnavigation">
    ...
  </nav>
</header>
```

Für die Umsetzung soll die Link-Struktur um Icon-Bilder und Label-Spans erweitert werden. Desktop kann weiterhin die bestehende Pill-Navigation zeigen; auf Mobil wird dieselbe `app-nav` fix unten positioniert und als Tabbar gestylt.

## Produktionsnahe HTML-Vorlage

Diese Vorlage beschreibt die gewünschte Struktur für `app/views/layouts/application.html.erb`:

```erb
<nav class="app-nav" aria-label="Hauptnavigation">
  <%= link_to root_path, class: ["app-nav-link", ("active" if current_page?(root_path))] do %>
    <%= image_tag "nav_dashboard_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
    <span class="app-nav-label">Home</span>
  <% end %>

  <%= link_to switches_path, class: ["app-nav-link", ("active" if current_page?(switches_path))] do %>
    <%= image_tag "nav_switches_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
    <span class="app-nav-label">Schalten</span>
  <% end %>

  <%= link_to reports_path, class: ["app-nav-link", ("active" if current_page?(reports_path))] do %>
    <%= image_tag "nav_reports_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
    <span class="app-nav-label">Berichte</span>
  <% end %>

  <%= link_to weather_path, class: ["app-nav-link", ("active" if current_page?(weather_path))] do %>
    <%= image_tag "nav_weather_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
    <span class="app-nav-label">Wetter</span>
  <% end %>

  <%= link_to sensors_path, class: ["app-nav-link", ("active" if current_page?(sensors_path))] do %>
    <%= image_tag "nav_sensors_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
    <span class="app-nav-label">Sensoren</span>
  <% end %>
</nav>
```

Die Icons sind dekorativ; die zugänglichen Linknamen kommen aus dem sichtbaren Labeltext.

## CSS-Vorlage aus dem abgestimmten Mockup

Die final abgestimmten Mockup-Werte:

- Tabbar-Höhe: ca. `74px`
- Icons: `32px × 32px`
- Label: `font-weight: 500`, nicht fett
- Layout: 5 gleich breite Spalten
- Position: fix unten, mit Safe-Area-Unterstützung
- Glaslook: `backdrop-filter: blur(28px) saturate(1.65)` plus Fallback-Hintergrund

Produktionsnahe CSS-Skizze für `app/assets/stylesheets/application.css`:

```css
.app-nav-icon {
  display: none;
}

.app-nav-label {
  display: inline;
}

@media (max-width: 640px) {
  body {
    padding-bottom: calc(104px + env(safe-area-inset-bottom));
  }

  .app-header {
    justify-content: center;
    border-bottom: none;
    padding-bottom: 0;
  }

  .app-header .app-nav {
    position: fixed;
    left: 16px;
    right: 16px;
    bottom: calc(14px + env(safe-area-inset-bottom));
    z-index: 90;
    display: grid;
    grid-template-columns: repeat(5, minmax(0, 1fr));
    gap: 5px;
    min-height: 74px;
    padding: 7px;
    border-radius: 25px;
    background: linear-gradient(145deg, rgba(255, 255, 255, 0.36), rgba(255, 248, 219, 0.46));
    border: 1px solid rgba(255, 255, 255, 0.72);
    box-shadow:
      0 18px 44px rgba(15, 23, 42, 0.18),
      inset 0 1px 0 rgba(255, 255, 255, 0.9),
      inset 0 -1px 0 rgba(245, 159, 0, 0.16);
    backdrop-filter: blur(28px) saturate(1.65);
    -webkit-backdrop-filter: blur(28px) saturate(1.65);
  }

  .app-header .app-nav-link {
    min-width: 0;
    min-height: 60px;
    border-radius: 17px;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 2px;
    padding: 4px 3px;
    color: #6f5600;
    font-size: 9px;
    font-weight: 500;
    line-height: 1.1;
    letter-spacing: 0;
    text-align: center;
  }

  .app-header .app-nav-link.active {
    color: var(--text);
    background: linear-gradient(135deg, rgba(255, 224, 102, 0.78), rgba(255, 255, 255, 0.36));
    box-shadow:
      inset 0 1px 0 rgba(255, 255, 255, 0.88),
      0 8px 18px rgba(245, 159, 0, 0.13);
  }

  .app-nav-icon {
    display: block;
    width: 32px;
    height: 32px;
    object-fit: contain;
    filter: drop-shadow(0 3px 4px rgba(124, 94, 0, 0.13));
  }

  .app-nav-label {
    display: block;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
}
```

## Responsiveness / Breakpoint

Empfohlener Breakpoint: `max-width: 640px`.

Begründung: Die bestehende App ist stark mobil orientiert, aber Desktop/Tablet soll die aktuelle Header-Navigation behalten. 640px deckt typische Smartphones und schmale Browserfenster ab, ohne Tablet/Desktop unnötig umzubauen.

## Accessibility

- `nav` behält `aria-label="Hauptnavigation"`.
- Icons haben leeres `alt` und `aria-hidden`, weil die Labels den Namen liefern.
- Aktiver Link bleibt visuell markiert über `.active`.
- `:focus-visible` muss weiterhin klar sichtbar sein; vorhandener Fokus-Stil soll erhalten oder mobil angepasst werden.
- `body` bekommt auf Mobil genug Bottom-Padding, damit die fixe Navi keinen Content verdeckt.
- `env(safe-area-inset-bottom)` schützt iPhones mit Home Indicator.

## Tests / Verifikation

Manuell im Browser prüfen:

1. Desktop: Header und Navigation sehen unverändert aus.
2. Mobile Viewport: Navigation sitzt unten, bleibt beim Scrollen sichtbar.
3. Mobile: Header zeigt keine doppelte Navigation oben.
4. Alle fünf Links führen zu den richtigen Seiten.
5. Aktiver Zustand stimmt für Dashboard, Schalten, Berichte, Wetter, Sensoren.
6. Content wird am Seitenende nicht von der Bottom-Navi verdeckt.
7. Fokus per Tastatur ist sichtbar.
8. Browser ohne `backdrop-filter` zeigt immer noch lesbare Navigation.

Automatisiert:

- Vorhandene Controller/Systemtests sollten weiterhin laufen.
- Falls bereits View-Tests existieren: prüfen, ob die Linktexte weiterhin auffindbar bleiben.

## Implementierungsnotizen

- Der mobile Labeltext für die Startseite ist `Home`; der Link führt weiterhin auf `root_path`/Dashboard.
- Das Logo bleibt auf Mobil oben sichtbar. Nur die Navigation wird zur fixen Bottom-Bar.
- Optional später: Icons durch einzeln mit transparentem Hintergrund generierte Assets ersetzen, falls die Freistellung noch weiter perfektioniert werden soll.

## Referenz-Mockup

Das im Brainstorming abgestimmte Mockup liegt unter:

`/.superpowers/brainstorm/4371-1781715978/content/mobile-nav-real-plush-crops-v6-smaller-icons.html`

Im Mockup wurden die WebP-Assets als Base64 eingebettet. Die Spec verwendet oben bewusst die produktionsnahe `image_tag`-Variante mit den realen Asset-Dateien.
