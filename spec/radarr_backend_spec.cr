require "./spec_helper"

describe ArrJanitor::RadarrBackend do
  describe ".map_queue_item" do
    it "maps a Radarr queue record onto a QueueItem" do
      record = Radarr::Model::QueueResource.from_json(<<-JSON)
        {
          "id": 42,
          "movieId": 7,
          "title": "Some.Movie.Release.Group",
          "status": "completed",
          "downloadId": "ABCDEF0123456789",
          "downloadClient": "My qbittorrent"
        }
        JSON

      item = ArrJanitor::RadarrBackend.map_queue_item(record)
      item.id.should eq(42)
      item.movie_id.should eq(7)
      # Radarr items carry no episode/series handles.
      item.episode_id.should be_nil
      item.series_id.should be_nil
      item.title.should eq("Some.Movie.Release.Group")
      item.status.should eq("completed")
      item.download_id.should eq("ABCDEF0123456789")
      item.download_client.should eq("My qbittorrent")
    end

    it "tolerates a record with missing fields" do
      record = Radarr::Model::QueueResource.from_json(%({"id": 1}))
      item = ArrJanitor::RadarrBackend.map_queue_item(record)
      item.id.should eq(1)
      item.movie_id.should be_nil
      item.status.should be_nil
      item.download_id.should be_nil
    end
  end

  describe ".available_movie?" do
    it "is true when isAvailable is true" do
      movie = Radarr::Model::MovieResource.from_json(%({"id": 1, "isAvailable": true}))
      ArrJanitor::RadarrBackend.available_movie?(movie).should be_true
    end

    it "is false when isAvailable is false" do
      movie = Radarr::Model::MovieResource.from_json(%({"id": 1, "isAvailable": false}))
      ArrJanitor::RadarrBackend.available_movie?(movie).should be_false
    end

    it "is false when isAvailable is absent" do
      movie = Radarr::Model::MovieResource.from_json(%({"id": 1}))
      ArrJanitor::RadarrBackend.available_movie?(movie).should be_false
    end
  end

  describe ".build_download_client_info" do
    it "pulls host/port/useSsl/urlBase from the resource fields" do
      resource = Radarr::Model::DownloadClientResource.from_json(<<-JSON)
        {
          "name": "My qbittorrent",
          "implementation": "qBittorrent",
          "fields": [
            {"name": "host", "value": "192.168.1.10"},
            {"name": "port", "value": 9091},
            {"name": "useSsl", "value": true},
            {"name": "urlBase", "value": "/qbit"}
          ]
        }
        JSON

      info = ArrJanitor::RadarrBackend.build_download_client_info(resource)
      info.name.should eq("My qbittorrent")
      info.implementation.should eq("qBittorrent")
      info.host.should eq("192.168.1.10")
      info.port.should eq(9091)
      info.use_ssl?.should be_true
      info.url_base.should eq("/qbit")
      info.base_url.should eq("https://192.168.1.10:9091/qbit")
    end

    it "falls back to defaults when fields are absent" do
      resource = Radarr::Model::DownloadClientResource.from_json(<<-JSON)
        {
          "name": "Bare",
          "implementation": "qBittorrent",
          "fields": []
        }
        JSON

      info = ArrJanitor::RadarrBackend.build_download_client_info(resource)
      info.host.should eq("")
      info.port.should eq(0)
      info.use_ssl?.should be_false
      info.url_base.should be_nil
    end

    it "coerces a stringified port to an integer" do
      resource = Radarr::Model::DownloadClientResource.from_json(<<-JSON)
        {
          "name": "Stringy",
          "implementation": "qBittorrent",
          "fields": [
            {"name": "host", "value": "localhost"},
            {"name": "port", "value": "8080"}
          ]
        }
        JSON

      info = ArrJanitor::RadarrBackend.build_download_client_info(resource)
      info.port.should eq(8080)
    end
  end

  describe "scheduling from config" do
    it "reads the interval span from the config backend" do
      config = ArrJanitor::Config::Backend.new(
        name: "My Radarr",
        type: ArrJanitor::Config::BackendType::Radarr,
        url: "http://localhost:7878",
        api_key: "key",
        interval: "45m")
      backend = ArrJanitor::RadarrBackend.new(config)
      backend.name.should eq("My Radarr")
      backend.interval_span.should eq(45.minutes)

      now = Time.utc(2026, 7, 18, 12, 0, 0)
      backend.schedule_next(now)
      backend.next_run.should eq(now + 45.minutes)
    end
  end
end
