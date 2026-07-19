require "./spec_helper"

# A fake download client returning canned file paths (or raising) — no network.
private class FakeDownloadClient < ArrJanitor::DownloadClient
  def initialize(@files : Array(String), @error : Exception? = nil)
  end

  def files_for(hash : String) : Array(String)
    if err = @error
      raise err
    end
    @files
  end
end

# A `Backend` with canned queue/client-info/release status that records the
# `delete_and_blocklist` and `search` items it was asked to act on. No network.
private class StubBackend < ArrJanitor::Backend
  getter deleted = [] of ArrJanitor::QueueItem
  getter searched = [] of ArrJanitor::QueueItem
  property? released = false

  def initialize(@config : ArrJanitor::Config::Backend,
                 @queue : Array(ArrJanitor::QueueItem) = [] of ArrJanitor::QueueItem,
                 @client_info : ArrJanitor::DownloadClientInfo? = nil)
  end

  getter config : ArrJanitor::Config::Backend

  def interval_span : Time::Span
    20.minutes
  end

  def name : String
    @config.name
  end

  def queue : Array(ArrJanitor::QueueItem)
    @queue
  end

  def released?(item : ArrJanitor::QueueItem) : Bool
    @released
  end

  def delete_and_blocklist(item : ArrJanitor::QueueItem) : Nil
    @deleted << item
  end

  def search(item : ArrJanitor::QueueItem) : Nil
    @searched << item
  end

  def download_client_info(name : String) : ArrJanitor::DownloadClientInfo?
    @client_info
  end
end

# Builds a config backend named "Test Sonarr" with the qBittorrent credentials
# and bad-extension filter used throughout these specs.
private def build_config(clients = [ArrJanitor::Config::DownloadClient.new(
                           name: "qbit", username: "admin", password: "secret")],
                         extensions = ["exe", "scr"]) : ArrJanitor::Config::Backend
  ArrJanitor::Config::Backend.new(
    name: "Test Sonarr",
    type: ArrJanitor::Config::BackendType::Sonarr,
    url: "http://localhost:8989",
    api_key: "key",
    extensions_filter: extensions,
    download_clients: clients)
end

# A `DownloadClientInfo` describing a qBittorrent client named "qbit".
private def qbit_info : ArrJanitor::DownloadClientInfo
  ArrJanitor::DownloadClientInfo.new(
    name: "qbit", implementation: "qBittorrent",
    host: "localhost", port: 8080, use_ssl: false)
end

private def queue_item(**opts) : ArrJanitor::QueueItem
  ArrJanitor::QueueItem.new(**opts)
end

# Runs the janitor against *backend* with a resolver that always returns
# *client*, capturing every emitted `LogEvent`.
private def run_janitor(backend : ArrJanitor::Backend,
                        client : ArrJanitor::DownloadClient?) : Array(ArrJanitor::LogEvent)
  resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
    client
  end
  capture(backend, ArrJanitor::Janitor.new(resolver))
end

# Drains all events a janitor emits while processing *backend*.
private def capture(backend : ArrJanitor::Backend,
                    janitor : ArrJanitor::Janitor) : Array(ArrJanitor::LogEvent)
  channel = Channel(ArrJanitor::LogEvent).new(64)
  reporter = ArrJanitor::Reporter.new(channel)
  janitor.process(backend, reporter)
  reporter.close

  events = [] of ArrJanitor::LogEvent
  while event = channel.receive?
    events << event
  end
  events
end

describe ArrJanitor::Janitor do
  describe "#process" do
    it "deletes, blocklists and re-searches a bad download that is released" do
      item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
        title: "Bad.Release", episode_id: 5)
      backend = StubBackend.new(build_config, [item], qbit_info)
      backend.released = true

      events = run_janitor(backend, FakeDownloadClient.new(["show.mkv", "virus.exe"]))

      backend.deleted.should eq([item])
      backend.searched.should eq([item])
      events.any? { |e| e.severity.warn? && e.message.includes?("virus.exe") }.should be_true
      events.any?(&.message.includes?("search re-triggered")).should be_true
    end

    it "deletes and blocklists but does not search when not released" do
      item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
        title: "Bad.Release", episode_id: 5)
      backend = StubBackend.new(build_config, [item], qbit_info)
      backend.released = false

      events = run_janitor(backend, FakeDownloadClient.new(["virus.scr"]))

      backend.deleted.should eq([item])
      backend.searched.should be_empty
      events.any?(&.message.includes?("not released yet")).should be_true
    end

    it "takes no action on a clean download" do
      item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
        title: "Good.Release", episode_id: 5)
      backend = StubBackend.new(build_config, [item], qbit_info)

      events = run_janitor(backend, FakeDownloadClient.new(["show.mkv", "info.nfo"]))

      backend.deleted.should be_empty
      backend.searched.should be_empty
      events.any?(&.severity.warn?).should be_false
    end

    it "skips an item whose download client has no configured credentials" do
      item = queue_item(id: 1, download_id: "HASH", download_client: "other",
        title: "Release", episode_id: 5)
      backend = StubBackend.new(build_config, [item], qbit_info)

      events = run_janitor(backend, FakeDownloadClient.new(["virus.exe"]))

      backend.deleted.should be_empty
      events.any? { |e| e.severity.warn? && e.message.includes?("no configured credentials") }.should be_true
    end

    it "skips an item with no download client name" do
      item = queue_item(id: 1, download_id: "HASH", title: "No.Client", episode_id: 5)
      backend = StubBackend.new(build_config, [item], qbit_info)

      events = run_janitor(backend, FakeDownloadClient.new(["virus.exe"]))

      backend.deleted.should be_empty
      events.any? { |e| e.severity.info? && e.message.includes?("no download client") }.should be_true
    end

    it "skips when the *arr has no such download client" do
      item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
        title: "Release", episode_id: 5)
      backend = StubBackend.new(build_config, [item], nil)

      events = run_janitor(backend, FakeDownloadClient.new(["virus.exe"]))

      backend.deleted.should be_empty
      events.any? { |e| e.severity.warn? && e.message.includes?("not found") }.should be_true
    end

    it "skips an unsupported download client implementation" do
      item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
        title: "Release", episode_id: 5)
      info = ArrJanitor::DownloadClientInfo.new(
        name: "qbit", implementation: "transmission",
        host: "localhost", port: 9091, use_ssl: false)
      backend = StubBackend.new(build_config, [item], info)

      # Resolver returns nil for the unsupported implementation.
      events = run_janitor(backend, nil)

      backend.deleted.should be_empty
      events.any? { |e| e.message.includes?("unsupported download client implementation 'transmission'") }.should be_true
    end

    it "skips an item with no download id" do
      item = queue_item(id: 1, download_client: "qbit", title: "No.Hash", episode_id: 5)
      backend = StubBackend.new(build_config, [item], qbit_info)

      run_janitor(backend, FakeDownloadClient.new(["virus.exe"]))

      backend.deleted.should be_empty
    end

    it "logs and continues when one item raises, still processing the rest" do
      bad = queue_item(id: 1, download_id: "BAD", download_client: "qbit",
        title: "Explodes", episode_id: 5)
      good = queue_item(id: 2, download_id: "GOOD", download_client: "qbit",
        title: "Fine", episode_id: 6)
      backend = StubBackend.new(build_config, [bad, good], qbit_info)
      backend.released = true

      # A resolver whose client raises on the first hash but succeeds on the
      # second, proving the loop continues past the failing item.
      resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
        FailingThenBadClient.new
      end
      events = capture(backend, ArrJanitor::Janitor.new(resolver))

      backend.deleted.should eq([good])
      events.any? { |e| e.severity.error? && e.message.includes?("Explodes") }.should be_true
    end
  end

  describe "store recording" do
    it "records a processed download in the store after a bad-download delete" do
      dir = File.tempname("arr_janitor_janitor_store")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Bad.Release", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)

        resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
          FakeDownloadClient.new(["show.mkv", "virus.exe"])
        end
        capture(backend, ArrJanitor::Janitor.new(resolver, store))

        backend.deleted.should eq([item])
        store.processed?(backend.name, "HASH").should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "takes no store action on a clean download" do
      dir = File.tempname("arr_janitor_janitor_store")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Good.Release", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)

        resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
          FakeDownloadClient.new(["show.mkv"])
        end
        capture(backend, ArrJanitor::Janitor.new(resolver, store))

        store.processed?(backend.name, "HASH").should be_false
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end
  end
end

# Raises on the "BAD" hash and returns a bad file for anything else, exercising
# the per-item rescue without aborting the whole run.
private class FailingThenBadClient < ArrJanitor::DownloadClient
  def files_for(hash : String) : Array(String)
    raise "kaboom" if hash == "BAD"
    ["virus.exe"]
  end
end
