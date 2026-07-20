# ArrJanitor

ArrJanitor is a long-running Crystal service that watches the download queues of
your **Sonarr** and **Radarr** instances and cleans up junk downloads
automatically.

For every queued/downloading/downloaded item it inspects the files inside the
torrent (via the download client) and, when it finds a **bad file extension**
(e.g. a `.scr`/`.exe`/`.lnk` decoy), it tells the *arr to:

1. **delete + blocklist** the download (remove it from the client and blocklist
   the release so it isn't grabbed again), and
2. if the episode has already **aired/been released**, **re-trigger a search** so
   the *arr grabs a legitimate replacement.

Every action is recorded to a local SQLite database for auditing.

## How it works

By default ArrJanitor makes a single scan pass over every backend and exits; with
`-d`/`--daemon` it runs continuously (see [Run modes](#run-modes)). Either way,
one worker fiber runs per configured backend, and when a backend is *due* it runs
a scan:

```
queue → for each item:
  resolve its download client (host/type from the *arr, creds from config)
  list the torrent's files by hash
  match each file against extensions_filter
    → any match:  delete_and_blocklist  → (if released) search  → record to SQLite
    → no match:   leave it alone
```

Workers never write logs directly; they emit log events onto a channel that the
main fiber drains, so console output stays ordered across threads.

## Configuration

ArrJanitor is configured from a single file in **YAML or JSON**. Copy one of the
samples in this repo to get started:

- [`config.example.yml`](config.example.yml)
- [`config.example.json`](config.example.json)

```yaml
# database: arr_janitor.db       # optional, SQLite persistence path (default ./arr_janitor.db; overridden by --database/-D)
# retention: 30d                 # optional, audit-log retention <int>[m|h|d] (default 30d)
# log_level: info                # optional, trace|debug|info|notice|warn|error|fatal|none (default info)

backends:
  - name: My Sonarr
    type: sonarr                 # sonarr | radarr
    url: http://localhost:8080
    api_key: "12355677757"
    interval: 30m                # optional, <int>[m|h|d], default 20m
    extensions_filter:           # bare ext (scr -> *.scr) OR glob ("*.lnk")
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

### Schema

Top level:

| Key         | Required | Default          | Notes                                             |
| ----------- | -------- | ---------------- | ------------------------------------------------- |
| `backends`  | yes      | —                | Array of *arr instances to watch (at least one).  |
| `database`  | no       | `arr_janitor.db` | SQLite persistence path. Overridden by `--database`/`-D`. |
| `retention` | no       | `30d`            | Audit-log retention window, `<int>[m\|h\|d]`.     |
| `log_level` | no       | `info`           | Log verbosity. One of `trace`, `debug`, `info`, `notice`, `warn`, `error`, `fatal`, `none` (case-insensitive). Overridden by `--log-level`/`-l` and `ARR_JANITOR_LOG_LEVEL`. |

Each entry in `backends`:

| Key                 | Required | Default | Notes                                                     |
| ------------------- | -------- | ------- | --------------------------------------------------------- |
| `name`              | yes      | —       | Human-readable label (used in logs).                      |
| `type`              | yes      | —       | `sonarr` or `radarr`.                                     |
| `url`               | yes      | —       | Base URL of the *arr instance.                            |
| `api_key`           | yes      | —       | The *arr API key.                                         |
| `interval`          | no       | `20m`   | Poll interval, `<int>[m\|h\|d]`.                          |
| `extensions_filter` | yes      | —       | Non-empty list of bad-extension rules (see below).        |
| `download_clients`  | yes      | —       | At least one; supplies credentials (see below).           |

Each entry in `download_clients`:

| Key        | Required | Notes                                                                 |
| ---------- | -------- | --------------------------------------------------------------------- |
| `name`     | yes      | Must match the download client's name in the *arr.                    |
| `api_key`  | *        | Provide **either** `api_key` **or** both `username` and `password`.   |
| `username` | *        | qBittorrent authenticates with username/password (no API key).        |
| `password` | *        | Paired with `username`.                                               |

The download client's **host, port and type** are read from the *arr's own
download-client configuration (matched by `name`); only the **credentials** live
in this config. Only **qBittorrent** clients are supported initially, and it
requires `username` + `password`.

The config is validated at startup and the process exits non-zero with a list of
all problems if anything is wrong (missing required fields, unknown `type`, a
malformed `interval`, an empty `extensions_filter`, no download clients, or a
download client missing credentials).

### Extension matching

Each `extensions_filter` entry is matched (case-insensitively) against a file's
basename:

- An entry containing a glob metacharacter (`*`, `?`, `[`) is matched as a
  **glob** against the basename, e.g. `*.lnk` or `payload.??` .
- Otherwise it is treated as a bare **extension**, matching files that end in
  `.<entry>`. A leading dot is tolerated, so `scr` and `.scr` behave the same.

### File format precedence

`.yml`/`.yaml` files parse as YAML and `.json` files as JSON. For any other
extension ArrJanitor tries **YAML first, then JSON** (YAML wins).

## Build & run

Requires Crystal `>= 1.20.2` and `libsqlite3` (the `crystal-sqlite3` shard needs
the SQLite dev headers to build — e.g. `apt-get install libsqlite3-dev`).

```sh
shards install
shards build -Dpreview_mt           # produces bin/arr_janitor
bin/arr_janitor                     # defaults to ./config.yml
bin/arr_janitor config.yml          # bare path...
bin/arr_janitor --config config.yml # ...or --config / -c
```

### CLI flags

| Flag                  | Default            | Notes                                                                 |
| --------------------- | ------------------ | --------------------------------------------------------------------- |
| `-c`, `--config <path>` | `./config.yml`   | Config file to load. Also accepted as a bare positional argument.     |
| `-D`, `--database <path>` | config `database:`, else `./arr_janitor.db` | SQLite database path. **Overrides** the config's `database:` value. |
| `-l`, `--log-level <level>` | env `ARR_JANITOR_LOG_LEVEL`, else config `log_level:`, else `info` | Log verbosity: `trace`, `debug`, `info`, `notice`, `warn`, `error`, `fatal`, `none` (case-insensitive). See [Logging](#logging). |
| `-d`, `--daemon`      | off                | Run continuously (see [Run modes](#run-modes)) instead of a single pass. |
| `-n`, `--dry-run`     | off                | Log intended actions without mutating anything or writing the store.  |
| `-h`, `--help`        | —                  | Print usage and exit `0`.                                             |

Both paths **default to the current working directory** (`./config.yml` and
`./arr_janitor.db`). The database path resolves with the precedence
**`--database`/`-D` > config `database:` > `./arr_janitor.db`**.

> Note the case: `-d` is `--daemon` (a flag, no value) while `-D` is
> `--database` (takes a path value). They are distinct.

### Run modes

By **default** ArrJanitor runs **once**: it makes a single scan pass over every
configured backend and then exits `0` — no interval loop, no waiting. This suits
cron jobs, systemd timers, or one-off invocations.

Pass **`-d`** / **`--daemon`** to run **continuously** instead: one worker fiber
per backend loops on each backend's poll interval, a retention-sweep fiber ages
out old audit rows, and the process runs until it receives **SIGINT** or
**SIGTERM**, then shuts down gracefully (workers stop, the log channel drains,
the process exits).

```sh
bin/arr_janitor config.yml          # run once, then exit
bin/arr_janitor config.yml -d       # run continuously (daemon)
```

The `-Dpreview_mt` flag enables Crystal's multi-threaded runtime so backend
fibers can run across threads. Tune the number of worker threads with the
`CRYSTAL_WORKERS` environment variable:

```sh
CRYSTAL_WORKERS=4 bin/arr_janitor config.yml -d
```

## Docker

A multi-stage [`Dockerfile`](Dockerfile) builds a slim `debian:12-slim` runtime
image with a release binary (compiled `-Dpreview_mt`) that runs as a non-root
user. The container runs in **daemon mode by default**.

### Build locally

Both `sonarr`/`qbittorrent.cr` dependencies are public GitHub repos, so the
build fetches them over HTTPS with no token or secret:

```sh
docker build -t arr_janitor .
```

### Run

Mount your config read-only and a writable data volume:

```sh
docker run --rm \
  -v ./config.yml:/config/config.yml:ro \
  -v ./data:/data \
  -e PUID=$(id -u) -e PGID=$(id -g) \
  -e CRYSTAL_WORKERS=4 \
  arr_janitor
```

**Volume permissions (`PUID`/`PGID`).** The container's entrypoint runs as root
only to `chown` the mounted `/data` to `PUID:PGID` (default `1000:1000`), then
drops to that user via `gosu`. This fixes the common case where `docker compose
up` / `docker run` creates a **root-owned** `./data` that the non-root app can't
write (which otherwise shows up as a "cannot open the database" error). Set
`PUID`/`PGID` to your host user (`id -u` / `id -g`) so the mount stays writable
and the DB files are owned by you. `/config` is read-only and left untouched.

The default `CMD` runs
`arr_janitor --config /config/config.yml --database /data/arr_janitor.db --daemon`
(continuous). Because the paths are passed explicitly, the SQLite database lands
on the mounted `/data` volume and survives container restarts **with no config
changes needed**. For a **one-shot** run (single scan pass, then exit), override
the command and drop `--daemon`:

```sh
docker run --rm \
  -v ./config.yml:/config/config.yml:ro \
  -v ./data:/data \
  arr_janitor --config /config/config.yml --database /data/arr_janitor.db
```

### docker-compose

A ready-to-use [`docker-compose.yml`](docker-compose.yml) runs the published
image:

```yaml
services:
  arr-janitor:
    image: ghcr.io/mjblack/arr_janitor:latest
    restart: unless-stopped
    volumes:
      - ./config.yml:/config/config.yml:ro
      - ./data:/data
    environment:
      - CRYSTAL_WORKERS=4
```

## Persistence

State is kept in a SQLite database at the resolved database path (`--database`/`-D`
override, else the config's `database:`, else `./arr_janitor.db`), opened in WAL
mode with a busy timeout so the backend fibers can write concurrently. It holds
two tables:

- **`processed_downloads`** — an audit log of every download ArrJanitor has acted
  on (backend, download id, title, action, matched extensions, timestamp). Rows
  older than `retention` are swept away.
- **`download_states`** — per-download bookkeeping (when a download was first
  seen stalled); groundwork for stalled-download handling.

## Logging

Logging uses Crystal's standard `Log` and writes to **stdout**. File logging is
planned. All worker log events are funnelled through a single channel drained on
the main fiber, so output stays ordered under `-Dpreview_mt`.

The **log level** is configurable from three sources, resolved with this
precedence (highest first):

1. `-l` / `--log-level <level>` — the CLI flag.
2. `ARR_JANITOR_LOG_LEVEL` — an environment variable.
3. `log_level:` — the config file.
4. Default: `info`.

Valid levels (case-insensitive) are `trace`, `debug`, `info`, `notice`, `warn`,
`error`, `fatal`, and `none`. An invalid value from **any** source fails fast
with a clear error listing the valid levels rather than silently falling back.

```sh
bin/arr_janitor -l debug config.yml          # via the flag
ARR_JANITOR_LOG_LEVEL=warn bin/arr_janitor   # via the environment
```

## Development

```sh
crystal spec              # run the test suite
crystal tool format       # format (add --check to verify in CI)
bin/ameba src/ spec/      # lint
```

Continuous integration lives in [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
(GitHub Actions): it installs Crystal and the public `sonarr`/`qbittorrent`
dependencies, checks formatting, lints, builds, and runs the spec suite on every
pull request and every push to `master`.

## Contributing

Issues and pull requests are tracked on GitHub at
[`github.com/mjblack/arr_janitor`](https://github.com/mjblack/arr_janitor).
Please run the format, lint and spec commands above before opening a PR.

## License

[MIT](LICENSE) © Matthew J. Black
