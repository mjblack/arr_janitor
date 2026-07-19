require "db"
require "sqlite3"

module ArrJanitor
  # SQLite-backed persistence for ArrJanitor.
  #
  # Tracks two things:
  #
  # * `processed_downloads` — an audit log of every download ArrJanitor has
  #   acted on (for retention/reporting), swept on a TTL.
  # * `download_states` — per-download stalled bookkeeping (groundwork for the
  #   stalled-download handling in #9): when a download was *first* seen stalled.
  #
  # A single `Store` (and its underlying `DB::Database` connection pool) is
  # meant to be shared across all backend fibers. Under `-Dpreview_mt` several
  # fibers may write concurrently; the database is opened in **WAL** mode with a
  # **busy_timeout** so concurrent writers block-and-retry instead of failing
  # with `SQLITE_BUSY`. Do not open a `Store` per call — reuse the shared one.
  class Store
    # How long a writer waits for a competing writer's lock before giving up.
    BUSY_TIMEOUT = 5.seconds

    # Opens (creating if necessary) the SQLite database at `path`, enables WAL
    # mode + a busy timeout, runs the schema migrations, and returns a ready
    # `Store`. The `path` is a plain filesystem path (not a `sqlite3://` URI).
    #
    # The pragmas are passed as URI query parameters so crystal-sqlite3 applies
    # them to **every** connection the pool opens (the driver runs the URI
    # pragmas in each new connection's `initialize`). Setting `busy_timeout`
    # via a post-open `@db.exec` would only configure the single pooled
    # connection that happened to run it — other connections (created lazily
    # under `-Dpreview_mt`) would default to `busy_timeout=0` and raise
    # `SQLITE_BUSY` immediately instead of blocking-and-retrying. `journal_mode`
    # is a persistent file-level setting, but is set via the URI too for
    # good measure.
    #
    # NOTE: `path` is interpolated into the URI unescaped. Paths are local
    # filenames so this is fine in practice; a path containing URI-significant
    # characters (e.g. `?` or `#`) would need escaping.
    def self.open(path : String) : Store
      millis = BUSY_TIMEOUT.total_milliseconds.to_i
      database = DB.open("sqlite3://#{path}?journal_mode=wal&busy_timeout=#{millis}")
      store = new(database)
      store.migrate
      store
    end

    # Wraps an already-open `DB::Database`. Prefer `Store.open`.
    def initialize(@db : DB::Database)
    end

    # Creates the schema if absent. Idempotent — safe to call on every open.
    def migrate : Nil
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS processed_downloads (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          backend TEXT NOT NULL,
          download_id TEXT NOT NULL,
          title TEXT,
          action TEXT NOT NULL,
          matched_extensions TEXT,
          created_at INTEGER NOT NULL
        )
        SQL

      @db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_processed_backend_download
          ON processed_downloads (backend, download_id)
        SQL

      @db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_processed_created_at
          ON processed_downloads (created_at)
        SQL

      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS download_states (
          backend TEXT NOT NULL,
          download_id TEXT NOT NULL,
          first_seen_stalled TEXT,
          updated_at TEXT NOT NULL,
          PRIMARY KEY (backend, download_id)
        )
        SQL
    end

    # Records that ArrJanitor took `action` on the download identified by
    # (`backend`, `download_id`). `matched_extensions` is the set of bad
    # extensions/paths that triggered the action; it is stored comma-joined.
    # `created_at` defaults to now; it is a parameter so callers (and tests)
    # can backdate rows through the public API.
    def record_processed(backend : String, download_id : String, title : String?,
                         action : String, matched_extensions : Enumerable(String),
                         created_at : Time = Time.utc) : Nil
      @db.exec(
        "INSERT INTO processed_downloads " \
        "(backend, download_id, title, action, matched_extensions, created_at) " \
        "VALUES (?, ?, ?, ?, ?, ?)",
        backend, download_id, title, action,
        matched_extensions.join(","), created_at.to_unix)
    end

    # Whether a download identified by (`backend`, `download_id`) has already
    # been recorded in `processed_downloads`.
    def processed?(backend : String, download_id : String) : Bool
      count = @db.scalar(
        "SELECT COUNT(*) FROM processed_downloads WHERE backend = ? AND download_id = ?",
        backend, download_id).as(Int64)
      count > 0
    end

    # Deletes `processed_downloads` rows older than `older_than` (relative to
    # now) and returns the number of rows removed.
    def sweep(older_than : Time::Span) : Int64
      cutoff = (Time.utc - older_than).to_unix
      result = @db.exec("DELETE FROM processed_downloads WHERE created_at < ?", cutoff)
      result.rows_affected
    end

    # Marks (`backend`, `download_id`) as stalled, recording `now` as the
    # first-seen-stalled time the *first* time it is called. Subsequent calls
    # leave the original first-seen time untouched (only `updated_at` moves).
    def mark_stalled(backend : String, download_id : String, now = Time.utc) : Nil
      timestamp = now.to_utc.to_rfc3339
      @db.exec(
        "INSERT INTO download_states (backend, download_id, first_seen_stalled, updated_at) " \
        "VALUES (?, ?, ?, ?) " \
        "ON CONFLICT (backend, download_id) DO UPDATE SET updated_at = excluded.updated_at",
        backend, download_id, timestamp, timestamp)
    end

    # The time (`backend`, `download_id`) was first seen stalled, or `nil` when
    # it has no recorded stalled state.
    def first_seen_stalled(backend : String, download_id : String) : Time?
      raw = @db.query_one?(
        "SELECT first_seen_stalled FROM download_states WHERE backend = ? AND download_id = ?",
        backend, download_id, as: String?)
      return nil if raw.nil?
      Time.parse_rfc3339(raw).to_utc
    end

    # Clears any stored stalled state for (`backend`, `download_id`).
    def clear_state(backend : String, download_id : String) : Nil
      @db.exec("DELETE FROM download_states WHERE backend = ? AND download_id = ?",
        backend, download_id)
    end

    # Closes the underlying database (flushing the WAL). Idempotent-safe to call
    # once at shutdown.
    def close : Nil
      @db.close
    end
  end
end
