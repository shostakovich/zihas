# Solakon One – Null-Einspeisung (Zero Export) — Design

**Datum:** 2026-06-16
**Status:** Abgenommen (Design), bereit für Implementierungsplan

## Ziel

Die Solakon One (Batterie + Wechselrichter, Balkonkraftwerk) so steuern, dass
sie **keine** Leistung ins Netz einspeist („eine Art Null-Einspeisung"), indem
ihre AC-Ausgabe minütlich auf den aktuell gemessenen Hausverbrauch nachgeführt
wird. Datenquelle für den Verbrauch sind die bestehenden Shelly- und
Fritz!DECT-Steckdosen. Es gibt **keine UI** — Ergebnis ist ein strukturiertes
Log.

## Rahmenbedingungen / getroffene Entscheidungen

- **Keine Messung am Netzanschlusspunkt** (kein Shelly 3EM, kein CT an der
  Solakon). Der Hausverbrauch wird aus den gemessenen Verbrauchern geschätzt.
- **Steuerung direkt per Modbus TCP** mit der Solakon One (Home Assistant wird
  umgangen). Die HA-Integration läuft **nicht parallel** als Modbus-Controller
  (kein konkurrierendes Schreiben auf dieselben Register).
- **Keine angenommene Grundlast als Offset** — fast die ganze Wohnung ist mit
  Shellys ausgestattet.
- **Regeltakt minütlich** (später evtl. häufiger; out of scope für v1).
- Integration als neuer wiederkehrender Solid-Queue-Job in der bestehenden
  Rails-App ZiWoAS.

## Kernidee & mathematische Garantie

Da die Summe der **gemessenen** Verbraucher immer ≤ dem echten Hausverbrauch
ist, kann die Regel

```
ausgabe = Σ gemessene Verbraucher
```

**nie** zu Einspeisung führen — ungemessene Restlast deckt einfach das Netz. Je
mehr Shellys, desto näher an 100 % Eigenverbrauch. Es ist kein Offset, kein PID,
keine Rückkopplung über einen Netzzähler nötig; minütlicher Feed-Forward genügt.

## Regel-Logik

```
target_w = clamp( max( Σ frische Consumer-Samples , guaranteed_floor_w ), 0, MAX_OUTPUT_W )
```

- **Σ frische Consumer-Samples:** Summe von `Sample.apower_w` (neuester Wert pro
  `plug_id`) über alle Plugs mit `role: consumer`, sofern der Sample frisch ist
  (jünger als `stale_after_s`). Stale Plugs fallen aus der Summe (unterschätzen
  ist export-sicher).
- **guaranteed_floor_w:** dauerhafte, export-sichere Untergrenze (siehe unten).
  Wirkt nicht nur im Fehlerfall, sondern hält die Ausgabe auch oben, wenn
  einzelne Plugs gerade stale sind.
- **MAX_OUTPUT_W = 800** (gesetzliches BKW-Limit, hardcodierte Konstante).

### Fail-Safe: guaranteed_floor_w

`guaranteed_floor_w` = **Minimum des 5-Minuten-Gesamtverbrauchs über die letzten
24 h**.

Berechnung aus der **rohen `samples`-Tabelle** (nicht aus `samples_5min` — die
wird vom Aggregator nur täglich um 3:15 Uhr befüllt und enthält die rollierenden
letzten 24 h nicht in Echtzeit):

1. Rohe Samples der letzten 24 h pro Plug in 5-Min-Buckets `(ts / 300) * 300`
   gruppieren, je Plug+Bucket `AVG(apower_w)`.
2. Pro Bucket die Plug-Mittelwerte über alle Consumer-Plugs summieren
   (= Gesamtverbrauch im Bucket).
3. Über alle Buckets das **Minimum** nehmen.

Diesen Wert liegt der Haushalt praktisch immer mindestens an → ihn auszugeben
ist export-sicher, auch wenn keine Live-Daten verfügbar sind. Die Abfrage ist
träge und wird **periodisch gecacht** (z. B. stündliche Neuberechnung), nicht
jede Minute neu gerechnet.

Verhalten:
- Live-Daten gesund → `Σ frische Samples` regiert (liegt ohnehin ≥ floor).
- Einzelne Plugs stale → `floor` hält die Ausgabe sicher oben.
- Alles tot / Modbus-Lesefehler → es bleibt `floor`. Kein Export, trotzdem
  Eigenverbrauch.

### Batterie-Schutz

- **MIN_SOC_PCT = 10** (hardcodierte Konstante). Wird über das Modbus-Register
  `minimum_soc_control` gesetzt/sichergestellt. Der Wechselrichter entlädt dann
  nicht unter 10 %.
- Defense-in-depth: Selbst der `guaranteed_floor` kann die Batterie nicht unter
  10 % ziehen, weil der Wechselrichter es selbst begrenzt — dann deckt das Netz
  die Lücke (weiterhin kein Export).

## Architektur (kleine, testbare Kollaborateure)

Im Stil des bestehenden Repos (vgl. `EnergyReport`-Split, `PlugCommander` als
Choke-Point):

| Komponente | Ort | Aufgabe | Abhängigkeiten |
|---|---|---|---|
| `SolakonClient` | `lib/` | Dünner Modbus-TCP-Wrapper: Sensoren lesen, Sollwert & Steuermodus & min-SoC schreiben. Analog zu `FritzDectClient`/`SwitchBotClient`. | `rmodbus` (neu), Config (host/port/unit_id) |
| `ConsumptionReader` | `app/models/` | Summe der gemessenen Verbraucher aus neuesten `Sample`s (Frische-Filter); Berechnung & Cache von `guaranteed_floor_w`. | `Sample`, Plug-Config |
| `ZeroExportController` | `app/models/` | Reine Regel-Logik (PORO, keine I/O): aus Verbrauch + floor → Sollwert. Voll unit-testbar. | — |
| `ZeroExportTickJob` | `app/jobs/` | Minütlich; verdrahtet Reader + Controller + Client; loggt Entscheidung. Spiegelt `ScheduleTickJob`. | obige |

### Datenfluss (pro Minute)

```
ZeroExportTickJob
  → ConsumptionReader            (DB: neueste Samples je Consumer-Plug, + cached floor)
  → ZeroExportController         (target_w = clamp(max(Σ frisch, floor), 0, MAX))
  → SolakonClient                (Modbus: Sollwert schreiben; Ist-Werte lesen)
  → Rails.logger                 (strukturiertes Log: Verbrauch je Plug, target, Ist-active_power, SoC, PV)
```

### Modbus-Register

Der genaue Register-Plan (Adressen, Datentypen, Skalierung für
`remote_active_power_control`, `remote_control_mode`, `minimum_soc_control`,
`battery_soc`, `active_power`, `pv_power`, `load_power`) wird beim
Implementierungsplan aus dem Quellcode der HA-Integration
(`solakon-de/solakon-one-homeassistant`, Modbus TCP) extrahiert.

Beim Steuern muss ggf. zuerst der Steuermodus (`remote_control_mode`) auf
Fernsteuerung gesetzt werden, bevor `remote_active_power_control` greift.

## Konfiguration

Neuer `solakon:`-Block in `config/ziwoas.yml` + Erweiterung `ConfigLoader`:

```yaml
solakon:
  host: 192.168.x.x        # Modbus-TCP-Host der Solakon One
  port: 502                # Modbus-TCP-Port (Default 502)
  unit_id: 1               # Modbus Unit/Slave ID
  enabled: true            # Schalter, um die Regelung global aus/an zu schalten
  stale_after_s: 120       # Samples älter als das fallen aus der Live-Summe
```

`MAX_OUTPUT_W` (800) und `MIN_SOC_PCT` (10) sind **hardcodierte Konstanten**, nicht
in der Config.

Recurring-Eintrag in `config/recurring.yml` (im geteilten `aggregator_schedule`):

```yaml
zero_export_tick:
  class: ZeroExportTickJob
  queue: default
  schedule: every minute
```

## Fehlerbehandlung & Sicherheit

- **Verbrauchsdaten stale:** betroffene Plugs aus Live-Summe streichen; `floor`
  greift als Untergrenze.
- **Modbus-Lese-/Schreibfehler:** Log-Warnung; Sollwert strebt `floor` an. Wenn
  selbst das Schreiben scheitert, bleibt der zuletzt gesetzte Sollwert stehen.
- **Watchdog-Risiko (offen, im Plan zu klären):** Falls
  `remote_active_power_control` keinen eigenen Timeout hat und die Verbindung
  wegbricht, kann ein zu hoher Sollwert stehenbleiben → Export-Risiko bei
  fallender Last. Mitigation: bei wiederholtem Fehler / Job-Shutdown den
  Steuermodus auf Default zurücksetzen. Das tatsächliche Timeout-Verhalten des
  Wechselrichters ist beim Implementieren zu verifizieren.
- `enabled: false` schaltet die Regelung sauber ab (Job wird No-Op).

## Annahmen

1. Der `bkw`-Plug (`role: producer`) ist die Solakon-Ausgabe → wird nicht als
   Verbraucher gezählt (Producer sind per Rolle bereits ausgeschlossen).
2. Die HA-Integration schreibt nicht parallel auf dieselben Modbus-Register.
3. Fritz!DECT-Werte landen (über `fritz_mqtt_bridge`) als normale `Sample`-Zeilen
   → „neuester Sample pro Plug" deckt Shelly **und** Fritz einheitlich ab.
   (Im Plan kurz verifizieren.)

## Testing

- `ZeroExportController`: reine Unit-Tests (clamp, floor-Untergrenze, stale,
  MAX-Cap, Fail-Safe).
- `ConsumptionReader`: DB-Fixtures (Frische-Filter, floor-Berechnung aus rohen
  `samples`, Cache).
- `SolakonClient`: gemockter Modbus (Lesen/Schreiben, Skalierung,
  Fehlerpfade).
- `ZeroExportTickJob`: Integration mit Fakes (Verdrahtung, Logging,
  `enabled: false`-No-Op).
- Keine UI, kein System-Test.

## Out of Scope (v1)

- Sub-minütlicher Regeltakt.
- Echte Netzeinspeise-Messung / Netzzähler-Rückkopplung.
- UI / Dashboard-Anzeige der Regelung.
- Laden der Batterie aus dem Netz; gezieltes PV-Überschuss-Management (regelt der
  Wechselrichter intern).
