module ArrJanitor
  # A single item in an *arr download queue, in ArrJanitor's own vocabulary so
  # callers never touch the underlying `sonarr`/`radarr` model types.
  struct QueueItem
    # Queue record id — the handle used to delete/blocklist the item.
    getter id : Int32?

    # The download client's identifier for the download (a torrent hash for
    # qBittorrent).
    getter download_id : String?

    # Name of the download client handling this item, as configured in the
    # *arr (used to resolve credentials + connection info).
    getter download_client : String?

    getter title : String?
    getter episode_id : Int32?
    getter series_id : Int32?

    # Queue status (e.g. `"downloading"`, `"completed"`), lower-cased schema
    # value, or `nil` when the *arr didn't report one.
    getter status : String?

    def initialize(@id : Int32? = nil, @download_id : String? = nil,
                   @download_client : String? = nil, @title : String? = nil,
                   @episode_id : Int32? = nil, @series_id : Int32? = nil,
                   @status : String? = nil)
    end
  end

  # Connection details for a download client, resolved from the *arr's own
  # download-client configuration (credentials come separately from
  # ArrJanitor's config).
  struct DownloadClientInfo
    getter name : String

    # The *arr's implementation name, e.g. `"qBittorrent"`.
    getter implementation : String

    getter host : String
    getter port : Int32
    getter? use_ssl : Bool

    # Optional URL base/path prefix the client is served under.
    getter url_base : String?

    def initialize(@name : String, @implementation : String, @host : String,
                   @port : Int32, @use_ssl : Bool, @url_base : String? = nil)
    end

    # The client's base URL: `http(s)://host:port[/urlBase]`.
    def base_url : String
      scheme = use_ssl? ? "https" : "http"
      url = "#{scheme}://#{host}:#{port}"
      if base = url_base
        trimmed = base.strip('/')
        url += "/#{trimmed}" unless trimmed.empty?
      end
      url
    end
  end

  # Abstraction over an *arr instance (Sonarr today, Radarr later). Concrete
  # backends wrap the corresponding client shard; callers work only with the
  # ArrJanitor structs above.
  #
  # A backend also carries its own scheduling state so the scheduler can run one
  # fiber per backend: `next_run` is when the next scan is due, `due?` reports
  # whether it should run now, and `schedule_next` advances it by the configured
  # interval.
  abstract class Backend
    # When the next scan is due; `nil` means "run on the first tick".
    property next_run : Time?

    # Whether a scan should run now: true on the first tick (`next_run` unset)
    # or once the scheduled time has been reached/passed.
    def due?(now = Time.local) : Bool
      run_at = next_run
      run_at.nil? || now >= run_at
    end

    # Advances `next_run` to `now + interval_span`.
    def schedule_next(now = Time.local) : Nil
      @next_run = now + interval_span
    end

    # Poll interval between scans.
    abstract def interval_span : Time::Span

    # Human-readable backend name (from config).
    abstract def name : String

    # The `Config::Backend` this backend was built from. The janitor reads it for
    # the `extensions_filter` matcher and download-client credentials.
    abstract def config : Config::Backend

    # The current download queue.
    abstract def queue : Array(QueueItem)

    # Whether the item's episode/movie has been released (aired/available).
    abstract def released?(item : QueueItem) : Bool

    # Removes the item from its download client and blocklists it in the *arr.
    abstract def delete_and_blocklist(item : QueueItem) : Nil

    # Triggers a fresh search for the item's episode/movie.
    abstract def search(item : QueueItem) : Nil

    # Resolves connection details for the download client named `name`, or `nil`
    # when the *arr has no such client configured.
    abstract def download_client_info(name : String) : DownloadClientInfo?
  end
end
