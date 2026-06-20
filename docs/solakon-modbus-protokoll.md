# Solakon ONE – Modbus-Protokoll (Referenz)

> Vollständige Aufbereitung des PDF **„Solakon ONE Modbus Protokoll v.02/26"**
> ([Quelle](https://cdn.shopify.com/s/files/1/0605/9684/6744/files/Solakon_ONE_Modbus_Protokoll_02_26.pdf))
> **plus** der Verschneidung mit unserem Quellcode.
>
> **Zweck:** Diese Datei ist die Single Source of Truth, damit das PDF nicht jedes Mal
> neu gelesen/geparst werden muss. Wenn sich am Protokoll oder an unserer Nutzung etwas
> ändert, hier nachziehen. Stand: 2026-06-20.

## Inhalt

1. [Wie wir das Protokoll nutzen (Code-Sicht)](#1-wie-wir-das-protokoll-nutzen-code-sicht)
2. [Cross-Reference: unsere Register ↔ PDF](#2-cross-reference-unsere-register--pdf)
3. [Abweichungen & Lücken zwischen Code und PDF](#3-abweichungen--lücken-zwischen-code-und-pdf)
4. [Grundlagen & Begriffe (Tabelle 1-1)](#4-grundlagen--begriffe-tabelle-1-1)
5. [Produktparameter (Tabellen 2-1 bis 2-3)](#5-produktparameter-tabellen-2-1-bis-2-3)
6. [Register-Definitionstabellen (2-4 bis 2-11)](#6-register-definitionstabellen-2-4-bis-2-11)
7. [Alarme (Tabelle 3-1)](#7-alarme-tabelle-3-1)
8. [Netzcodes / Grid Codes (Tabelle 3-2)](#8-netzcodes--grid-codes-tabelle-3-2)
9. [Ansteuerung (Remote Control 46001)](#9-ansteuerung-remote-control-46001)

---

## 1. Wie wir das Protokoll nutzen (Code-Sicht)

**Transport / Verbindung** — implementiert in [`lib/solakon_client.rb`](../lib/solakon_client.rb):

| Eigenschaft | Wert | Quelle |
|-------------|------|--------|
| Transport | **Modbus TCP** | `ModBus::TCPClient.connect` ([solakon_client.rb:115](../lib/solakon_client.rb#L115)), Gem `rmodbus` |
| Registertyp | **Holding Registers** (FC03 lesen / FC06 + FC16 schreiben) | [solakon_client.rb:5-8](../lib/solakon_client.rb#L5) |
| Word-Order (32-Bit) | **Big-Endian, High Word First** | `to_i32` / `from_i32` ([solakon_client.rb:130-138](../lib/solakon_client.rb#L130)) |
| Host | `solakon.host` (z. B. `192.168.1.50`) | [`config/ziwoas.example.yml`](../config/ziwoas.example.yml) |
| Port | `solakon.port`, Default **502** | `ConfigLoader::SolakonCfg` ([config_loader.rb](../lib/config_loader.rb)) |
| Unit / Slave ID | `solakon.unit_id`, Default **1** | s. o. |
| Stale-Schwelle | `solakon.stale_after_s`, Default **120 s** | s. o. |
| Monitoring an? | `solakon.monitoring_enabled`, Default **true** | s. o. |
| Steuerung (Nulleinspeisung) an? | `solakon.control_enabled`, Default **false** | s. o. |

> **Hinweis Funktionscodes:** Das PDF nennt keine FC-Nummern, Unit-ID oder Baudrate (Modbus TCP).
> Die Angaben oben stammen aus unserem live verifizierten Code, nicht aus dem PDF (vgl. [§3](#3-abweichungen--lücken-zwischen-code-und-pdf)).

**Datenfluss** ([`app/jobs/solakon_monitor_job.rb`](../app/jobs/solakon_monitor_job.rb) → [`app/jobs/zero_export_tick_job.rb`](../app/jobs/zero_export_tick_job.rb)):

```
Modbus TCP (Solakon ONE)
  → SolakonClient#read_state            (FC03)
    → SolakonReading.create!            (Persistenz, app/models/solakon_reading.rb)
    → ZeroExportTickJob (wenn control_enabled)
        → ConsumptionReader (Live-Last, 24h-Floor, Nacht-Basis P20)
        → SunWindow (Tag/Nacht, Stunden bis Sonnenaufgang)
        → ZeroExportController#decide    (reine State-Machine)
        → SolakonClient#apply_control!   (FC06/FC16, nur bei Bedarf — Sparse Write)
```

Algorithmus-Details stehen in [`docs/superpowers/specs/2026-06-20-solakon-control-algorithm-design.md`](superpowers/specs/2026-06-20-solakon-control-algorithm-design.md)
und im Plan [`docs/superpowers/plans/2026-06-20-solakon-control-algorithm.md`](superpowers/plans/2026-06-20-solakon-control-algorithm.md).

---

## 2. Cross-Reference: unsere Register ↔ PDF

Nur diese Register berührt unser Code aktuell. Konstanten in [`lib/solakon_client.rb`](../lib/solakon_client.rb).

### Gelesen (FC03)

| Adresse | Code-Konstante | Modell-Feld | Typ | #Reg | Skalierung im Code | PDF-Eintrag | Anmerkung |
|--------:|----------------|-------------|-----|:----:|--------------------|-------------|-----------|
| 39424 | `REG_BATTERY_SOC` | `battery_soc_pct` | i16 | 1 | × 1 (%) | **— nicht im PDF v02/26 —** | Live verifiziert: liefert exakt denselben Wert wie BMS1 SoC (37612). Aggregierter Gesamt-SoC, im PDF nur nicht gelistet. Siehe [§3](#3-abweichungen--lücken-zwischen-code-und-pdf). |
| 39248 | `REG_ACTIVE_POWER` | `active_power_w` | i32 | 2 | × 1 (W) | Index 214 „INV R Phase Active Power" (W, Faktor 1) | Wir nutzen die R-Phase als Gesamtwirkleistung (einphasiger Balkon-Aufbau). |
| 39230 | `REG_BATTERY_POWER` | `battery_power_w` | i32 | 2 | × 1 (W) | Index 203 „Battery 1 Power" (W, Faktor 1) | Vorzeichen: **+ = Laden, − = Entladen**. (Combined läge bei 39237.) |
| 39279 (+2·(n−1)) | `REG_PV_POWER_BASE` | `pv_power_w` | i32 ×4 | 8 | × 1 (W), Summe der 4 Strings | Index 231 ff. „PV1..PVn Power" (W, Faktor 1) | Es gibt kein Momentan-Gesamt-PV-Register; ungenutzte Strings lesen 0. |
| 37617 | `REG_BMS_MAX_TEMP` | `battery_temperature_c` | i16 | 1 | ÷ 10 (°C) | Index 28 „BMS1 Max Temperature" (℃, Faktor 10) | Skalierung passt zum PDF-Faktor 10. |
| 46609 | `REG_MINIMUM_SOC` | (nur lesen vor Schreiben) | u16 | 1 | × 1 (%) | Index 298 „Minimum SoC" (%, [10,100]) | Wird nur gelesen, um Self-Healing-Write zu entscheiden. |

### Geschrieben (FC06 / FC16)

| Adresse | Code-Konstante | Typ | #Reg | Wert | PDF-Eintrag | Anmerkung |
|--------:|----------------|-----|:----:|------|-------------|-----------|
| 46001 | `REG_REMOTE_CONTROL` | Bitfield16 | 1 | `0b0001` ein / `0` aus | Index 270 „Remote Control" | `0b0001` = Enable + Generation + Target AC. PDF-Notation „00 0 1". |
| 46002 | `REG_REMOTE_TIMEOUT` | u16 | 1 | `150` (s) | Index 271 „Remote Timeout_Set" (s) | Inverter-seitiger Watchdog; > Tick-Intervall, damit Normalbetrieb ihn nicht auslöst. |
| 46003 | `REG_REMOTE_ACTIVE_POWER` | i32 | 2 | 0…800 (W, geclamped) | Index 272 „Remote Control Active Power Command" (W) | Aktiver Leistungs-Sollwert pro Steuer-Tick. |
| 46609 | `REG_MINIMUM_SOC` | u16 | 1 | `10` | Index 298 „Minimum SoC" (%) | **Nur bei Abweichung** schreiben (persistentes Register → Flash schonen). |

`46001`-Bitfeld wird im Code als `REMOTE_CONTROL_ENABLE = 0b0001` kodiert
([solakon_client.rb:31-34](../lib/solakon_client.rb#L31)). Bedeutung der Bits → [§9](#9-ansteuerung-remote-control-46001).

---

## 3. Abweichungen & Lücken zwischen Code und PDF

- **SoC-Register 39424 fehlt im PDF v02/26 — ist aber live korrekt.** Die Register-Definitionstabelle 2-5
  endet bei den MPPT-Werten (…39337) und springt dann auf 39600 (Tabelle 2-6); Adresse **39424** existiert in
  diesem Dokument nicht. **Live gegen das Gerät geprüft (2026-06-20, Host 192.168.8.166):** 39424 liefert
  `58 %` — identisch zum dokumentierten **BMS1 SoC = 37612** (`58 %`). 39424 ist also der vom Inverter
  aggregierte Gesamt-SoC und eine gültige Quelle; das PDF listet ihn nur nicht. Dokumentierter Fallback wäre
  **BMS1 SoC 37612** (bzw. **BMS2 SoC 38310** für die zweite Batterie; im Testsystem ist nur eine verbaut, 38310 = `0`).
- **Active Power (39248).** Im PDF ist 39248 die *INV R Phase* Active Power, nicht die kombinierte
  Wirkleistung. Für unseren einphasigen Aufbau ist das die Gesamtleistung; bei dreiphasigem Einsatz
  müsste man Index 214/215/216 summieren oder die kombinierte Leistung (39134, „Active power", kW ×1000) lesen.
- **Battery Power (39230).** Wir lesen „Battery 1 Power". Bei zwei Batterien gäbe es Battery 2 (39235)
  bzw. Battery Combined (39237).
- **Protokoll-Metadaten nicht im PDF.** Funktionscodes, Unit/Slave-ID, Baudrate und explizite Endianness
  stehen **nicht** im PDF. Einzige protokollnahe Aussagen: „Register address = 2-Byte-Nachricht",
  „broadcast address = fest 0", und das Versionsbeispiel `0x01020304` = V1.02.03.04 (Startversion V1.01.00.00).
  Alle Verbindungsdetails in [§1](#1-wie-wir-das-protokoll-nutzen-code-sicht) stammen aus unserem verifizierten Code.

---

## 4. Grundlagen & Begriffe (Tabelle 1-1)

Das Modbus-Protokoll ist ein anerkannter Kommunikationsstandard auf Geräteebene. Der Solakon ONE
entspricht der offiziellen Modbus-Spezifikation; das PDF beschränkt sich auf die gerätespezifischen Teile.

| Begriff | Bedeutung |
|---------|-----------|
| master node | Initiiert die Kommunikation aktiv (Masterknoten). |
| slave node | Reagiert passiv auf Befehle (Slaveknoten). |
| broadcast address | Fest auf 0 gesetzt. |
| Register address | Entspricht einer 2-Byte-Nachricht. |
| U16 / U32 | 16- bzw. 32-Bit-Integer **ohne** Vorzeichen. |
| I16 / I32 | 16- bzw. 32-Bit-Integer **mit** Vorzeichen. |
| STR | Zeichenkette. |
| MLD | Multibyte. |
| Bitfield16 / Bitfield32 | 16- bzw. 32-Bit breite bitweise Datendarstellung. |
| s | Sekunde. |
| INV | Wechselrichter. |
| BMS | Batteriemanagementsystem. |
| RO / RW / WO | Nur lesbar / lese- und schreibbar / nur schreibbar. |
| - | nicht beteiligt / nicht zutreffend. |

**Datentyp-Konventionen für diese Datei:** „#Reg" = Anzahl belegter 16-Bit-Register. „Faktor" = Wert,
durch den der Rohwert geteilt wird, um die physikalische Einheit zu erhalten (z. B. Faktor 10 bei V → Rohwert/10 = Volt).

---

## 5. Produktparameter (Tabellen 2-1 bis 2-3)

### Tabelle 2-1: Inverter-Modell-Informationen

| Index | Signal | Typ | Datentyp | Faktor | Adresse | #Reg |
|------:|--------|-----|----------|:------:|--------:|:----:|
| 1 | Model name | RO | STR | 1 | 30000 | 16 |
| 2 | SN | RO | STR | 1 | 30016 | 16 |
| 3 | MFG ID | RO | STR | 1 | 30032 | 16 |

### Tabelle 2-2: Inverter-Version-Informationen

| Index | Signal | Typ | Datentyp | Adresse | #Reg |
|------:|--------|-----|----------|--------:|:----:|
| 4 | Master Version | RO | U16 | 36001 | 1 |
| 5 | Slave Version | RO | U16 | 36002 | 1 |
| 6 | Manager Version | RO | U16 | 36003 | 1 |
| 7 | Meter1 SN | RO | STR | 36100 | 16 |
| 8 | Meter1 MFG ID | RO | STR | 36116 | 16 |
| 9 | Meter1 TYPE | RO | STR | 36132 | 16 |
| 10 | Meter1 Version | RO | STR | 36148 | 1 |
| 11 | Meter2 SN | RO | STR | 36200 | 16 |
| 12 | Meter2 MFG ID | RO | STR | 36216 | 16 |
| 13 | Meter2 TYPE | RO | STR | 36232 | 16 |
| 14 | Meter2 Version | RO | STR | 36248 | 1 |

### Tabelle 2-3: Batterie-Version- & BMS-Informationen

> Für BMS1/BMS2 gilt: max. 32 Slave-Kanäle. Tatsächlich gelesene Kanäle = „BMS amount of slaves".
> Versionsadresse Slave n: `37033 + (n−1)` (BMS1) bzw. `37731 + (n−1)` (BMS2).
> SN-Adresse Slave n: `37097 + 16·(n−1)` (BMS1) bzw. `37795 + 16·(n−1)` (BMS2). n ∈ [1, 32].

| Index | Signal | Typ | Datentyp | Einheit | Faktor | Adresse | #Reg | Zusatzinfo |
|------:|--------|-----|----------|---------|:------:|--------:|:----:|------------|
| 15 | BMS1 connect state | RO | U16 | — | — | 37002 | 1 | 0: Offline, 1: Online |
| 16 | BMS1 Master version | RO | U16 | — | — | 37003 | 1 | |
| 17 | BMS1 Main Control | RO | U16 | — | — | 37004 | 1 | |
| 18 | BMS1 Main SN | RO | STR | — | — | 37005 | 16 | |
| 19 | BMS1 amount of slaves | RO | U16 | — | 1 | 37032 | 1 | [0, 32]; 0 = nicht vorhanden |
| 20 | BMS1 Slave 1 version | RO | U16 | — | — | 37033 | 1 | s. Formel oben |
| 21 | BMS1 Slave 2 version | RO | U16 | — | — | 37034 | 1 | |
| 22 | BMS1 1 - SN | RO | STR | — | — | 37097 | 16 | s. Formel oben |
| 23 | BMS1 2 - SN | RO | STR | — | — | 37113 | 16 | |
| 24 | BMS1 Voltage | RO | U16 | V | 10 | 37609 | 1 | |
| 25 | BMS1 Current | RO | I16 | A | 10 | 37610 | 1 | |
| 26 | BMS1 Ambient Temperature | RO | I16 | ℃ | 10 | 37611 | 1 | |
| 27 | **BMS1 SoC** | RO | U16 | % | 1 | **37612** | 1 | dokumentierte SoC-Quelle |
| 28 | **BMS1 Max Temperature** | RO | I16 | ℃ | 10 | **37617** | 1 | von uns gelesen (`REG_BMS_MAX_TEMP`) |
| 29 | BMS1 Min Temperature | RO | I16 | ℃ | 10 | 37618 | 1 | |
| 30 | BMS1 Max Cell Voltage | RO | U16 | mV | 1 | 37619 | 1 | |
| 31 | BMS1 Min Cell Voltage | RO | U16 | mV | 1 | 37620 | 1 | |
| 32 | BMS1 SOH | RO | U16 | % | 1 | 37624 | 1 | |
| 33–38 | BMS1 Fault1…Fault6 | RO | Bitfield16 | — | — | 37626–37631 | je 1 | |
| 39 | BMS1 Remain Energy | RO | U16 | Wh | 0.1 | 37632 | 1 | |
| 40 | BMS1 FCC Capacity | RO | U16 | Ah | 10 | 37633 | 1 | |
| 41 | reserve | RO | U16 | — | — | 37634 | 1 | |
| 42 | BMS1 Design Energy | RO | U16 | Wh | 0.1 | 37635 | 1 | |
| 43 | BMS1 Force to Change battery Flag | RO | U16 | — | — | 37636 | 1 | 0: Reset, 1: Set (lädt bis Reset) |
| 44 | BMS2 connect state | RO | U16 | — | — | 37700 | 1 | 0: Offline, 1: Online |
| 45 | BMS2 Master version | RO | U16 | — | — | 37701 | 1 | |
| 46 | BMS2 Main control | RO | U16 | — | — | 37702 | 1 | |
| 47 | BMS2 Main SN | RO | STR | — | — | 37703 | 16 | |
| 48 | BMS2 amount of slaves | RO | U16 | — | 1 | 37730 | 1 | [0, 32]; 0 = nicht vorhanden |
| 49 | BMS2 Slave 1 version | RO | U16 | — | — | 37731 | 1 | |
| 50 | BMS2 Slave 2 version | RO | U16 | — | — | 37732 | 1 | |
| 51 | BMS2 1 - SN | RO | STR | — | — | 37795 | 16 | |
| 52 | BMS2 2 - SN | RO | STR | — | — | 37811 | 16 | |
| 53 | BMS2 Voltage | RO | U16 | V | 10 | 38307 | 1 | |
| 54 | BMS2 Current | RO | I16 | A | 10 | 38308 | 1 | |
| 55 | BMS2 Ambient Temperature | RO | I16 | ℃ | 10 | 38309 | 1 | |
| 56 | **BMS2 SoC** | RO | U16 | % | 1 | **38310** | 1 | dokumentierte SoC-Quelle (2. Batterie) |
| 57 | BMS2 Max Temperature | RO | I16 | ℃ | 10 | 38315 | 1 | |
| 58 | BMS2 Min Temperature | RO | I16 | ℃ | 10 | 38316 | 1 | |
| 59 | BMS2 Max Cell Voltage | RO | U16 | mV | 1 | 38317 | 1 | |
| 60 | BMS2 Min Cell Voltage | RO | U16 | mV | 1 | 38318 | 1 | |
| 61 | BMS2 SOH | RO | U16 | % | 1 | 38322 | 1 | |
| 62–67 | BMS2 Fault1…Fault6 | RO | Bitfield16 | — | — | 38324–38329 | je 1 | |
| 68 | BMS2 Remain Energy | RO | U16 | Wh | 0.1 | 38330 | 1 | |
| 69 | BMS2 FCC Capacity | RO | U16 | Ah | 10 | 38331 | 1 | |
| 70 | reserve | RO | U16 | — | — | 38332 | 1 | |
| 71 | BMS2 Design Energy | RO | U16 | Wh | 0.1 | 38333 | 1 | |
| 72 | BMS2 Force to Change battery Flag | RO | U16 | — | — | 38334 | 1 | 0: Reset, 1: Set |

---

## 6. Register-Definitionstabellen (2-4 bis 2-11)

Im PDF tragen alle Tabellen den Titel „Register Definitionstabelle". Sie sind hier nach Adressbereich/Thema
benannt. Wo „PVn"/„MPPTn"/„Meter" generisch sind, gilt: gelesene Kanalzahl = entsprechende „Number of …".

### Tabelle 2-4: Meter / CT Messwerte (38801–38946)

Adressschema identisch für Meter1/CT1 (388xx) und Meter2/CT2 (389xx). Connect State: U16, 0 = Getrennt, 1 = Verbunden.
Alle übrigen Messwerte: I32, 2 Register.

| Größe | Einheit | Faktor | Meter1-Adresse | Meter2-Adresse |
|-------|---------|:------:|:--------------:|:--------------:|
| Connect State (U16) | — | — | 38801 | 38901 |
| R/S/T Phase Voltage | V | 10 | 38802 / 38804 / 38806 | 38902 / 38904 / 38906 |
| R/S/T Phase Current | A | 1000 | 38808 / 38810 / 38812 | 38908 / 38910 / 38912 |
| Combined Active Power | W | 10 | 38814 | 38914 |
| R/S/T Phase Active Power | W | 10 | 38816 / 38818 / 38820 | 38916 / 38918 / 38920 |
| Combined Reactive Power | Var | 10 | 38822 | 38922 |
| R/S/T Phase Reactive Power | Var | 10 | 38824 / 38826 / 38828 | 38924 / 38926 / 38928 |
| Combined Apparent Power | VA | 10 | 38830 | 38930 |
| R/S/T Phase Apparent Power | VA | 10 | 38832 / 38834 / 38836 | 38932 / 38934 / 38936 |
| Combined Power Factor | — | 1000 | 38838 | 38938 |
| R/S/T Phase Power Factor | — | 1000 | 38840 / 38842 / 38844 | 38940 / 38942 / 38944 |
| Freq | Hz | 100 | 38846 | 38946 |

### Tabelle 2-5: Inverter / PV / Grid / Last / Batterie Messwerte (39000–39337)

> **Protocol version (39000):** `0x01020304` = V1.02.03.04; Startversion V1.01.00.00.
> **PV-Strings:** `PVn voltage = 39070 + 2·(n−1)`, `PVn current = 39071 + 2·(n−1)`, `PVn Power = 39279 + 2·(n−1)`, n ∈ [1, 24].
> **MPPT:** `MPPTn Volt = 39327 + 4·(n−1)`, `MPPTn Curr = 39328 + 4·(n−1)`, `MPPTn Power = 39329 + 4·(n−1)`, n ∈ [1, 24].

| Index | Signal | Typ | Datentyp | Einheit | Faktor | Adresse | #Reg | Zusatzinfo |
|------:|--------|-----|----------|---------|:------:|--------:|:----:|------------|
| 121 | Protocol version | RO | U32 | — | — | 39000 | 2 | s. Beispiel oben |
| 122 | Model name | RO | STR | — | 1 | 39002 | 16 | |
| 123 | SN | RO | STR | — | 1 | 39018 | 16 | |
| 124 | PN | RO | STR | — | 1 | 39034 | 16 | |
| 125 | Model ID | RO | U16 | — | 1 | 39050 | 1 | |
| 126 | Number of strings | RO | U16 | — | 1 | 39051 | 1 | |
| 127 | Number of MPPTs | RO | U16 | — | 1 | 39052 | 1 | |
| 128 | Rated power (Pn) | RO | I32 | kW | 1000 | 39053 | 2 | |
| 129 | Maximum active power (Pmax) | RO | I32 | kW | 1000 | 39055 | 2 | |
| 130 | Maximum apparent power (Smax) | RO | I32 | kVA | 1000 | 39057 | 2 | |
| 131 | Max reactive power (Qmax, eingespeist) | RO | I32 | kVar | 1000 | 39059 | 2 | |
| 132 | Max reactive power (Qmax, bezogen) | RO | I32 | kVar | 1000 | 39061 | 2 | |
| 133 | Status 1 | RO | Bitfield16 | — | 1 | 39063 | 1 | Bit0: Standby; Bit2: Betrieb; Bit6: Fehler |
| 135 | Status 3 | RO | Bitfield32 | — | 1 | 39065 | 2 | Bit0: Inselbetrieb (0=nein, 1=ja) |
| 136 | Alarm 1 | RO | Bitfield16 | — | 1 | 39067 | 1 | s. [§7](#7-alarme-tabelle-3-1) |
| 137 | Alarm 2 | RO | Bitfield16 | — | 1 | 39068 | 1 | s. [§7](#7-alarme-tabelle-3-1) |
| 138 | Alarm 3 | RO | Bitfield16 | — | 1 | 39069 | 1 | s. [§7](#7-alarme-tabelle-3-1) |
| 139 | PV1 voltage | RO | I16 | V | 10 | 39070 | 1 | Schema s. oben |
| 140 | PV1 current | RO | I16 | A | 100 | 39071 | 1 | |
| 141–146 | PV2…PV4 voltage/current | RO | I16 | V / A | 10 / 100 | 39072–39077 | je 1 | |
| 147 | Total PV input power | RO | I32 | kW | 1000 | 39118 | 2 | |
| 151–153 | Grid R/S/T phase voltage | RO | I16 | V | 10 | 39123 / 39124 / 39125 | je 1 | |
| 154–156 | Inverter R/S/T phase current | RO | I32 | A | 1000 | 39126 / 39128 / 39130 | je 2 | |
| 158 | Active power | RO | I32 | kW | 1000 | 39134 | 2 | kombinierte Wirkleistung |
| 159 | Reactive power | RO | I32 | kVar | 1000 | 39136 | 2 | |
| 160 | power factor | RO | I16 | — | 1000 | 39138 | 1 | |
| 161 | Grid frequency | RO | I16 | Hz | 100 | 39139 | 1 | |
| 163 | internal temperature | RO | I16 | ℃ | 10 | 39141 | 1 | |
| 169 | Cumulative power generation | RO | U32 | kWh | 100 | 39149 | 2 | |
| 170 | Power generation on the day | RO | U32 | kWh | 100 | 39151 | 2 | |
| 178 | Energy storage module 1 charge/discharge power | RO | I32 | W | 1 | 39162 | 2 | >0: Laden, <0: Entladen |
| 181 | Meter collection Active power | RO | I32 | W | 1 | 39168 | 2 | >0: Einspeisung, <0: Bezug |
| 186–188 | EPS R/S/T Phase Voltage | RO | U16 | V | 10 | 39201 / 39202 / 39203 | je 1 | |
| 189–191 | EPS R/S/T Phase Current | RO | I32 | A | 1000 | 39204 / 39206 / 39208 | je 2 | |
| 192–194 | EPS R/S/T Phase Power | RO | I32 | W | 1 | 39210 / 39212 / 39214 | je 2 | |
| 195 | EPS Combined Power | RO | I32 | W | 1 | 39216 | 2 | |
| 196 | EPS Frequency | RO | I16 | Hz | 100 | 39218 | 1 | |
| 197–199 | Load R/S/T Phase Power | RO | I32 | W | 1 | 39219 / 39221 / 39223 | je 2 | |
| 200 | Load Combined Power | RO | I32 | W | 1 | 39225 | 2 | |
| 201 | Battery1 Voltage | RO | I16 | V | 10 | 39227 | 1 | |
| 202 | Battery1 Current | RO | I32 | A | 1000 | 39228 | 2 | |
| 203 | **Battery 1 Power** | RO | I32 | W | 1 | **39230** | 2 | von uns gelesen (`REG_BATTERY_POWER`) |
| 204 | Battery 2 Voltage | RO | I16 | V | 10 | 39232 | 1 | |
| 205 | Battery 2 Current | RO | I32 | A | 1000 | 39233 | 2 | |
| 206 | Battery 2 Power | RO | I32 | W | 1 | 39235 | 2 | |
| 207 | Battery Combined Power | RO | I32 | W | 1 | 39237 | 2 | |
| 214–216 | **INV R/S/T Phase Active Power** | RO | I32 | W | 1 | **39248** / 39250 / 39252 | je 2 | R-Phase = `REG_ACTIVE_POWER` |
| 218–220 | INV R/S/T Phase Reactive Power | RO | I32 | Var | 1 | 39256 / 39258 / 39260 | je 2 | |
| 222–224 | INV R/S/T Phase Apparent Power | RO | I32 | VA | 1 | 39264 / 39266 / 39268 | je 2 | |
| 225 | INV Combined Apparent Power | RO | I32 | VA | 1 | 39270 | 2 | |
| 226–228 | INV Frequency R/S/T | RO | I16 | Hz | 100 | 39272 / 39273 / 39274 | je 1 | |
| 229 | Available Import Power | RO | I32 | W | 1 | 39275 | 2 | |
| 230 | Available Export Power | RO | I32 | W | 1 | 39277 | 2 | |
| 231–234 | **PV1…PV4 Power** | RO | I32 | W | 1 | **39279** / 39281 / 39283 / 39285 | je 2 | von uns summiert (`REG_PV_POWER_BASE`) |
| 235 | MPPT1 Voltage | RO | I16 | V | 10 | 39327 | 1 | Schema s. oben |
| 236 | MPPT1 Current | RO | I16 | A | 100 | 39328 | 1 | |
| 237 | MPPT1 Power | RO | I32 | W | 1 | 39329 | 2 | |
| 238–243 | MPPT2/MPPT3 Volt/Curr/Power | RO | I16/I32 | V/A/W | 10/100/1 | 39331–39337 | | |

> Übersprungene Indizes (134, 148–150, 157, 162, 164–168, 171–177, 179–180, 182–185, 208–213, 217, 221) sind im PDF als **reserve** gelistet.
> **Lücke:** zwischen 39337 und 39600 dokumentiert das PDF nichts (relevant für unser SoC-Register 39424, s. [§3](#3-abweichungen--lücken-zwischen-code-und-pdf)).

### Tabelle 2-6: Kumulierte Energiezähler (39600–39631)

Alle U32, kWh, Faktor 100, je 2 Register.

| Index | Signal | Adresse |
|------:|--------|--------:|
| 245 | PV total power | 39601 |
| 246 | Total PV power today | 39603 |
| 247 | Total charging capacity | 39605 |
| 248 | Today's total charging capacity | 39607 |
| 249 | Total discharge power | 39609 |
| 250 | Today's total discharge power | 39611 |
| 251 | Total power of feeder network (Einspeisung gesamt) | 39613 |
| 252 | Today's total feeder power | 39615 |
| 253 | Total power taken (Netzbezug gesamt) | 39617 |
| 254 | Today's total electricity consumption | 39619 |
| 255 | Output total power | 39621 |
| 256 | Total power output today | 39623 |
| 257 | Enter total power | 39625 |
| 258 | Enter total power today | 39627 |
| 259 | Total load power | 39629 |
| 260 | Total load power today | 39631 |

### Tabelle 2-7: Batterie-Steuerbefehle / Factory Reset (45000–45007)

| Index | Signal | Typ | Datentyp | Adresse | Werte / Zusatzinfo |
|------:|--------|-----|----------|--------:|--------------------|
| 263 | Factory Reset | WO | U16 | 45002 | 0: ungültig, 1: aktiv |
| 264 | Battery power active | WO | U16 | 45003 | 0/1 — nur H3 Smart-Serie |
| 266 | Battery power shutdown | WO | U16 | 45005 | 0/1 — nur H3 Smart-Serie |
| 267 | Battery power ON/OFF | RO | U16 | 45006 | 0: AUS, 1: EIN |
| 268 | Battery Connect Enable | RW | U16 | 45007 | 0: Disable, 1: Enable — nur H3 Smart-Serie |

### Tabelle 2-8: Remote Control / Fernsteuerung (46000–46020)

| Index | Signal | Typ | Datentyp | Einheit | Adresse | #Reg | Zusatzinfo |
|------:|--------|-----|----------|---------|--------:|:----:|------------|
| 270 | Remote Control | RW | Bitfield16 | — | 46001 | 1 | Bit-Layout s. [§9](#9-ansteuerung-remote-control-46001) |
| 271 | Remote Timeout_Set | RW | U16 | s | 46002 | 1 | Watchdog-Fenster |
| 272 | Remote Control Active Power Command | RW | I32 | W | 46003 | 2 | Wirkleistungs-Sollwert |
| 273 | Remote Control Reactive Power Command | RW | I32 | Var | 46005 | 2 | Blindleistungs-Sollwert |
| 274 | Remote Timeout Countdown | RO | U16 | s | 46007 | 1 | verbleibende Aktiv-Zeit |
| 275 | Pwr_limit Bat_Up | RO | I32 | W | 46018 | 2 | |
| 276 | Pwr_limit Bat_Dn | RO | I32 | W | 46020 | 2 | |

### Tabelle 2-9: Lade-/Entlade-Limits & Zeitfenster (46500–46514)

| Index | Signal | Typ | Datentyp | Einheit | Adresse | #Reg |
|------:|--------|-----|----------|---------|--------:|:----:|
| 278 | Import Power Limit | RW | I32 | W | 46501 | 2 |
| 279 | Threshold SOC | RW | U16 | % | 46503 | 1 |
| 280 | Export Peak Limit | RW | I32 | W | 46504 | 2 |
| 281 | ChrInLowImport | RW | U16 | — | 46506 | 1 |
| 282–285 | ChrInLowTime1 Start/End Hour/Minute | RW | U16 | — | 46507–46510 | je 1 |
| 286–289 | ChrInLowTime2 Start/End Hour/Minute | RW | U16 | — | 46511–46514 | je 1 |

### Tabelle 2-10: Batterie-Strombegrenzungen, SoC-Grenzen, EPS (46601–46619)

| Index | Signal | Typ | Datentyp | Einheit | Faktor | Adresse | Zusatzinfo |
|------:|--------|-----|----------|---------|:------:|--------:|------------|
| 296 | Battery maximum charging current | RW | I16 | A | 10 | 46607 | H3:[0,26]; H3Pro/KH:[0,50]; H1:[0,40]; H1-G2:[0,40] |
| 297 | Battery maximum discharge current | RW | I16 | A | 10 | 46608 | H3:[0,26]; H3Pro/KH:[0,50]; H1:[0,50]; H1-G2:[0,40] |
| 298 | **Minimum SoC** | RW | U16 | % | 1 | **46609** | [10,100] — von uns geschrieben (`REG_MINIMUM_SOC`) |
| 299 | Maximum SoC | RW | U16 | % | 1 | 46610 | [10,100] |
| 300 | Minimum SoC OnGrid | RW | U16 | % | 1 | 46611 | [10,100] |
| 301 | EPS Frequency Select | RW | U16 | — | — | 46612 | 0: ungültig, 1: 50 Hz, 2: 60 Hz |
| 302 | EPS Output | RW | U16 | — | — | 46613 | 0: aus, 2: EPS, 3: UPS |
| 303 | Balance Load | RW | U16 | — | — | 46614 | 0: aus, 1: an |
| 304 | Balance Logic First | RW | U16 | — | — | 46615 | 0: aus, 1: an |
| 305 | Export Power Limit | RW | I32 | W | 1 | 46616 | [0, Pmax] |
| 306 | Import Current Limit | RW | I16 | A | 10 | 46618 | |
| 307 | Export Current Limit | RW | I16 | A | 10 | 46619 | |

### Tabelle 2-11: Systemzeit, Netz-Dispatch, Work mode, Geräteeinstellungen (49000–49245)

| Index | Signal | Typ | Datentyp | Einheit | Faktor | Adresse | #Reg | Zusatzinfo |
|------:|--------|-----|----------|---------|:------:|--------:|:----:|------------|
| 308 | system time | RW | U32 | — | — | 49000 | 2 | Ortszeit [946684800, 3155759999] |
| 312 | Grid Scheduling: Power compensation (PF) | RW | I16 | — | 1000 | 49005 | 1 | (−1, −0.8] ∪ [0.8, 1] |
| 313 | Grid Scheduling: Power compensation (Q/S) | RW | I16 | — | 1000 | 49006 | 1 | [−1.000, +1.000] |
| 314 | Grid dispatch: Active power % derating | RW | I16 | % | 10 | 49007 | 1 | [0, 100.0] |
| 322 | Power on | RW | U16 | — | — | 49077 | 1 | 0: ungültig, 1: gültig (Status: 49228) |
| 323 | Shut down | RW | U16 | — | — | 49078 | 1 | 0: ungültig, 1: gültig (Status: 49228) |
| 324 | Grid standard code | RW | U16 | — | — | 49079 | 1 | s. [§8](#8-netzcodes--grid-codes-tabelle-3-2) |
| 335 | Grid point power limit | RW | I32 | W | 1 | 49136 | 2 | [0, Pmax]; Default Pmax |
| 341 | Work mode | RW | U16 | — | — | 49203 | 1 | 1: Selbstverbrauch; 2: Einspeise-Priorität; 3: Backup; 4: Lastspitzenkappung; 6: erzw. Laden; 7: erzw. Entladen |
| 342 | DRM | RW | U16 | — | — | 49206 | 1 | 0/1 (nur AU) |
| 343 | Meter1/CT1 | RW | U16 | — | — | 49207 | 1 | 0: aus, 1: 1-Ph-Zähler, 2: CT, 3: 3-Ph-Zähler |
| 344 | Meter2/CT2 | RW | U16 | — | — | 49208 | 1 | 0: aus, 1: 1-Ph-Zähler, 2: CT, 3: 3-Ph-Zähler |
| 345 | BUZZER | RW | U16 | — | — | 49209 | 1 | 0/1 |
| 346 | MPPT Switch | RW | U16 | — | — | 49210 | 1 | 0/1 |
| 347 | Relay1 Switch | RW | U16 | — | — | 49211 | 1 | 0/1 |
| 348 | Relay2 Switch | RW | U16 | — | — | 49212 | 1 | 0/1 |
| 349 | Brightness Level | RW | U16 | % | 1 | 49221 | 1 | 0–100 % |
| 350–355 | Year / Month / Day / Hour / Minute / Second | RW | U16 | — | 1 | 49222–49227 | je 1 | RTC-Einstellung |
| 356 | System Power State | RO | U16 | — | 1 | 49228 | 1 | 0: AUS, 1: EIN |
| 357 | Idle State | RW | U16 | — | 1 | 49229 | 1 | 0/1 |
| 358 | Idle Loadpower Threshold | RW | U16 | W | 1 | 49230 | 1 | H3: 100–200 W; H3Pro: 100–600 W |
| 359 | Clear Idle Count | WO | U16 | — | 1 | 49231 | 1 | 0: Leerlaufzähler löschen |
| 360 | Key Password | RW | STR | — | 1 | 49232 | 8 | |
| 361 | Network status | RO | U16 | — | 1 | 49240 | 1 | 0: nicht verbunden, 1: getrennt, 2: verbunden |
| 362 | Ripple Control Enable | RW | U16 | — | 1 | 49241 | 1 | 0/1 |
| 363 | Trigger Signal | RO | U16 | — | 1 | 49242 | 1 | Bit0–3: K1–K4 status |
| 364–366 | K1/K2/K3 Power Ratio | RW | U16 | % | 1 | 49243–49245 | je 1 | [0, 100] |

---

## 7. Alarme (Tabelle 3-1)

Quelle: Register **Alarm 1 = 39067**, **Alarm 2 = 39068**, **Alarm 3 = 39069** (je Bitfield16).
Leeres „Level" = im PDF nicht als „important" markiert; alle benannten Bits sind „important", sofern nicht anders vermerkt.

### Alarm 1 (39067)

| Bit | Bedeutung |
|----:|-----------|
| 0 | Eingangs-String-Spannung zu hoch |
| 1 | DC-Lichtbogenfehler (DC arc fault) |
| 2 | String-Verpolung |
| 8 | Netzausfall (Grid power outage) |
| 9 | Netzspannung abnormal |
| 11 | Netzfrequenz abnormal |
| 14 | Ausgangs-Überstrom |
| 15 | DC-Anteil im Ausgangsstrom zu groß |

(Bits 3–7, 10, 12, 13 = reserve.)

### Alarm 2 (39068)

| Bit | Bedeutung |
|----:|-----------|
| 0 | Fehlerstrom abnormal (residual current) |
| 1 | Systemerdung abnormal |
| 2 | Isolationswiderstand zu niedrig |
| 3 | Temperatur zu hoch |
| 9 | Energiespeicher-Gerät abnormal |
| 10 | Inselbetrieb (isolated island) |
| 14 | Off-Grid-Ausgang überlastet |

(Bits 4–8, 11–13, 15 = reserve.)

### Alarm 3 (39069)

| Bit | Bedeutung | Level |
|----:|-----------|-------|
| 3 | Externer Lüfter abnormal | important |
| 4 | Energiespeicher-Verpolung | important |
| 9 | Meter Lost | (nicht markiert) |
| 10 | BMS Lost | (nicht markiert) |

(Übrige Bits = reserve.)

---

## 8. Netzcodes / Grid Codes (Tabelle 3-2)

Geschrieben über **Grid standard code = 49079** (U16). Auswahl (Enumeration → Standard → Land):

| Code | Name | Land |
|----:|------|------|
| 0 | AS4777_AU | Australia |
| 1 | AS4777_NZ | New Zealand |
| 2 | G98_UK | U.K. |
| 3 | G99_UK | U.K. |
| 4 | EN50549_NL | Netherlands |
| 5 | CEI021_A | Italy |
| **6** | **VDE0126** | **Germany** |
| **7** | **VDE4105_DE** | **Germany** |
| 8 | NBR-220_BR | Brazil |
| 9 | NBR-240_BR | Brazil |
| 10 | IEC61727 | India |
| 11 | Philippines | The Philippines |
| 12 | NRS_SA | South Africa |
| 13 | Vietnam | Vietnam |
| 14 | EN50549_PL | Poland |
| 15 | EN50549_PT | Portugal |
| 16 | PPDS_CR | Czech Republic |
| 17 | UNE-206_SP | Spain |
| 18 | RD1699_SP | Spain |
| 19 | Belgium | Belgium |
| 20 | VFR2019_FR | France |
| 21 | UTE_FR | France |
| 22 | Singapore | Singapore |
| 23 | Indonesia | Indonesia |
| 24 | Malaysia | Malaysia |
| 25 | Cambodia | Cambodia |
| 26 | PEA_TH | Thailand |
| 27 | MEA_TH | Thailand |
| 28 | Sri Lanka | Sri Lanka |
| 29 | Pakistan | Pakistan |
| 30 | Ireland | Ireland |
| 31 | Denmark 3.2.1 | Denmark |
| 32 | Slovakia | Slovakia |
| 33 | Austria | Austria |
| 34 | Switzerland | Switzerland |
| 35 | Slovenia | Slovenia |
| 36 | Hungary | Hungary |
| 37 | Serbia | Serbia |
| 38 | Croatia | Croatia |
| 39 | Turkey | Türkiye |
| 40 | Cyprus | Cyprus |
| 41 | Bulgaria | Bulgaria |
| 42 | Romania | Romania |
| 43 | Greece | Greece |
| 44 | Latvia | Latvia |
| 45 | Lithuania | Lithuania |
| 46 | Estonia | Estonia |
| 47 | Sweden | Sweden |
| 48 | Norway | Norway |
| 49 | Finland | Finland |
| 50 | Argentina | Argentina |
| 51 | Chile BT | Chile |
| 52 | Mexico | Mexico |
| 53 | USA | USA |
| 54 | Hawaii | Canada *(so im Original)* |
| 55 | CQC_CN | China |
| 56 | Japan | Japan |
| 57 | CQC_CN-1 | China (wide range) |
| 58 | Local | India (wide range) |
| 59 | Saudi Arabia | Saudi Arabia |
| 60 | AS4777_AU-2020A | Australia (A) |
| 61 | AS4777_AU-2020B | Australia (B) |
| 62 | AS4777_AU-2020C | Australia (C) |
| 63 | AS4777_NZ-2020 | New Zealand |
| 64 | CQC_CN-2 | China (wide range 2) |
| 65 | CEI021_B | Italy |
| 66 | CEI021_Areti_A | Italy |
| 67 | CEI021_Areti_B | Italy |
| 68 | NBR-220_BR2022 | Brazil |
| 69 | Spain | Spain |
| 70 | CQC_CN-3 | China |
| 71 | Puerto Rico | Puerto Rico |
| 72 | G98_NI | Northern Ireland |
| 73 | G99_NI | Northern Ireland |
| 74 | USA-208 | USA |
| **75** | **VDE4110_DE** | **Germany** |
| 76 | KSC8564 | South Korea |
| 77 | KSC8565 | South Korea |
| 78 | PR-LUMA | Puerto Rico |
| 79 | CEI016 | Italy |
| 80 | DUBAI | Dubai |
| 81 | Denmark 3.2.2 | Denmark |
| 82 | TR 3.3.1-DK1 | Denmark |
| 83 | TR 3.3.1-DK2 | Denmark |
| 84 | Chile MT-A | Chile |
| 85 | Chile MT-B | Chile |

---

## 9. Ansteuerung (Remote Control 46001)

Zentrale Steuerung erfolgt über das Bitfeld **46001** in Kombination mit Timeout (46002) und
Leistungs-Sollwert (46003). Unser Code setzt `46001 = 0b0001` (Enable + Generation + AC).

### Bit-Layout von 46001

| Bit(s) | Funktion | Werte |
|--------|----------|-------|
| 0 | Fernsteuerung aktivieren | 0 = deaktiviert, 1 = aktiviert |
| 1 | Definition positive Richtung | 0 = Erzeugungssystem (Generation), 1 = Verbrauchssystem (Consumption) |
| 3:2 | Gesteuertes Ziel (Target) | 00 = AC, 01 = Batterie, 10 = Netz (CT/Meter), 11 = AC (Grid first) |
| 15:4 | reserviert | — |

> PDF-Schreibweise der Beispiele: `[Bits 3:2] [Bit 1] [Bit 0]`, z. B. „00 0 1".

### Anwendungsfälle aus dem PDF

| Szenario | 46001 (Bit 3:2 / 1 / 0) | Enable | Richtung | Target |
|----------|--------------------------|:------:|----------|--------|
| **PV-Priorität** – Speicher laden (Generation) | `00 0 1` | 1 | Generation | AC |
| **PV-Priorität** – Speicher laden (Consumption) | `00 1 1` | 1 | Consumption | AC |
| **Batterie-Priorität** – Speicher entladen | `01 0 1` | 1 | Generation | Batterie |
| **Batterie-Priorität** – Speicher laden | `01 1 1` | 1 | Consumption | Batterie |
| **Meter** – Entladung mit Smart Meter | `10 0 1` | 1 | Generation | Netz |
| **Meter** – Ladung mit Smart Meter | `10 1 1` | 1 | Consumption | Netz |

### Steuersequenz im Code

`SolakonClient#write_control!` ([solakon_client.rb:101-109](../lib/solakon_client.rb#L101)) schreibt in dieser Reihenfolge:

1. **46609** Minimum SoC — *nur falls abweichend* (Self-Healing, schont Flash).
2. **46001** Remote Control = `0b0001` (Enable, Generation, AC).
3. **46002** Remote Timeout = `150 s` (Watchdog re-arm).
4. **46003** Active-Power-Sollwert (i32, W) — zuletzt.

`release_control!` schreibt `46001 = 0`, damit der Inverter in seinen sicheren Default zurückfällt.
Fällt das Schreiben aus, übernimmt nach 150 s der **geräteseitige Watchdog** als Backstop.

---

*Generiert aus dem PDF v02/26 + Quellcode-Stand 2026-06-20. Bei Protokoll-Updates (neue PDF-Version) diese Datei aktualisieren.*
