# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-07-20

### Added

- **Radarr backend** — a `RadarrBackend` (via the `radarr` shard) giving Radarr
  the same treatment as Sonarr: page through the movie-based download queue,
  determine movie release status via Radarr's `isAvailable` flag,
  `delete_and_blocklist` (queue delete with remove-from-client + blocklist),
  `search` (the `MoviesSearch` command), and download-client lookup by name.
  Configure it with `type: radarr` — the same config shape as a Sonarr backend.

### Changed

- **CI/release moved to GitHub Actions** — the repo is now public on
  `github.com/mjblack/arr_janitor` with both runtime dependencies public, so the
  Gitea workflows and their token/internal-CA machinery were dropped in favour of
  clean `.github/workflows/{ci.yml,release.yml}`. The release workflow now
  publishes the container image to **`ghcr.io/mjblack/arr_janitor`** and creates
  the GitHub release.

## [0.1.0] - 2026-07-19

### Added

- **Configuration** — `Config`/`Backend`/`DownloadClient` models
  (`YAML::Serializable` + `JSON::Serializable`) loaded from YAML or JSON (YAML
  wins). Interval parsing (`<int>[m|h|d]`, default 20m), a bad-extension matcher
  (bare extensions and globs), and fail-fast validation of all required fields,
  the backend `type`, and download-client credentials.
- **Sonarr backend** — a `Backend` interface and `SonarrBackend` (via the
  `sonarr` shard): fetch the download queue, determine episode release status,
  `delete_and_blocklist` (queue delete with remove-from-client + blocklist),
  `search` (command), and download-client lookup by name. Carries its own
  scheduling state (`next_run`, `due?`, `schedule_next`).
- **Download client** — resolve a queue item's client (host/port/type from the
  *arr, matched by name; credentials from config) and connect to qBittorrent (via
  the `qbittorrent` shard) to list a torrent's files by hash.
- **Logging** — a channel-backed `Reporter` that worker fibers emit `LogEvent`s
  through, drained on the main fiber and written via Crystal's `Log` to stdout so
  output stays ordered under `-Dpreview_mt`.
- **Janitor pipeline** — per-item processing: list files → match
  `extensions_filter` → `delete_and_blocklist` → re-`search` when released;
  resilient to per-item failures.
- **Scheduler + CLI** — one fiber per backend, each running a scan immediately
  when due then rescheduling; multi-threaded via `-Dpreview_mt`. CLI takes the
  config path (bare or `--config`/`-c`) and shuts down gracefully on
  SIGINT/SIGTERM.
- **Persistence** — a SQLite-backed `Store` (WAL mode + busy timeout) with
  `processed_downloads` (audit log, retention-swept) and `download_states`
  tables, plus `database`/`retention` config options.
- **Run modes** — `-d`/`--daemon` runs the scheduler continuously (one fiber per
  backend, retention sweep, graceful SIGINT/SIGTERM shutdown); without it the app
  makes a single scan pass over every backend and exits.
- **Dry run** — `--dry-run`/`-n` (or `dry_run: true` in config) logs intended
  deletes/blocklists/searches without mutating Sonarr/qBittorrent **and without
  writing to the store**.
- **Docker + release** — a multi-stage `Dockerfile` (`crystallang/crystal:1.20.2`
  builder → `debian:12-slim` runtime, non-root, `-Dpreview_mt --release`, private
  deps via a BuildKit secret, daemon by default), a `.dockerignore`, a
  `docker-compose.yml` example, and a manually triggered, CI-gated
  `.gitea/workflows/release.yml` that checks version consistency, builds/pushes
  the image to the Gitea registry, and creates the `v<version>` tag + release.

### Notes

- Targets the `sonarr` and `qbittorrent` Crystal shards.
- File logging is planned.

[Unreleased]: https://github.com/mjblack/arr_janitor/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/mjblack/arr_janitor/releases/tag/v0.2.0
[0.1.0]: https://github.com/mjblack/arr_janitor/releases/tag/v0.1.0
