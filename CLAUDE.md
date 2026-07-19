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
- `backend/` — `Backend` interface + `SonarrBackend` (via the `sonarr` shard): `queue`, release-status, `delete_and_blocklist`, `search`.
- `download_client/` — resolve + connect to qBittorrent (via the `qbittorrent` shard), `files_for(hash)`.
- `janitor.cr` — per-item pipeline: files → bad-ext match → delete+blocklist → (if released) search.
- `scheduler.cr` + `arr_janitor.cr` — one fiber per backend on its interval; graceful shutdown (SIGINT/SIGTERM); CLI takes the config path.

## Commands

- Install deps: `shards install`
- Build: `shards build` (binary in `bin/arr_janitor`) or `crystal build src/arr_janitor.cr`
- Run: `bin/arr_janitor <config.yml>`
- Format: `crystal tool format` (check: `--check`) · Lint: `bin/ameba` · Specs: `crystal spec`

## Workflow (local-only for now — no GitHub repo yet)

Coordinated by a lead + specialized subagents. **No GitHub issues/PRs**: work is tracked in `ROADMAP.md`; subagents work on **local branches** (own worktree in this repo), the coordinator reviews the diff (pr-reviewer) and **merges locally** into `master`. When this goes to a GitHub repo, add CI (needs a token for the private `qbittorrent.cr` dep) + the release workflow, and switch to PRs.

## Gotchas
- `shard.lock` **is** committed (this is an app).
- Deps are private repos on GitHub — `shards install` needs the `gh` credential helper (HTTPS) configured.
