# ArrJanitor — Roadmap

Work tracking (this repo is local-only, so this file stands in for GitHub issues).
Each unit lands on its own local branch, is reviewed, and merged into `master`.

## Units

- [x] **1. Config** — `Config`/`Backend`/`DownloadClient` models (`YAML::Serializable` +
  `JSON::Serializable`), load-from-YAML-or-JSON (YAML priority), `interval` `<int>[m|h|d]`
  → `Time::Span` (default 20m), extension matcher (bare ext + glob), and `#validate`
  (required fields; `type` enum; download-client `api_key` XOR `username`+`password`).
  Sample `config.example.yml`. *(foundational)*
- [ ] **2. Sonarr backend** — `Backend` interface + `SonarrBackend` (via the `sonarr` shard):
  fetch queue (with `downloadId`/`downloadClient`/episode), episode **release status**
  (aired + monitored), `delete_and_blocklist` (queue delete w/ `removeFromClient`+`blocklist`),
  `search` (command). Depends on #1.
- [ ] **3. Download-client** — resolve a queue item's client (host/port/type from the *arr's
  download-client config, matched by name; creds from config) and connect to qBittorrent
  (via the `qbittorrent` shard) to `files_for(hash)`. Depends on #1.
- [ ] **4. Janitor core** — per-item pipeline: list files → match `extensions_filter` →
  `delete_and_blocklist` → if released, `search`. Structured logging. Depends on #2, #3.
- [ ] **5. Scheduler + CLI** — one fiber per backend on its interval; graceful shutdown
  (SIGINT/SIGTERM); `arr_janitor.cr` entrypoint parses the config path and runs. Depends on #4.
- [ ] **6. Tests + Docs + CI** — unit specs (config validation, interval parse, ext matching,
  janitor logic with stubbed backends/clients); README + sample configs; CI/release workflow
  (deferred until a GitHub repo exists — needs a token for the private `qbittorrent.cr` dep).

## Sequencing
#1 first → #2 + #3 in parallel → #4 → #5. Tests/docs alongside. Radarr backend is a
follow-up once the Sonarr path is proven.
