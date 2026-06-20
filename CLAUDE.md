# CLAUDE.md – ZiWoAS

## Solakon ONE Modbus

Die vollständige Modbus-Register-Referenz für den Solakon ONE (alle Register, Faktoren,
Alarme, Netzcodes, Ansteuerung) steht in [`docs/solakon-modbus-protokoll.md`](docs/solakon-modbus-protokoll.md).
**Dort nachschlagen statt das PDF neu zu parsen.** Die Datei verschneidet das offizielle
PDF „Solakon ONE Modbus Protokoll v.02/26" mit unserer Nutzung in [`lib/solakon_client.rb`](lib/solakon_client.rb)
und enthält eine Cross-Reference-Tabelle (welche Register wir lesen/schreiben) sowie die bekannten
Abweichungen zwischen Code und PDF.
