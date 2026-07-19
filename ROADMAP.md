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
  `search` (command), and download-client config lookup by name. Carries scheduling state:
  **`next_run : Time?`**, `due?(now = Time.local)` (`next_run.nil? || now >= next_run`),
  `schedule_next(now)` (`next_run = now + interval_span`). Depends on #1.
- [ ] **3. Download-client** — resolve a queue item's client (host/port/type from the *arr's
  download-client config, matched by name; creds from config) and connect to qBittorrent
  (via the `qbittorrent` shard) to `files_for(hash)`. Depends on #1.
- [ ] **4. Logging + Janitor core** — `LogEvent` + channel-backed `Reporter` (workers emit) +
  a consumer that drains on the main fiber via Crystal `Log` → stdout. Janitor per-item pipeline:
  list files → match `extensions_filter` → `delete_and_blocklist` → if released, `search`;
  emits via the `Reporter`. Depends on #2, #3.
- [ ] **5. Scheduler + CLI** — **one fiber per backend**; each loops and runs a scan
  **immediately when `due?`** (missed/first run), then `schedule_next`. Workers send
  `LogEvent`s down a `Channel` drained by the **main fiber**. Build/run with **`-Dpreview_mt`**.
  Graceful shutdown (SIGINT/SIGTERM); `arr_janitor.cr` parses the config path and runs. Depends on #4.
- [ ] **6. Tests + Docs + CI** — unit specs (config validation, interval parse, ext matching,
  janitor logic with stubbed backends/clients); README + sample configs; CI/release workflow
  (deferred until a GitHub repo exists — needs a token for the private `qbittorrent.cr` dep).

## Sequencing
#1 first → #2 + #3 in parallel → #4 → #5. Tests/docs alongside. Radarr backend is a
follow-up once the Sonarr path is proven.
