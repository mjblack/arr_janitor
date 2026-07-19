# ArrJanitor

ArrJanitor is a long-running Crystal service that watches the download queues of
your **Sonarr** instances (Radarr is planned) and cleans up junk downloads
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

One worker fiber runs per configured backend. Each fiber loops and, whenever its
backend is *due* (its poll interval has elapsed), runs a scan:

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
# database: arr_janitor.db       # optional, SQLite persistence path (default arr_janitor.db)
# retention: 30d                 # optional, audit-log retention <int>[m|h|d] (default 30d)

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
| `database`  | no       | `arr_janitor.db` | SQLite persistence path.                          |
| `retention` | no       | `30d`            | Audit-log retention window, `<int>[m\|h\|d]`.     |

Each entry in `backends`:

| Key                 | Required | Default | Notes                                                     |
| ------------------- | -------- | ------- | --------------------------------------------------------- |
| `name`              | yes      | —       | Human-readable label (used in logs).                      |
| `type`              | yes      | —       | `sonarr` or `radarr` (`radarr` is parsed but not yet run).|
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
bin/arr_janitor config.yml          # bare path...
bin/arr_janitor --config config.yml # ...or --config / -c
```

The `-Dpreview_mt` flag enables Crystal's multi-threaded runtime so backend
fibers can run across threads. Tune the number of worker threads with the
`CRYSTAL_WORKERS` environment variable:

```sh
CRYSTAL_WORKERS=4 bin/arr_janitor config.yml
```

The service runs until it receives **SIGINT** or **SIGTERM**, then shuts down
gracefully (workers stop, the log channel drains, the process exits).

## Persistence

State is kept in a SQLite database at `database` (default `arr_janitor.db`),
opened in WAL mode with a busy timeout so the backend fibers can write
concurrently. It holds two tables:

- **`processed_downloads`** — an audit log of every download ArrJanitor has acted
  on (backend, download id, title, action, matched extensions, timestamp). Rows
  older than `retention` are swept away.
- **`download_states`** — per-download bookkeeping (when a download was first
  seen stalled); groundwork for stalled-download handling.

## Logging

Logging uses Crystal's standard `Log` and writes to **stdout** at `Info` level.
File logging is planned. All worker log events are funnelled through a single
channel drained on the main fiber, so output stays ordered under `-Dpreview_mt`.

## Development

```sh
crystal spec              # run the test suite
crystal tool format       # format (add --check to verify in CI)
bin/ameba src/ spec/      # lint
```

Continuous integration lives in [`.gitea/workflows/ci.yml`](.gitea/workflows/ci.yml)
(Gitea Actions). It is **inert until a Gitea Actions runner is registered and a
`GH_TOKEN` secret is defined** for fetching the private `sonarr`/`qbittorrent`
dependencies — see the comments in that file.

## Contributing

Issues and pull requests are tracked in the project's Gitea instance. Please run
the format, lint and spec commands above before opening a PR.

## License

[MIT](LICENSE) © Matthew J. Black
