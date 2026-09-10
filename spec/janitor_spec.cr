require "./spec_helper"
require "db"
require "sqlite3"

# A fake download client returning canned file paths / snapshots (or raising) —
# no network. Default snapshot is a healthy downloading torrent with seeds so
# existing extension-matcher specs keep taking the files_for path.
private class FakeDownloadClient < ArrJanitor::DownloadClient
  getter? files_for_called = false

  def initialize(@files : Array(String), @error : Exception? = nil,
                 @snapshot : ArrJanitor::DownloadClient::TorrentSnapshot? = nil,
                 @info_error : Exception? = nil,
                 @failing_hash : String? = nil)
  end

  def files_for(hash : String) : Array(String)
    @files_for_called = true
    if (err = @error) && hash_fails?(hash)
      raise err
    end
    @files
  end

  def info_for(hash : String) : ArrJanitor::DownloadClient::TorrentSnapshot
    if (err = @info_error) && hash_fails?(hash)
      raise err
    end
    @snapshot || ArrJanitor::DownloadClient::TorrentSnapshot.new(
      hash: hash, state: "downloading", num_seeds: 1)
  end

  private def hash_fails?(hash : String) : Bool
    failing = @failing_hash
    failing.nil? || hash == failing
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
                         extensions = ["exe", "scr"],
                         cleanup : ArrJanitor::Config::Cleanup? = nil) : ArrJanitor::Config::Backend
  ArrJanitor::Config::Backend.new(
    name: "Test Sonarr",
    type: ArrJanitor::Config::BackendType::Sonarr,
    url: "http://localhost:8989",
    api_key: "key",
    extensions_filter: extensions,
    download_clients: clients,
    cleanup: cleanup)
end

# A `TorrentSnapshot` in qBittorrent `metaDL`. Default `added_on` is older than
# the 15m metadata-downloading timeout so over-timeout examples stay concise.
private def meta_snapshot(hash = "HASH", *, added_on : Time? = Time.utc - 16.minutes)
  ArrJanitor::DownloadClient::TorrentSnapshot.new(
    hash: hash, state: "metaDL", num_seeds: 0, added_on: added_on)
end

# A `TorrentSnapshot` in a downloading-family state with the given seed count.
# Defaults to `stalledDL` + 0 seeds (the stalled-cleanup happy path).
private def stalled_snapshot(hash = "HASH", *, state = "stalledDL", num_seeds = 0)
  ArrJanitor::DownloadClient::TorrentSnapshot.new(
    hash: hash, state: state, num_seeds: num_seeds)
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
                        client : ArrJanitor::DownloadClient?,
                        store : ArrJanitor::Store? = nil,
                        dry_run : Bool = false) : Array(ArrJanitor::LogEvent)
  resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
    client
  end
  capture(backend, ArrJanitor::Janitor.new(resolver, store, dry_run: dry_run))
end

# The most recent `processed_downloads.action` for (`backend`, `download_id`),
# or `nil` when nothing has been recorded.
private def recorded_action(path : String, backend : String, download_id : String) : String?
  DB.open("sqlite3://#{path}") do |database|
    database.query_one?(
      "SELECT action FROM processed_downloads WHERE backend = ? AND download_id = ? ORDER BY id DESC LIMIT 1",
      backend, download_id, as: String)
  end
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

    it "skips (with a warning) an item whose torrent is not found in the client" do
      gone = queue_item(id: 1, download_id: "GONE", download_client: "qbit",
        title: "Missing", episode_id: 5)
      good = queue_item(id: 2, download_id: "GOOD", download_client: "qbit",
        title: "Fine", episode_id: 6)
      backend = StubBackend.new(build_config, [gone, good], qbit_info)
      backend.released = true

      resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
        DownloadClientErrorClient.new(
          "GONE", ArrJanitor::DownloadClient::TorrentNotFound.new("torrent GONE not found (HTTP 404)"))
      end
      events = capture(backend, ArrJanitor::Janitor.new(resolver))

      # The scan completed and the healthy second item was still processed.
      backend.deleted.should eq([good])
      backend.searched.should eq([good])
      # Warned about the missing torrent, but did not error out.
      events.any? { |e| e.severity.warn? && e.message.includes?("Missing") && e.message.includes?("not found") }.should be_true
      events.any?(&.severity.error?).should be_false
    end

    it "skips (with a warning) an item whose file listing raises a generic client error" do
      broken = queue_item(id: 1, download_id: "BROKEN", download_client: "qbit",
        title: "Broken", episode_id: 5)
      good = queue_item(id: 2, download_id: "GOOD", download_client: "qbit",
        title: "Fine", episode_id: 6)
      backend = StubBackend.new(build_config, [broken, good], qbit_info)
      backend.released = true

      resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
        DownloadClientErrorClient.new(
          "BROKEN", ArrJanitor::DownloadClient::Error.new("qBittorrent API error: HTTP 409"))
      end
      events = capture(backend, ArrJanitor::Janitor.new(resolver))

      # The failing item was skipped without a delete/blocklist/search, and the
      # healthy second item was still processed.
      backend.deleted.should eq([good])
      backend.searched.should eq([good])
      events.any? { |e| e.severity.warn? && e.message.includes?("Broken") && e.message.includes?("could not list files") }.should be_true
      events.any?(&.severity.error?).should be_false
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

  describe "dry-run mode" do
    it "logs intended delete/blocklist + search but does not mutate the backend" do
      item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
        title: "Bad.Release", episode_id: 5)
      backend = StubBackend.new(build_config, [item], qbit_info)
      backend.released = true

      resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
        FakeDownloadClient.new(["show.mkv", "virus.exe"])
      end
      events = capture(backend, ArrJanitor::Janitor.new(resolver, dry_run: true))

      backend.deleted.should be_empty
      backend.searched.should be_empty
      events.any? { |e| e.message.includes?("[DRY RUN] would delete + blocklist 'Bad.Release'") && e.message.includes?("virus.exe") }.should be_true
      events.any?(&.message.includes?("[DRY RUN] would re-trigger search for 'Bad.Release'")).should be_true
    end

    it "logs that it would skip the search when not released" do
      item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
        title: "Bad.Release", episode_id: 5)
      backend = StubBackend.new(build_config, [item], qbit_info)
      backend.released = false

      resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
        FakeDownloadClient.new(["virus.scr"])
      end
      events = capture(backend, ArrJanitor::Janitor.new(resolver, dry_run: true))

      backend.deleted.should be_empty
      backend.searched.should be_empty
      events.any?(&.message.includes?("[DRY RUN] not released; would skip search")).should be_true
    end

    it "does not write to the store" do
      dir = File.tempname("arr_janitor_dry_run_store")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Bad.Release", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)

        resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
          FakeDownloadClient.new(["show.mkv", "virus.exe"])
        end
        capture(backend, ArrJanitor::Janitor.new(resolver, store, dry_run: true))

        backend.deleted.should be_empty
        store.processed?(backend.name, "HASH").should be_false
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
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

  describe "metadata-downloading cleanup" do
    it "deletes, blocklists and re-searches a metaDL torrent older than the timeout when released" do
      dir = File.tempname("arr_janitor_janitor_meta")
      Dir.mkdir_p(dir)
      path = File.join(dir, "test.db")
      store = ArrJanitor::Store.open(path)
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Stuck.Magnet", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        backend.released = true
        client = FakeDownloadClient.new(["virus.exe"], snapshot: meta_snapshot)

        events = run_janitor(backend, client, store)

        backend.deleted.should eq([item])
        backend.searched.should eq([item])
        client.files_for_called?.should be_false
        recorded_action(path, backend.name, "HASH").should eq("removed_blocklisted_metadata")
        events.any? { |event|
          event.severity.warn? && event.message.includes?("stuck downloading metadata")
        }.should be_true
        events.any?(&.message.includes?("search re-triggered")).should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "deletes and blocklists but does not search a timed-out metaDL torrent that is not released" do
      item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
        title: "Stuck.Magnet", episode_id: 5)
      backend = StubBackend.new(build_config, [item], qbit_info)
      backend.released = false
      client = FakeDownloadClient.new(["virus.exe"], snapshot: meta_snapshot)

      events = run_janitor(backend, client)

      backend.deleted.should eq([item])
      backend.searched.should be_empty
      client.files_for_called?.should be_false
      events.any?(&.message.includes?("not released yet")).should be_true
    end

    it "does not delete a metaDL torrent younger than the timeout and records first-seen" do
      dir = File.tempname("arr_janitor_janitor_meta")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Fresh.Magnet", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        client = FakeDownloadClient.new(["virus.exe"],
          snapshot: meta_snapshot(added_on: Time.utc - 1.minute))

        events = run_janitor(backend, client, store)

        backend.deleted.should be_empty
        backend.searched.should be_empty
        client.files_for_called?.should be_false
        store.first_seen_metadata(backend.name, "HASH").should_not be_nil
        store.processed?(backend.name, "HASH").should be_false
        events.any? { |event|
          event.severity.debug? && event.message.includes?("downloading metadata")
        }.should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "marks first-seen and does not delete a metaDL torrent with no added_on and no prior store row" do
      dir = File.tempname("arr_janitor_janitor_meta")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "No.AddedOn", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        client = FakeDownloadClient.new(["virus.exe"],
          snapshot: meta_snapshot(added_on: nil))

        store.first_seen_metadata(backend.name, "HASH").should be_nil
        run_janitor(backend, client, store)

        backend.deleted.should be_empty
        client.files_for_called?.should be_false
        store.first_seen_metadata(backend.name, "HASH").should_not be_nil
        store.processed?(backend.name, "HASH").should be_false
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "deletes a metaDL torrent with no added_on once first-seen is older than the timeout" do
      dir = File.tempname("arr_janitor_janitor_meta")
      Dir.mkdir_p(dir)
      path = File.join(dir, "test.db")
      store = ArrJanitor::Store.open(path)
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Aged.Magnet", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        backend.released = true
        store.mark_metadata(backend.name, "HASH", Time.utc - 16.minutes)
        client = FakeDownloadClient.new(["virus.exe"],
          snapshot: meta_snapshot(added_on: nil))

        events = run_janitor(backend, client, store)

        backend.deleted.should eq([item])
        backend.searched.should eq([item])
        client.files_for_called?.should be_false
        recorded_action(path, backend.name, "HASH").should eq("removed_blocklisted_metadata")
        events.any? { |event|
          event.severity.warn? && event.message.includes?("stuck downloading metadata")
        }.should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "does not act on metadata when the cleanup rule is disabled" do
      dir = File.tempname("arr_janitor_janitor_meta")
      Dir.mkdir_p(dir)
      path = File.join(dir, "test.db")
      store = ArrJanitor::Store.open(path)
      begin
        cleanup = ArrJanitor::Config::Cleanup.new(
          metadata_downloading: ArrJanitor::Config::CleanupRule.new(enabled: false))
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Disabled.Meta", episode_id: 5)
        backend = StubBackend.new(build_config(cleanup: cleanup), [item], qbit_info)
        backend.released = true
        client = FakeDownloadClient.new(["virus.exe"], snapshot: meta_snapshot)

        events = run_janitor(backend, client, store)

        # Falls through to the extension matcher; the bad file still triggers
        # the existing delete path, not the metadata action.
        backend.deleted.should eq([item])
        client.files_for_called?.should be_true
        store.first_seen_metadata(backend.name, "HASH").should be_nil
        recorded_action(path, backend.name, "HASH").should eq("removed_blocklisted")
        events.any?(&.message.includes?("stuck downloading metadata")).should be_false
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "logs a dry-run would-delete for a timed-out metaDL torrent without mutating" do
      dir = File.tempname("arr_janitor_janitor_meta")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Stuck.Magnet", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        backend.released = true
        client = FakeDownloadClient.new(["virus.exe"], snapshot: meta_snapshot)

        events = run_janitor(backend, client, store, dry_run: true)

        backend.deleted.should be_empty
        backend.searched.should be_empty
        client.files_for_called?.should be_false
        store.processed?(backend.name, "HASH").should be_false
        store.first_seen_metadata(backend.name, "HASH").should be_nil
        events.any? { |event|
          event.message.includes?("[DRY RUN] would delete + blocklist") &&
            event.message.includes?("stuck downloading metadata")
        }.should be_true
        events.any?(&.message.includes?("[DRY RUN] would re-trigger search")).should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "skips (with a warning) when info_for raises a generic client error" do
      broken = queue_item(id: 1, download_id: "BROKEN", download_client: "qbit",
        title: "InspectFail", episode_id: 5)
      good = queue_item(id: 2, download_id: "GOOD", download_client: "qbit",
        title: "Fine", episode_id: 6)
      backend = StubBackend.new(build_config, [broken, good], qbit_info)
      backend.released = true
      client = FakeDownloadClient.new(
        ["virus.exe"],
        info_error: ArrJanitor::DownloadClient::Error.new("qBittorrent API error: HTTP 500"),
        failing_hash: "BROKEN")

      events = run_janitor(backend, client)

      backend.deleted.should eq([good])
      backend.searched.should eq([good])
      events.any? { |event|
        event.severity.warn? && event.message.includes?("InspectFail") &&
          event.message.includes?("could not inspect torrent")
      }.should be_true
      events.any?(&.severity.error?).should be_false
    end

    it "clears a leftover metadata clock when the torrent leaves metaDL" do
      dir = File.tempname("arr_janitor_janitor_meta")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Left.MetaDL", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        store.mark_metadata(backend.name, "HASH", Time.utc - 5.minutes)
        client = FakeDownloadClient.new(["show.mkv"])

        run_janitor(backend, client, store)

        backend.deleted.should be_empty
        client.files_for_called?.should be_true
        store.first_seen_metadata(backend.name, "HASH").should be_nil
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "stalled zero-seed cleanup" do
    it "does not delete a stalled zero-seed torrent on first scan and records first-seen" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Zero.Seeds", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        client = FakeDownloadClient.new(["show.mkv"], snapshot: stalled_snapshot)

        events = run_janitor(backend, client, store)

        backend.deleted.should be_empty
        backend.searched.should be_empty
        client.files_for_called?.should be_true
        store.first_seen_stalled(backend.name, "HASH").should_not be_nil
        store.processed?(backend.name, "HASH").should be_false
        events.any? { |event|
          event.severity.debug? && event.message.includes?("stalled") &&
            event.message.includes?("0 seeds")
        }.should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "deletes, blocklists and re-searches a stalled torrent whose first-seen is older than the timeout when released" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      path = File.join(dir, "test.db")
      store = ArrJanitor::Store.open(path)
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Aged.Stall", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        backend.released = true
        store.mark_stalled(backend.name, "HASH", Time.utc - 61.minutes)
        client = FakeDownloadClient.new(["show.mkv"], snapshot: stalled_snapshot)

        events = run_janitor(backend, client, store)

        backend.deleted.should eq([item])
        backend.searched.should eq([item])
        client.files_for_called?.should be_true
        recorded_action(path, backend.name, "HASH").should eq("removed_blocklisted_stalled")
        events.any? { |event|
          event.severity.warn? && event.message.includes?("stalled") &&
            event.message.includes?("0 seeds")
        }.should be_true
        events.any?(&.message.includes?("search re-triggered")).should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "deletes and blocklists but does not search a timed-out stalled torrent that is not released" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      path = File.join(dir, "test.db")
      store = ArrJanitor::Store.open(path)
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Aged.Stall", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        backend.released = false
        store.mark_stalled(backend.name, "HASH", Time.utc - 61.minutes)
        client = FakeDownloadClient.new(["show.mkv"], snapshot: stalled_snapshot)

        events = run_janitor(backend, client, store)

        backend.deleted.should eq([item])
        backend.searched.should be_empty
        recorded_action(path, backend.name, "HASH").should eq("removed_blocklisted_stalled")
        events.any?(&.message.includes?("not released yet")).should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "does not delete a stalled torrent whose first-seen is younger than the timeout" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Fresh.Stall", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        store.mark_stalled(backend.name, "HASH", Time.utc - 30.minutes)
        client = FakeDownloadClient.new(["show.mkv"], snapshot: stalled_snapshot)

        events = run_janitor(backend, client, store)

        backend.deleted.should be_empty
        store.processed?(backend.name, "HASH").should be_false
        store.first_seen_stalled(backend.name, "HASH").should_not be_nil
        events.any? { |event|
          event.severity.debug? && event.message.includes?("waiting")
        }.should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "clears a leftover stalled clock when the torrent has seeds again" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Recovered.Seeds", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        store.mark_stalled(backend.name, "HASH", Time.utc - 61.minutes)
        client = FakeDownloadClient.new(["show.mkv"],
          snapshot: stalled_snapshot(state: "downloading", num_seeds: 1))

        events = run_janitor(backend, client, store)

        backend.deleted.should be_empty
        store.first_seen_stalled(backend.name, "HASH").should be_nil
        store.processed?(backend.name, "HASH").should be_false
        events.any? { |event|
          event.severity.debug? && event.message.includes?("clean download")
        }.should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "does not use the stalled path for a metaDL torrent with zero seeds" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      path = File.join(dir, "test.db")
      store = ArrJanitor::Store.open(path)
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Still.MetaDL", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        backend.released = true
        store.mark_stalled(backend.name, "HASH", Time.utc - 61.minutes)
        client = FakeDownloadClient.new(["show.mkv"], snapshot: meta_snapshot)

        events = run_janitor(backend, client, store)

        backend.deleted.should eq([item])
        client.files_for_called?.should be_false
        recorded_action(path, backend.name, "HASH").should eq("removed_blocklisted_metadata")
        events.any? { |event|
          event.severity.warn? && event.message.includes?("stuck downloading metadata")
        }.should be_true
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "starts the stalled clock now when a torrent leaves metaDL into 0-seed downloading" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Left.MetaDL.ZeroSeeds", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        store.mark_metadata(backend.name, "HASH", Time.utc - 2.hours)
        client = FakeDownloadClient.new(["show.mkv"], snapshot: stalled_snapshot)

        run_janitor(backend, client, store)

        backend.deleted.should be_empty
        store.first_seen_metadata(backend.name, "HASH").should be_nil
        seen = store.first_seen_stalled(backend.name, "HASH")
        seen.should be_a(Time)
        (Time.utc - seen.as(Time)).should be < 5.seconds
        store.processed?(backend.name, "HASH").should be_false
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "does not treat queuedDL, uploading, or stoppedDL with zero seeds as stalled" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        %w[queuedDL uploading stoppedDL].each do |state|
          item = queue_item(id: 1, download_id: "HASH-#{state}", download_client: "qbit",
            title: "Not.Stalled.#{state}", episode_id: 5)
          backend = StubBackend.new(build_config, [item], qbit_info)
          client = FakeDownloadClient.new(["show.mkv"],
            snapshot: stalled_snapshot("HASH-#{state}", state: state, num_seeds: 0))

          run_janitor(backend, client, store)

          backend.deleted.should be_empty
          store.first_seen_stalled(backend.name, "HASH-#{state}").should be_nil
        end
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "still deletes via the extension path when a 0-seed torrent is under the stalled timeout" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      path = File.join(dir, "test.db")
      store = ArrJanitor::Store.open(path)
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Bad.And.Stalled", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        store.mark_stalled(backend.name, "HASH", Time.utc - 5.minutes)
        client = FakeDownloadClient.new(["virus.exe"], snapshot: stalled_snapshot)

        events = run_janitor(backend, client, store)

        backend.deleted.should eq([item])
        client.files_for_called?.should be_true
        recorded_action(path, backend.name, "HASH").should eq("removed_blocklisted")
        events.any? { |event|
          event.severity.warn? && event.message.includes?("virus.exe")
        }.should be_true
        events.any?(&.message.includes?("removed_blocklisted_stalled")).should be_false
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "does not act on stalled when the cleanup rule is disabled and clears a stale clock" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      path = File.join(dir, "test.db")
      store = ArrJanitor::Store.open(path)
      begin
        cleanup = ArrJanitor::Config::Cleanup.new(
          stalled: ArrJanitor::Config::CleanupRule.new(enabled: false))
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Disabled.Stall", episode_id: 5)
        backend = StubBackend.new(build_config(cleanup: cleanup), [item], qbit_info)
        backend.released = true
        store.mark_stalled(backend.name, "HASH", Time.utc - 61.minutes)
        client = FakeDownloadClient.new(["show.mkv"], snapshot: stalled_snapshot)

        events = run_janitor(backend, client, store)

        backend.deleted.should be_empty
        store.first_seen_stalled(backend.name, "HASH").should be_nil
        recorded_action(path, backend.name, "HASH").should be_nil
        events.any? { |event|
          event.message.includes?("stalled") && event.message.includes?("0 seeds")
        }.should be_false
      ensure
        store.close
        FileUtils.rm_rf(dir)
      end
    end

    it "does not delete a stalled torrent when there is no store" do
      item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
        title: "No.Store.Stall", episode_id: 5)
      backend = StubBackend.new(build_config, [item], qbit_info)
      backend.released = true
      client = FakeDownloadClient.new(["show.mkv"], snapshot: stalled_snapshot)

      events = run_janitor(backend, client)

      backend.deleted.should be_empty
      backend.searched.should be_empty
      events.any? { |event|
        event.severity.debug? && event.message.includes?("database")
      }.should be_true
    end

    it "logs a dry-run would-delete for a timed-out stalled torrent without mutating" do
      dir = File.tempname("arr_janitor_janitor_stalled")
      Dir.mkdir_p(dir)
      store = ArrJanitor::Store.open(File.join(dir, "test.db"))
      begin
        item = queue_item(id: 1, download_id: "HASH", download_client: "qbit",
          title: "Aged.Stall", episode_id: 5)
        backend = StubBackend.new(build_config, [item], qbit_info)
        backend.released = true
        store.mark_stalled(backend.name, "HASH", Time.utc - 61.minutes)
        client = FakeDownloadClient.new(["show.mkv"], snapshot: stalled_snapshot)

        events = run_janitor(backend, client, store, dry_run: true)

        backend.deleted.should be_empty
        backend.searched.should be_empty
        store.processed?(backend.name, "HASH").should be_false
        store.first_seen_stalled(backend.name, "HASH").should_not be_nil
        events.any? { |event|
          event.message.includes?("[DRY RUN] would delete + blocklist") &&
            event.message.includes?("stalled, 0 seeds")
        }.should be_true
        events.any?(&.message.includes?("[DRY RUN] would re-trigger search")).should be_true
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

  def info_for(hash : String) : ArrJanitor::DownloadClient::TorrentSnapshot
    ArrJanitor::DownloadClient::TorrentSnapshot.new(
      hash: hash, state: "downloading", num_seeds: 1)
  end
end

# Raises a specific `DownloadClient::Error` for one *failing_hash* and returns a
# bad file for anything else, exercising the janitor's download-client error
# handling while proving the scan continues past the failing item.
#
# `TorrentNotFound` is raised from `info_for` (the first lookup after the
# client is resolved). Generic errors are raised from `files_for` so the
# existing "could not list files" path stays covered once `info_for` succeeds.
private class DownloadClientErrorClient < ArrJanitor::DownloadClient
  def initialize(@failing_hash : String, @error : ArrJanitor::DownloadClient::Error)
  end

  def files_for(hash : String) : Array(String)
    raise @error if hash == @failing_hash
    ["virus.exe"]
  end

  def info_for(hash : String) : ArrJanitor::DownloadClient::TorrentSnapshot
    if hash == @failing_hash && @error.is_a?(ArrJanitor::DownloadClient::TorrentNotFound)
      raise @error
    end
    ArrJanitor::DownloadClient::TorrentSnapshot.new(
      hash: hash, state: "downloading", num_seeds: 1)
  end
end
