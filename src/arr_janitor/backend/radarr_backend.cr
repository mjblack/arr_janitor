require "radarr"

module ArrJanitor
  # `Backend` backed by the `radarr` shard. Wraps a `Radarr::Client` built from
  # a `Config::Backend` and maps Radarr's models onto ArrJanitor's structs.
  #
  # Mirrors `SonarrBackend`, adapted to Radarr's movie domain: the queue is
  # movie-based (`movieId`), "released" means the movie is *available*, and the
  # re-search command is `MoviesSearch`.
  #
  # Network errors are not swallowed: any failed Radarr request raises
  # (`Radarr::ApiError`) for the scheduler/janitor to log.
  class RadarrBackend < Backend
    # Page size used when walking the (paged) queue endpoint.
    QUEUE_PAGE_SIZE = 100

    # The `Config::Backend` this backend was built from.
    getter config : Config::Backend

    def initialize(@config : Config::Backend)
      @client = Radarr::Client.new(@config.url, @config.api_key)
    end

    def interval_span : Time::Span
      @config.interval_span
    end

    def name : String
      @config.name
    end

    # Fetches the full queue, following paging until every record is collected.
    def queue : Array(QueueItem)
      api = Radarr::Api::Queue.new(@client)
      items = [] of QueueItem
      page = 1

      loop do
        resource = api.list(page: page, page_size: QUEUE_PAGE_SIZE, include_movie: true)
        break if resource.nil?

        records = resource.records
        records.each { |record| items << RadarrBackend.map_queue_item(record) }

        total = resource.total_records
        break if records.empty?
        break if total && items.size >= total
        break if records.size < QUEUE_PAGE_SIZE

        page += 1
      end

      items
    end

    # True when the item's movie is *available* — Radarr's notion of a movie
    # being released/available. Uses `MovieResource#is_available` (`isAvailable`),
    # which Radarr computes from the movie's status, minimum-availability setting,
    # and release dates — the direct analog of Sonarr's aired-episode check.
    def released?(item : QueueItem) : Bool
      movie_id = item.movie_id
      return false if movie_id.nil?

      movie = Radarr::Api::Movie.new(@client).get(movie_id)
      return false if movie.nil?

      RadarrBackend.available_movie?(movie)
    end

    # Deletes the queue record, removing it from the download client and adding
    # it to the blocklist.
    def delete_and_blocklist(item : QueueItem) : Nil
      id = item.id
      raise ArgumentError.new("queue item #{item.title.inspect} has no id; cannot delete") if id.nil?

      Radarr::Api::Queue.new(@client).delete(id, remove_from_client: true, blocklist: true)
    end

    # Issues a `MoviesSearch` command for the item's movie.
    def search(item : QueueItem) : Nil
      movie_id = item.movie_id
      raise ArgumentError.new("queue item #{item.title.inspect} has no movie id to search") if movie_id.nil?

      post_command({name: "MoviesSearch", movieIds: [movie_id]})
    end

    # Resolves the Radarr download client named `name` to connection details
    # pulled from its `fields` array.
    def download_client_info(name : String) : DownloadClientInfo?
      resource = Radarr::Api::DownloadClient.new(@client).list.find { |candidate| candidate.name == name }
      return nil if resource.nil?

      RadarrBackend.build_download_client_info(resource)
    end

    # Maps a Radarr queue record onto a `QueueItem`.
    def self.map_queue_item(record : Radarr::Model::QueueResource) : QueueItem
      QueueItem.new(
        id: record.id,
        download_id: record.download_id,
        download_client: record.download_client,
        title: record.title,
        movie_id: record.movie_id,
        status: record.status.try(&.to_radarr_value),
      )
    end

    # Whether `movie` is available, per Radarr's `isAvailable` flag (false when
    # the flag is absent).
    def self.available_movie?(movie : Radarr::Model::MovieResource) : Bool
      movie.is_available == true
    end

    # Builds a `DownloadClientInfo` from a Radarr download-client resource,
    # reading host/port/useSsl/urlBase out of its `fields`.
    def self.build_download_client_info(resource : Radarr::Model::DownloadClientResource) : DownloadClientInfo
      fields = resource.fields
      DownloadClientInfo.new(
        name: resource.name || "",
        implementation: resource.implementation || "",
        host: field_string(fields, "host") || "",
        port: field_int(fields, "port") || 0,
        use_ssl: field_bool(fields, "useSsl") || false,
        url_base: field_string(fields, "urlBase"),
      )
    end

    private def post_command(body) : Nil
      @client.request(:post, "/api/v3/command", nil, body)
    end

    private def self.field_value(fields : Array(Radarr::Model::Field), key : String) : JSON::Any?
      fields.find { |field| field.name == key }.try(&.value)
    end

    private def self.field_string(fields : Array(Radarr::Model::Field), key : String) : String?
      field_value(fields, key).try(&.as_s?)
    end

    private def self.field_int(fields : Array(Radarr::Model::Field), key : String) : Int32?
      value = field_value(fields, key)
      return nil if value.nil?

      if i = value.as_i?
        i
      elsif f = value.as_f?
        f.to_i
      elsif s = value.as_s?
        s.to_i?
      end
    end

    private def self.field_bool(fields : Array(Radarr::Model::Field), key : String) : Bool?
      field_value(fields, key).try(&.as_bool?)
    end
  end
end
