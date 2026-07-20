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

# Runs the block with `ARR_JANITOR_LOG_LEVEL` set to *value* (or unset when nil),
# restoring the prior value afterwards so tests don't leak env state.
private def with_env_log_level(value : String?, &)
  previous = ENV["ARR_JANITOR_LOG_LEVEL"]?
  if value.nil?
    ENV.delete("ARR_JANITOR_LOG_LEVEL")
  else
    ENV["ARR_JANITOR_LOG_LEVEL"] = value
  end
  begin
    yield
  ensure
    if previous.nil?
      ENV.delete("ARR_JANITOR_LOG_LEVEL")
    else
      ENV["ARR_JANITOR_LOG_LEVEL"] = previous
    end
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

    it "defaults to config.yml (in CWD) when no path is given" do
      ArrJanitor::CLI.config_path([] of String).should eq("config.yml")
    end

    it "does not treat a --database/-D value as the config path" do
      # -D takes a value; with no positional the config must fall back to the
      # default, NOT be the database path.
      ArrJanitor::CLI.config_path(["-D", "/data/db.sqlite"]).should eq("config.yml")
      ArrJanitor::CLI.config_path(["--database", "/data/db.sqlite"]).should eq("config.yml")
    end

    it "reads the positional config even when a -D value precedes it" do
      ArrJanitor::CLI.config_path(["-D", "/data/db.sqlite", "config.yml"]).should eq("config.yml")
    end
  end

  describe ".database_arg" do
    it "reads the value after --database" do
      ArrJanitor::CLI.database_arg(["--database", "/data/db.sqlite"]).should eq("/data/db.sqlite")
    end

    it "reads the value after -D" do
      ArrJanitor::CLI.database_arg(["-D", "/data/db.sqlite"]).should eq("/data/db.sqlite")
    end

    it "returns nil when no --database/-D flag is given" do
      ArrJanitor::CLI.database_arg(["config.yml"]).should be_nil
      ArrJanitor::CLI.database_arg([] of String).should be_nil
    end

    it "is not confused with the daemon flag (-d vs -D)" do
      ArrJanitor::CLI.database_arg(["-d", "config.yml"]).should be_nil
      ArrJanitor::CLI.daemon?(["-D", "/data/db.sqlite"]).should be_false
    end
  end

  describe "database path precedence" do
    # Resolves exactly as CLI.run does: --database/-D overrides config database:,
    # which falls back to DEFAULT_DATABASE.
    private_resolve = ->(argv : Array(String), config : ArrJanitor::Config) do
      ArrJanitor::CLI.database_arg(argv) || config.database_path
    end

    it "uses the --database override when given, over the config value" do
      config = ArrJanitor::Config.new(database: "config.db")
      private_resolve.call(["-D", "/override.db"], config).should eq("/override.db")
    end

    it "uses the config database: value when no --database is given" do
      config = ArrJanitor::Config.new(database: "config.db")
      private_resolve.call([] of String, config).should eq("config.db")
    end

    it "falls back to arr_janitor.db when neither is given" do
      config = ArrJanitor::Config.new
      private_resolve.call([] of String, config).should eq("arr_janitor.db")
    end
  end

  describe ".log_level_arg" do
    it "reads the value after --log-level" do
      ArrJanitor::CLI.log_level_arg(["--log-level", "debug"]).should eq("debug")
    end

    it "reads the value after -l" do
      ArrJanitor::CLI.log_level_arg(["-l", "warn"]).should eq("warn")
    end

    it "returns nil when no --log-level/-l flag is given" do
      ArrJanitor::CLI.log_level_arg(["config.yml"]).should be_nil
      ArrJanitor::CLI.log_level_arg([] of String).should be_nil
    end

    it "is not confused with the daemon/dry-run flags" do
      ArrJanitor::CLI.log_level_arg(["-d", "config.yml"]).should be_nil
      ArrJanitor::CLI.log_level_arg(["-n", "config.yml"]).should be_nil
    end

    it "does not treat a -l value as the config path" do
      # -l takes a value; with no positional the config must fall back to the
      # default, NOT be the log level.
      ArrJanitor::CLI.config_path(["-l", "debug"]).should eq("config.yml")
      ArrJanitor::CLI.config_path(["--log-level", "debug"]).should eq("config.yml")
    end

    it "reads the positional config even when a -l value precedes it" do
      ArrJanitor::CLI.config_path(["-l", "debug", "config.yml"]).should eq("config.yml")
    end
  end

  describe ".resolve_log_level" do
    it "defaults to Info when no source is set" do
      with_env_log_level(nil) do
        config = ArrJanitor::Config.new
        ArrJanitor::CLI.resolve_log_level([] of String, config).should eq(::Log::Severity::Info)
      end
    end

    it "uses the config log_level when neither CLI nor env is set" do
      with_env_log_level(nil) do
        config = ArrJanitor::Config.new(log_level: "error")
        ArrJanitor::CLI.resolve_log_level([] of String, config).should eq(::Log::Severity::Error)
      end
    end

    it "prefers the env var over the config log_level" do
      with_env_log_level("warn") do
        config = ArrJanitor::Config.new(log_level: "error")
        ArrJanitor::CLI.resolve_log_level([] of String, config).should eq(::Log::Severity::Warn)
      end
    end

    it "prefers the CLI flag over the env var and config" do
      with_env_log_level("warn") do
        config = ArrJanitor::Config.new(log_level: "error")
        ArrJanitor::CLI.resolve_log_level(["-l", "debug"], config).should eq(::Log::Severity::Debug)
      end
    end

    it "parses case-insensitively" do
      with_env_log_level(nil) do
        config = ArrJanitor::Config.new
        ArrJanitor::CLI.resolve_log_level(["--log-level", "TRACE"], config).should eq(::Log::Severity::Trace)
      end
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
      begin
        ArrJanitor::CLI.build_store(dry_run: true, path: db_path).should be_nil
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
      begin
        store = ArrJanitor::CLI.build_store(dry_run: false, path: db_path)
        store.should be_a(ArrJanitor::Store)
        File.exists?(db_path).should be_true
        store.try &.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe ".build_store" do
    it "opens a functional store at the given database path" do
      dir = File.tempname("arr_janitor_cli_store")
      Dir.mkdir_p(dir)
      db_path = File.join(dir, "cli.db")
      begin
        store = ArrJanitor::CLI.build_store(dry_run: false, path: db_path).as(ArrJanitor::Store)
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
      begin
        # Open the store exactly as CLI.run does (via CLI.build_store).
        store = ArrJanitor::CLI.build_store(dry_run: false, path: db_path).as(ArrJanitor::Store)
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
