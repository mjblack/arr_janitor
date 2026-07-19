require "sonarr"

module ArrJanitor
  # `Backend` backed by the `sonarr` shard. Wraps a `Sonarr::Client` built from
  # a `Config::Backend` and maps Sonarr's models onto ArrJanitor's structs.
  #
  # Network errors are not swallowed: any failed Sonarr request raises
  # (`Sonarr::ApiError`) for the scheduler/janitor to log.
  class SonarrBackend < Backend
    # Page size used when walking the (paged) queue endpoint.
    QUEUE_PAGE_SIZE = 100

    # The `Config::Backend` this backend was built from.
    getter config : Config::Backend

    def initialize(@config : Config::Backend)
      @client = Sonarr::Client.new(@config.url, @config.api_key)
    end

    def interval_span : Time::Span
      @config.interval_span
    end

    def name : String
      @config.name
    end

    # Fetches the full queue, following paging until every record is collected.
    def queue : Array(QueueItem)
      api = Sonarr::Api::Queue.new(@client)
      items = [] of QueueItem
      page = 1

      loop do
        resource = api.list(page: page, page_size: QUEUE_PAGE_SIZE, include_episode: true)
        break if resource.nil?

        records = resource.records
        records.each { |record| items << SonarrBackend.map_queue_item(record) }

        total = resource.total_records
        break if records.empty?
        break if total && items.size >= total
        break if records.size < QUEUE_PAGE_SIZE

        page += 1
      end

      items
    end

    # True when the item's episode has aired (air-date on/before now) — Sonarr's
    # notion of an episode being released/available.
    def released?(item : QueueItem) : Bool
      episode_id = item.episode_id
      return false if episode_id.nil?

      episode = Sonarr::Api::Episode.new(@client).get(episode_id)
      return false if episode.nil?

      SonarrBackend.released_episode?(episode)
    end

    # Deletes the queue record, removing it from the download client and adding
    # it to the blocklist.
    def delete_and_blocklist(item : QueueItem) : Nil
      id = item.id
      raise ArgumentError.new("queue item #{item.title.inspect} has no id; cannot delete") if id.nil?

      Sonarr::Api::Queue.new(@client).delete(id, remove_from_client: true, blocklist: true)
    end

    # Issues an `EpisodeSearch` command for the item's episode, falling back to a
    # `SeriesSearch` when there is no episode id.
    def search(item : QueueItem) : Nil
      if episode_id = item.episode_id
        post_command({name: "EpisodeSearch", episodeIds: [episode_id]})
      elsif series_id = item.series_id
        post_command({name: "SeriesSearch", seriesId: series_id})
      else
        raise ArgumentError.new("queue item #{item.title.inspect} has no episode or series id to search")
      end
    end

    # Resolves the Sonarr download client named `name` to connection details
    # pulled from its `fields` array.
    def download_client_info(name : String) : DownloadClientInfo?
      resource = Sonarr::Api::DownloadClient.new(@client).list.find { |candidate| candidate.name == name }
      return nil if resource.nil?

      SonarrBackend.build_download_client_info(resource)
    end

    # Maps a Sonarr queue record onto a `QueueItem`.
    def self.map_queue_item(record : Sonarr::Model::QueueResource) : QueueItem
      QueueItem.new(
        id: record.id,
        download_id: record.download_id,
        download_client: record.download_client,
        title: record.title,
        episode_id: record.episode_id,
        series_id: record.series_id,
        status: record.status.try(&.to_sonarr_value),
      )
    end

    # Whether `episode` has aired by `now` (both compared in UTC).
    def self.released_episode?(episode : Sonarr::Model::EpisodeResource, now : Time = Time.utc) : Bool
      air_date = episode.air_date_utc
      return false if air_date.nil?

      air_date <= now
    end

    # Builds a `DownloadClientInfo` from a Sonarr download-client resource,
    # reading host/port/useSsl/urlBase out of its `fields`.
    def self.build_download_client_info(resource : Sonarr::Model::DownloadClientResource) : DownloadClientInfo
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

    private def self.field_value(fields : Array(Sonarr::Model::Field), key : String) : JSON::Any?
      fields.find { |field| field.name == key }.try(&.value)
    end

    private def self.field_string(fields : Array(Sonarr::Model::Field), key : String) : String?
      field_value(fields, key).try(&.as_s?)
    end

    private def self.field_int(fields : Array(Sonarr::Model::Field), key : String) : Int32?
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

    private def self.field_bool(fields : Array(Sonarr::Model::Field), key : String) : Bool?
      field_value(fields, key).try(&.as_bool?)
    end
  end
end
