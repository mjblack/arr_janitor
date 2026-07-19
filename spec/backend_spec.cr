require "./spec_helper"

# A minimal concrete backend to exercise the scheduling logic on the abstract
# `Backend` without touching the network.
private class StubBackend < ArrJanitor::Backend
  def initialize(@span : Time::Span)
  end

  def interval_span : Time::Span
    @span
  end

  def name : String
    "stub"
  end

  def queue : Array(ArrJanitor::QueueItem)
    [] of ArrJanitor::QueueItem
  end

  def released?(item : ArrJanitor::QueueItem) : Bool
    false
  end

  def delete_and_blocklist(item : ArrJanitor::QueueItem) : Nil
  end

  def search(item : ArrJanitor::QueueItem) : Nil
  end

  def download_client_info(name : String) : ArrJanitor::DownloadClientInfo?
    nil
  end
end

private NOW = Time.utc(2026, 7, 18, 12, 0, 0)

describe ArrJanitor::Backend do
  describe "#due?" do
    it "is due on the first tick when next_run is unset" do
      backend = StubBackend.new(20.minutes)
      backend.next_run.should be_nil
      backend.due?(NOW).should be_true
    end

    it "is due once next_run has been reached or passed" do
      backend = StubBackend.new(20.minutes)
      backend.next_run = NOW
      backend.due?(NOW).should be_true
      backend.due?(NOW + 1.second).should be_true
    end

    it "is not due before next_run" do
      backend = StubBackend.new(20.minutes)
      backend.next_run = NOW + 5.minutes
      backend.due?(NOW).should be_false
    end
  end

  describe "#schedule_next" do
    it "advances next_run by the interval span" do
      backend = StubBackend.new(30.minutes)
      backend.schedule_next(NOW)
      backend.next_run.should eq(NOW + 30.minutes)
    end

    it "makes the backend not due until the new next_run" do
      backend = StubBackend.new(30.minutes)
      backend.schedule_next(NOW)
      backend.due?(NOW).should be_false
      backend.due?(NOW + 30.minutes).should be_true
    end
  end
end

describe ArrJanitor::DownloadClientInfo do
  describe "#base_url" do
    it "builds an http URL without ssl or url_base" do
      info = ArrJanitor::DownloadClientInfo.new(
        name: "qbit", implementation: "qBittorrent",
        host: "localhost", port: 8080, use_ssl: false)
      info.base_url.should eq("http://localhost:8080")
    end

    it "builds an https URL when use_ssl is true" do
      info = ArrJanitor::DownloadClientInfo.new(
        name: "qbit", implementation: "qBittorrent",
        host: "example.com", port: 443, use_ssl: true)
      info.base_url.should eq("https://example.com:443")
    end

    it "appends a url_base, normalising surrounding slashes" do
      info = ArrJanitor::DownloadClientInfo.new(
        name: "qbit", implementation: "qBittorrent",
        host: "localhost", port: 8080, use_ssl: false, url_base: "/qbit/")
      info.base_url.should eq("http://localhost:8080/qbit")
    end

    it "ignores an empty url_base" do
      info = ArrJanitor::DownloadClientInfo.new(
        name: "qbit", implementation: "qBittorrent",
        host: "localhost", port: 8080, use_ssl: true, url_base: "")
      info.base_url.should eq("https://localhost:8080")
    end
  end
end

describe ArrJanitor::SonarrBackend do
  describe ".map_queue_item" do
    it "maps a Sonarr queue record onto a QueueItem" do
      record = Sonarr::Model::QueueResource.from_json(<<-JSON)
        {
          "id": 42,
          "seriesId": 7,
          "episodeId": 13,
          "title": "Some.Release.Group",
          "status": "completed",
          "downloadId": "ABCDEF0123456789",
          "downloadClient": "My qbittorrent"
        }
        JSON

      item = ArrJanitor::SonarrBackend.map_queue_item(record)
      item.id.should eq(42)
      item.series_id.should eq(7)
      item.episode_id.should eq(13)
      item.title.should eq("Some.Release.Group")
      item.status.should eq("completed")
      item.download_id.should eq("ABCDEF0123456789")
      item.download_client.should eq("My qbittorrent")
    end

    it "tolerates a record with missing fields" do
      record = Sonarr::Model::QueueResource.from_json(%({"id": 1}))
      item = ArrJanitor::SonarrBackend.map_queue_item(record)
      item.id.should eq(1)
      item.episode_id.should be_nil
      item.status.should be_nil
      item.download_id.should be_nil
    end
  end

  describe ".released_episode?" do
    now = Time.utc(2026, 7, 18, 12, 0, 0)

    it "is true when the episode aired before now" do
      episode = Sonarr::Model::EpisodeResource.from_json(
        %({"id": 1, "airDateUtc": "2026-07-01T00:00:00Z"}))
      ArrJanitor::SonarrBackend.released_episode?(episode, now).should be_true
    end

    it "is true when the episode airs exactly now" do
      episode = Sonarr::Model::EpisodeResource.from_json(
        %({"id": 1, "airDateUtc": "2026-07-18T12:00:00Z"}))
      ArrJanitor::SonarrBackend.released_episode?(episode, now).should be_true
    end

    it "is false when the episode airs in the future" do
      episode = Sonarr::Model::EpisodeResource.from_json(
        %({"id": 1, "airDateUtc": "2026-08-01T00:00:00Z"}))
      ArrJanitor::SonarrBackend.released_episode?(episode, now).should be_false
    end

    it "is false when the episode has no air date" do
      episode = Sonarr::Model::EpisodeResource.from_json(%({"id": 1}))
      ArrJanitor::SonarrBackend.released_episode?(episode, now).should be_false
    end
  end

  describe ".build_download_client_info" do
    it "pulls host/port/useSsl/urlBase from the resource fields" do
      resource = Sonarr::Model::DownloadClientResource.from_json(<<-JSON)
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

      info = ArrJanitor::SonarrBackend.build_download_client_info(resource)
      info.name.should eq("My qbittorrent")
      info.implementation.should eq("qBittorrent")
      info.host.should eq("192.168.1.10")
      info.port.should eq(9091)
      info.use_ssl?.should be_true
      info.url_base.should eq("/qbit")
      info.base_url.should eq("https://192.168.1.10:9091/qbit")
    end

    it "falls back to defaults when fields are absent" do
      resource = Sonarr::Model::DownloadClientResource.from_json(<<-JSON)
        {
          "name": "Bare",
          "implementation": "qBittorrent",
          "fields": []
        }
        JSON

      info = ArrJanitor::SonarrBackend.build_download_client_info(resource)
      info.host.should eq("")
      info.port.should eq(0)
      info.use_ssl?.should be_false
      info.url_base.should be_nil
    end

    it "coerces a stringified port to an integer" do
      resource = Sonarr::Model::DownloadClientResource.from_json(<<-JSON)
        {
          "name": "Stringy",
          "implementation": "qBittorrent",
          "fields": [
            {"name": "host", "value": "localhost"},
            {"name": "port", "value": "8080"}
          ]
        }
        JSON

      info = ArrJanitor::SonarrBackend.build_download_client_info(resource)
      info.port.should eq(8080)
    end
  end

  describe "scheduling from config" do
    it "reads the interval span from the config backend" do
      config = ArrJanitor::Config::Backend.new(
        name: "My Sonarr",
        type: ArrJanitor::Config::BackendType::Sonarr,
        url: "http://localhost:8989",
        api_key: "key",
        interval: "45m")
      backend = ArrJanitor::SonarrBackend.new(config)
      backend.name.should eq("My Sonarr")
      backend.interval_span.should eq(45.minutes)

      now = Time.utc(2026, 7, 18, 12, 0, 0)
      backend.schedule_next(now)
      backend.next_run.should eq(now + 45.minutes)
    end
  end
end
