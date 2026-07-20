# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**ArrJanitor** is a Crystal **application** (long-running service). It periodically checks each configured Sonarr/Radarr **download queue** (items queued/downloading/downloaded), inspects the files inside each download for a configurable list of **bad extensions**, and when it finds one it tells the *arr to **delete + blocklist** the download, then — if the episode/movie is **released/aired** — triggers a fresh **search**.

Both Sonarr and Radarr are supported (via the `sonarr` and `radarr` shards); they share the same config shape, selected per backend by `type: sonarr` / `type: radarr`.

## Dependencies (reuse our own shards)

- **`sonarr`** (`github: mjblack/sonarr`, 0.2.0) — the *arr client (queue, episodes/release status, queue delete+blocklist, command/search).
- **`qbittorrent`** (`github: mjblack/qbittorrent.cr`, 0.2.0) — download-client client, used to list a torrent's files by hash.
- `ameba` (dev) for lint. Crystal `>= 1.20.2`.

The download client's **host/port/type** come from the *arr's own download-client config (matched by `name`); the **credentials** come from ArrJanitor's config. Only **qBittorrent** download clients are supported initially.

## Configuration

YAML **or** JSON (both supported; **YAML wins** — try YAML first, JSON fallback; pick by file extension when unambiguous). Top key `backends` (array). Example:

```yaml
backends:
  - name: My Sonarr
    type: sonarr                 # sonarr | radarr
    url: http://localhost:8080
    api_key: "12355677757"
    interval: 30m                # optional, <int>[m|h|d], default 20m
    extensions_filter:           # bare ext (scr → *.scr) OR glob ("*.lnk")
      - scr
      - exe
      - bat
      - "*.lnk"
    download_clients:
      - name: My qbittorrent     # matches the client name in Sonarr/Radarr
        username: admin          # api_key XOR (username + password)
        password: password
        # api_key: "..."         # alternative to username/password
```

**Validation** (fail fast at startup): backend `name`/`type`/`url`/`api_key` present; `type` ∈ {sonarr, radarr}; `interval` matches `<int>[m|h|d]` if given; `extensions_filter` non-empty; ≥1 download client; each download client has a `name` and **either `api_key` or (`username` AND `password`)**.

**Extension matching:** an entry containing a glob metachar (`*`, `?`, `[`) is matched as a glob against the file's basename (case-insensitive); otherwise it's an extension, matching files whose name ends with `.<entry>` (case-insensitive; a leading `.` is tolerated).

## Architecture (`src/arr_janitor/`, built incrementally)

- `config.cr` — `Config`/`Backend`/`DownloadClient` (`YAML::Serializable` + `JSON::Serializable`), loading, interval parsing, extension matcher, validation.
- `backend/` — `Backend` interface + `SonarrBackend` (via the `sonarr` shard) and `RadarrBackend` (via the `radarr` shard): `queue`, release-status, `delete_and_blocklist`, `search`. Also carries scheduling state: **`next_run : Time?`**, `due?(now = Time.local)` (true when `next_run.nil? || now >= next_run`), and `schedule_next(now = Time.local)` (`next_run = now + interval_span`).
- `download_client/` — resolve + connect to qBittorrent (via the `qbittorrent` shard), `files_for(hash)`.
- `logging` — `LogEvent` + a channel-backed `Reporter` (workers emit events) + a consumer that drains the channel on the **main fiber** and writes via Crystal's `Log`.
- `janitor.cr` — per-item pipeline: files → bad-ext match → delete+blocklist → (if released) search; emits via the `Reporter`.
- `scheduler.cr` + `arr_janitor.cr` — **one fiber per backend**; each loops, and when the backend is `due?` runs a scan and calls `schedule_next`; workers send log messages down a `Channel(LogEvent)` that the **main fiber consumes**. Graceful shutdown (SIGINT/SIGTERM); CLI takes the config path.

### Runtime
- A backend runs **immediately** whenever it's `due?` — i.e. on first tick (`next_run` nil) or once a scheduled run has been missed (`Time.local >= next_run`) — no extra delay before the catch-up run.
- Built/run with **`-Dpreview_mt`** (multi-threaded scheduler) so backend fibers can run across threads. Logging is funneled through a single `Channel(LogEvent)` drained by the main fiber, so console output stays ordered/serialized across threads.
- Logging uses Crystal's **`Log`** to **stdout** for now (file logging is a planned addition) — the consumer maps each `LogEvent` to `Log.for(source).<severity>`.

## Commands

- Install deps: `shards install`
- Build (multi-threaded): `shards build -Dpreview_mt` (binary in `bin/arr_janitor`) or `crystal build -Dpreview_mt src/arr_janitor.cr`
- Run: `bin/arr_janitor [<config.yml>|-c <path>] [-D <db>] [-d] [-n]` — config path defaults to `./config.yml` (bare positional or `-c`/`--config`); `-D`/`--database` sets the SQLite path (overrides config `database:`, else `./arr_janitor.db`); `-d`/`--daemon` runs the continuous scheduler (default: one scan pass then exit); `-n`/`--dry-run` logs intended actions only; `-h`/`--help` prints usage. Note `-d` (daemon, no value) vs `-D` (database, takes a value). Optionally `CRYSTAL_WORKERS=<n>`.
- Format: `crystal tool format` (check: `--check`) · Lint: `bin/ameba` · Specs: `crystal spec` (specs may run without `-Dpreview_mt`)

## Workflow (GitHub, PR-based)

Repo: **`github.com/mjblack/arr_janitor`** (PUBLIC; remote `origin` = GitHub, a `gitea` remote is kept for reference). Work is tracked as **GitHub issues** via the `gh` CLI (`gh issue|pr list/create/merge --repo mjblack/arr_janitor`).

Flow per unit:
1. A subagent implements the unit on a **feature branch** in its own worktree and commits (no push).
2. The coordinator **pushes the branch** (`git push -u origin <branch>`) and opens a **PR** (`gh pr create --head <branch> --base master --title … --body …`).
3. **pr-reviewer** reviews the diff.
4. Coordinator **squash-merges** (`gh pr merge <n> --squash`) with `closes #<issue>` so GitHub closes the issue, then `git fetch` + fast-forward local `master`.

`ROADMAP.md` is the higher-level unit map (its numbering predates the issues).

## Releases

The version lives in **two** places that must always agree: `version:` in
`shard.yml` and `ArrJanitor::VERSION` in `src/arr_janitor.cr`. Keep them in sync.

Release is driven by **`.github/workflows/release.yml`**, a **manually triggered**
(`workflow_dispatch`) GitHub Actions workflow that mirrors the sonarr model: it is
**CI-gated** (a `test` job replicates `ci.yml`), then a `release` job asserts the
two version locations match, **builds and pushes** the container image to GHCR
(`ghcr.io/mjblack/arr_janitor:<version>` and `:latest`), and **creates the
`v<version>` tag + a GitHub release** (`gh release create --generate-notes`).
Never tag/release by hand — bump both version locations (+ CHANGELOG) via a PR,
merge to `master`, then trigger the workflow (`gh workflow run release.yml`).

### Docker
- **`Dockerfile`** — multi-stage (`crystallang/crystal:1.20.2` builder →
  `debian:12-slim` runtime), builds the binary `-Dpreview_mt --release`,
  `VOLUME [/config, /data]`. Default CMD passes the paths explicitly and runs in
  **daemon mode**: `--config /config/config.yml --database /data/arr_janitor.db
  --daemon`, so the DB persists in the mounted `/data` volume with no config
  changes needed. Both deps are public, so `shards install --production` runs
  with no token or BuildKit secret.
- **`docker-entrypoint.sh`** — runs as root only to `chown /data` to
  `PUID`/`PGID` (default 1000:1000), then drops to that user via `gosu` and execs
  `arr_janitor`. Fixes root-owned bind-mounted `./data` (created by the docker
  daemon on `docker compose up`) so the non-root app can write the DB. `/config`
  is read-only and untouched.
- **`.dockerignore`** keeps the build context lean (but keeps `shard.yml`,
  `shard.lock`, `src/`).
- **`docker-compose.yml`** — user-facing example running the published image;
  the image's default CMD already writes the DB to `/data`, so no config change
  is needed to persist it.

## Gotchas
- `shard.lock` **is** committed (this is an app).
- Both deps (`mjblack/sonarr`, `mjblack/qbittorrent.cr`) are **public** GitHub repos — `shards install` needs no token or credential helper.
