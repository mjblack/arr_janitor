require "./spec_helper"

# A valid single-Sonarr-backend YAML config body.
private VALID_YAML = <<-YAML
  backends:
    - name: My Sonarr
      type: sonarr
      url: http://localhost:8989
      api_key: "abc"
      extensions_filter:
        - exe
      download_clients:
        - name: qbit
          username: admin
          password: secret
  YAML

# Writes *body* to a temp file with *ext* and yields its path, cleaning up after.
private def with_config(body : String, ext = ".yml", &)
  file = File.tempfile("arrjanitor-cli", ext)
  begin
    File.write(file.path, body)
    yield file.path
  ensure
    file.delete
  end
end

# A fake download client returning canned file paths — no network.
private class FakeDownloadClient < ArrJanitor::DownloadClient
  def initialize(@files : Array(String))
  end

  def files_for(hash : String) : Array(String)
    @files
  end
end

# A minimal `Backend` with a single canned queue item and download-client info,
# recording the items it was asked to delete — enough to drive the janitor's
# bad-download path. No network.
private class StubBackend < ArrJanitor::Backend
  getter deleted = [] of ArrJanitor::QueueItem

  def initialize(@config : ArrJanitor::Config::Backend,
                 @queue : Array(ArrJanitor::QueueItem),
                 @client_info : ArrJanitor::DownloadClientInfo?)
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
    false
  end

  def delete_and_blocklist(item : ArrJanitor::QueueItem) : Nil
    @deleted << item
  end

  def search(item : ArrJanitor::QueueItem) : Nil
  end

  def download_client_info(name : String) : ArrJanitor::DownloadClientInfo?
    @client_info
  end
end

describe ArrJanitor::CLI do
  describe ".config_path" do
    it "reads a bare positional argument" do
      ArrJanitor::CLI.config_path(["config.yml"]).should eq("config.yml")
    end

    it "reads the value after --config" do
      ArrJanitor::CLI.config_path(["--config", "/etc/aj.yml"]).should eq("/etc/aj.yml")
    end

    it "reads the value after -c" do
      ArrJanitor::CLI.config_path(["-c", "/etc/aj.yml"]).should eq("/etc/aj.yml")
    end

    it "returns nil when no path is given" do
      ArrJanitor::CLI.config_path([] of String).should be_nil
    end
  end

  describe ".dry_run?" do
    it "is true when --dry-run is present" do
      ArrJanitor::CLI.dry_run?(["config.yml", "--dry-run"]).should be_true
    end

    it "is true when -n is present" do
      ArrJanitor::CLI.dry_run?(["-n", "config.yml"]).should be_true
    end

    it "is false when neither flag is present" do
      ArrJanitor::CLI.dry_run?(["config.yml"]).should be_false
    end

    it "does not confuse the dry-run flags with the config path" do
      ArrJanitor::CLI.config_path(["--dry-run", "config.yml"]).should eq("config.yml")
      ArrJanitor::CLI.config_path(["-n", "config.yml"]).should eq("config.yml")
    end

    it "combines with the config's dry_run so either enables it" do
      # flag OR config.dry_run
      (false || ArrJanitor::CLI.dry_run?(["-n"])).should be_true
      (true || ArrJanitor::CLI.dry_run?([] of String)).should be_true
      (false || ArrJanitor::CLI.dry_run?([] of String)).should be_false
    end
  end

  describe ".daemon?" do
    it "is true when --daemon is present" do
      ArrJanitor::CLI.daemon?(["config.yml", "--daemon"]).should be_true
    end

    it "is true when -d is present" do
      ArrJanitor::CLI.daemon?(["-d", "config.yml"]).should be_true
    end

    it "is false when neither flag is present" do
      ArrJanitor::CLI.daemon?(["config.yml"]).should be_false
    end

    it "does not confuse the daemon flags with the config path" do
      ArrJanitor::CLI.config_path(["--daemon", "config.yml"]).should eq("config.yml")
      ArrJanitor::CLI.config_path(["-d", "config.yml"]).should eq("config.yml")
    end
  end

  describe ".load_config" do
    it "loads and validates a valid config" do
      with_config(VALID_YAML) do |path|
        config = ArrJanitor::CLI.load_config(path)
        config.backends.size.should eq(1)
        config.backends.first.name.should eq("My Sonarr")
      end
    end

    it "raises Config::Error on an invalid (incomplete) config" do
      body = <<-YAML
        backends:
          - name: Broken
            type: sonarr
            url: http://localhost:8989
            api_key: "abc"
        YAML
      with_config(body) do |path|
        expect_raises(ArrJanitor::Config::Error) do
          ArrJanitor::CLI.load_config(path)
        end
      end
    end

    it "raises Config::Error when the file is missing" do
      expect_raises(ArrJanitor::Config::Error) do
        ArrJanitor::CLI.load_config("/nonexistent/arrjanitor.yml")
      end
    end
  end

  describe ".build_backends" do
    it "builds a SonarrBackend for a sonarr config backend" do
      config = ArrJanitor::Config.from_yaml(VALID_YAML)
      backends = ArrJanitor::CLI.build_backends(config)
      backends.size.should eq(1)
      backends.first.should be_a(ArrJanitor::SonarrBackend)
      backends.first.name.should eq("My Sonarr")
    end

    it "builds a RadarrBackend for a radarr config backend" do
      config = ArrJanitor::Config.new([
        ArrJanitor::Config::Backend.new(
          name: "My Radarr", type: ArrJanitor::Config::BackendType::Radarr,
          url: "http://localhost:7878", api_key: "k"),
      ])

      backends = ArrJanitor::CLI.build_backends(config)
      backends.size.should eq(1)
      backends.first.should be_a(ArrJanitor::RadarrBackend)
      backends.first.name.should eq("My Radarr")
    end

    it "builds both a SonarrBackend and a RadarrBackend from a mixed config" do
      config = ArrJanitor::Config.new([
        ArrJanitor::Config::Backend.new(
          name: "My Sonarr", type: ArrJanitor::Config::BackendType::Sonarr,
          url: "http://localhost:8989", api_key: "k"),
        ArrJanitor::Config::Backend.new(
          name: "My Radarr", type: ArrJanitor::Config::BackendType::Radarr,
          url: "http://localhost:7878", api_key: "k"),
      ])

      backends = ArrJanitor::CLI.build_backends(config)
      backends.map(&.name).should eq(["My Sonarr", "My Radarr"])
      backends[0].should be_a(ArrJanitor::SonarrBackend)
      backends[1].should be_a(ArrJanitor::RadarrBackend)
    end
  end

  describe ".build_store (dry-run selection)" do
    it "returns nil and creates no database file in dry-run" do
      dir = File.tempname("arr_janitor_cli_dryrun")
      Dir.mkdir_p(dir)
      db_path = File.join(dir, "dryrun.db")
      config = ArrJanitor::Config.new(database: db_path)
      begin
        ArrJanitor::CLI.build_store(config, dry_run: true).should be_nil
        # Strict dry-run must not touch the filesystem.
        File.exists?(db_path).should be_false
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "opens the store and creates the database file when not dry-run" do
      dir = File.tempname("arr_janitor_cli_dryrun")
      Dir.mkdir_p(dir)
      db_path = File.join(dir, "live.db")
      config = ArrJanitor::Config.new(database: db_path)
      begin
        store = ArrJanitor::CLI.build_store(config, dry_run: false)
        store.should be_a(ArrJanitor::Store)
        File.exists?(db_path).should be_true
        store.try &.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe ".build_store" do
    it "opens a functional store at the configured database path" do
      dir = File.tempname("arr_janitor_cli_store")
      Dir.mkdir_p(dir)
      db_path = File.join(dir, "cli.db")
      config = ArrJanitor::Config.new(database: db_path)
      begin
        store = ArrJanitor::CLI.build_store(config)
        begin
          File.exists?(db_path).should be_true
          store.record_processed("sonarr", "H", "T", "removed_blocklisted", ["exe"])
          store.processed?("sonarr", "H").should be_true
        ensure
          store.close
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "wires the store into a janitor that records processed downloads" do
      dir = File.tempname("arr_janitor_cli_store")
      Dir.mkdir_p(dir)
      db_path = File.join(dir, "cli.db")
      config = ArrJanitor::Config.new(database: db_path)
      begin
        # Open the store exactly as CLI.run does (via CLI.build_store).
        store = ArrJanitor::CLI.build_store(config)
        begin
          backend_config = ArrJanitor::Config::Backend.new(
            name: "Test Sonarr", type: ArrJanitor::Config::BackendType::Sonarr,
            url: "http://localhost:8989", api_key: "key",
            extensions_filter: ["exe"],
            download_clients: [ArrJanitor::Config::DownloadClient.new(
              name: "qbit", username: "admin", password: "secret")])
          item = ArrJanitor::QueueItem.new(
            id: 1, download_id: "HASH", download_client: "qbit", title: "Bad.Release")
          info = ArrJanitor::DownloadClientInfo.new(
            name: "qbit", implementation: "qBittorrent",
            host: "localhost", port: 8080, use_ssl: false)
          backend = StubBackend.new(backend_config, [item], info)

          # Swap the janitor's resolver for one returning a fake bad-file client.
          resolver = ArrJanitor::DownloadClientResolver.new do |_impl, _url, _key, _user, _pass|
            FakeDownloadClient.new(["show.mkv", "virus.exe"])
          end
          janitor = ArrJanitor::Janitor.new(resolver, store)

          channel = Channel(ArrJanitor::LogEvent).new(64)
          reporter = ArrJanitor::Reporter.new(channel)
          janitor.process(backend, reporter)

          backend.deleted.should eq([item])
          store.processed?("Test Sonarr", "HASH").should be_true
        ensure
          store.close
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
