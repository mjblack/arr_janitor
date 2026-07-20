require "qbittorrent"

module ArrJanitor
  # Abstraction over a download client (qBittorrent, ...) able to list the file
  # paths contained in a torrent, identified by its hash.
  #
  # Concrete implementations live as nested classes (see `QBittorrent`); build
  # one from a Sonarr/Radarr download-client `implementation` name plus the
  # matched credentials via `.build`.
  abstract class DownloadClient
    # Raised when a download client cannot be constructed (e.g. missing
    # credentials for the chosen implementation) or when listing a torrent's
    # files fails.
    class Error < Exception
    end

    # Raised when the torrent identified by a hash is no longer present in the
    # download client (e.g. qBittorrent answers HTTP 404). Callers can treat this
    # as a benign "already gone" condition and skip the item rather than abort.
    class TorrentNotFound < Error
    end

    # Returns the file paths (each relative to the torrent root) inside the
    # torrent identified by *hash*.
    abstract def files_for(hash : String) : Array(String)

    # Builds a `DownloadClient` for the *arr download-client *implementation*.
    #
    # Only `qbittorrent` (case-insensitive) is supported; it requires both
    # *username* and *password* (its WebUI has no API key) and raises `Error`
    # when either is missing. Returns `nil` for any other implementation so the
    # caller can log and skip it.
    def self.build(implementation : String, base_url : String,
                   api_key : String?, username : String?,
                   password : String?) : DownloadClient?
      case implementation.downcase
      when "qbittorrent"
        if username.nil? || username.blank? || password.nil? || password.blank?
          raise Error.new(
            "qBittorrent download client requires a username and password")
        end
        QBittorrent.new(base_url, username, password)
      end
    end

    # A qBittorrent download client, backed by the `qbittorrent` shard.
    #
    # qBittorrent's WebUI authenticates with username/password (cookie session),
    # not an API key, so this implementation always takes user + pass. Login is
    # performed lazily on the first `files_for` call and the session is reused.
    class QBittorrent < DownloadClient
      @client : ::QBittorrent::Client

      def initialize(@base_url : String, @username : String, @password : String)
        @client = ::QBittorrent::Client.new(@base_url, @username, @password)
      end

      # Lists the file paths inside the torrent *hash*. Ensures a session (the
      # underlying client logs in on demand) and maps each returned
      # `TorrentFile` to its `name`, dropping any nil entries.
      #
      # Translates qBittorrent API failures into this abstraction's own error
      # types so callers never need to know about `::QBittorrent::ApiError`: a
      # 404 (torrent no longer in the client) becomes `TorrentNotFound`, any
      # other non-2xx becomes `Error`.
      def files_for(hash : String) : Array(String)
        @client.login unless @client.logged_in?
        files = ::QBittorrent::Api::Torrents.new(@client).files(hash)
        self.class.extract_paths(files)
      rescue ex : ::QBittorrent::ApiError
        raise self.class.translate_api_error(hash, ex)
      end

      # Maps a `::QBittorrent::ApiError` onto this abstraction's error types:
      # HTTP 404 (torrent no longer present) becomes `TorrentNotFound`; any other
      # non-2xx becomes a generic `Error` carrying the original as its cause.
      # Pure (no I/O) so the translation is unit-testable without a live server.
      def self.translate_api_error(hash : String, ex : ::QBittorrent::ApiError) : Error
        if ex.status_code == 404
          TorrentNotFound.new("torrent #{hash} not found in qBittorrent (HTTP 404)", cause: ex)
        else
          Error.new(ex.message || "qBittorrent API error", cause: ex)
        end
      end

      # Extracts the file paths from a list of qBittorrent `TorrentFile`s,
      # dropping entries whose `name` is nil. Pure (no I/O) so it is
      # unit-testable without a live server.
      def self.extract_paths(files : Array(::QBittorrent::Model::TorrentFile)) : Array(String)
        files.compact_map(&.name)
      end
    end
  end
end
