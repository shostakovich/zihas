# ZiWoAS — Zipfelmaus-Wohnungs-Automatisierungs-system

Heimautomation fürs Mini-Rack. Erstes Feature: Shelly-Monitoring fürs Balkonkraftwerk und Grundverbraucher.

## Quickstart

```bash
cp config/ziwoas.example.yml config/ziwoas.yml
$EDITOR config/ziwoas.yml
mkdir -p data
docker compose up -d
```

Dashboard: <http://localhost:4567>

## Anforderungen

- Shellys mit Gen2+-API (`/rpc/Switch.GetStatus?id=0`) im selben Netz erreichbar
- Docker + docker-compose

## Backup

Die Anwendung erzeugt nachts um 03:30 einen konsistenten SQLite-Snapshot unter `./data/backup/ziwoas-YYYY-MM-DD.db` und hält die letzten 7 Stück. Das `./data`-Verzeichnis kann per restic/rsync offsite gesichert werden.

## Tests

```bash
bundle install
bundle exec rake test
```

## Spec & Plan

- Design: `docs/superpowers/specs/2026-04-13-shelly-monitoring-design.md`
- Plan:   `docs/superpowers/plans/2026-04-13-shelly-monitoring.md`
