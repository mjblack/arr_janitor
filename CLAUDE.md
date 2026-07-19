# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**ArrJanitor** is a Crystal **application** (long-running service). It periodically checks each configured Sonarr/Radarr **download queue** (items queued/downloading/downloaded), inspects the files inside each download for a configurable list of **bad extensions**, and when it finds one it tells the *arr to **delete + blocklist** the download, then — if the episode/movie is **released/aired** — triggers a fresh **search**.

Radarr support comes later; Sonarr first.

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
- `backend/` — `Backend` interface + `SonarrBackend` (via the `sonarr` shard): `queue`, release-status, `delete_and_blocklist`, `search`. Also carries scheduling state: **`next_run : Time?`**, `due?(now = Time.local)` (true when `next_run.nil? || now >= next_run`), and `schedule_next(now = Time.local)` (`next_run = now + interval_span`).
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
- Run: `bin/arr_janitor <config.yml>` (optionally `CRYSTAL_WORKERS=<n>`)
- Format: `crystal tool format` (check: `--check`) · Lint: `bin/ameba` · Specs: `crystal spec` (specs may run without `-Dpreview_mt`)

## Workflow (Gitea)

Repo: **`gitscm.mjbh.net/mblack/arr_janitor`** (remote `origin` = `git@gitscm.mjbh.net:mblack/arr_janitor.git`, SSH). Work is tracked as **Gitea issues** via the `tea` CLI (`tea issues list/create/close --repo mblack/arr_janitor`). Coordinated by a lead + specialized subagents: a subagent implements a unit on a local branch (own worktree), the coordinator reviews the diff and **merges into `master`** (put `closes #N` in the merge commit so Gitea closes the issue on push), then `git push`. `ROADMAP.md` is the higher-level unit map (its numbering predates the Gitea issues).

## Gotchas
- `shard.lock` **is** committed (this is an app).
- Deps are private repos on GitHub — `shards install` needs the `gh` credential helper (HTTPS) configured.
