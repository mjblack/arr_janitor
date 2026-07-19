require "./spec_helper"

private VALID_YAML = <<-YAML
  backends:
    - name: My Sonarr
      type: sonarr
      url: http://localhost:8080
      api_key: "12355677757"
      interval: 30m
      extensions_filter:
        - scr
        - exe
        - "*.lnk"
      download_clients:
        - name: My qbittorrent
          username: admin
          password: password
  YAML

private VALID_JSON = <<-JSON
  {
    "backends": [
      {
        "name": "My Sonarr",
        "type": "sonarr",
        "url": "http://localhost:8080",
        "api_key": "12355677757",
        "interval": "2h",
        "extensions_filter": ["scr", "exe", "*.lnk"],
        "download_clients": [
          { "name": "My qbittorrent", "api_key": "abc123" }
        ]
      }
    ]
  }
  JSON

describe ArrJanitor::Config do
  describe ".from_yaml" do
    it "loads a valid config" do
      config = ArrJanitor::Config.from_yaml(VALID_YAML)
      config.backends.size.should eq(1)

      backend = config.backends.first
      backend.name.should eq("My Sonarr")
      backend.type.should eq(ArrJanitor::Config::BackendType::Sonarr)
      backend.url.should eq("http://localhost:8080")
      backend.api_key.should eq("12355677757")
      backend.interval.should eq("30m")
      backend.extensions_filter.should eq(["scr", "exe", "*.lnk"])
      backend.download_clients.size.should eq(1)
      backend.download_clients.first.username.should eq("admin")
      backend.download_clients.first.password.should eq("password")

      config.validation_errors.should be_empty
    end

    it "defaults dry_run to false when omitted" do
      config = ArrJanitor::Config.from_yaml(VALID_YAML)
      config.dry_run?.should be_false
    end

    it "parses dry_run: true" do
      body = VALID_YAML + "\ndry_run: true\n"
      config = ArrJanitor::Config.from_yaml(body)
      config.dry_run?.should be_true
    end

    it "raises Config::Error on malformed YAML" do
      expect_raises(ArrJanitor::Config::Error, /invalid YAML/) do
        ArrJanitor::Config.from_yaml("backends: [ : : :")
      end
    end
  end

  describe ".from_json" do
    it "loads a valid config" do
      config = ArrJanitor::Config.from_json(VALID_JSON)
      config.backends.size.should eq(1)

      backend = config.backends.first
      backend.type.should eq(ArrJanitor::Config::BackendType::Sonarr)
      backend.interval.should eq("2h")
      backend.download_clients.first.api_key.should eq("abc123")

      config.validation_errors.should be_empty
    end

    it "raises Config::Error on malformed JSON" do
      expect_raises(ArrJanitor::Config::Error, /invalid JSON/) do
        ArrJanitor::Config.from_json("{ not json")
      end
    end
  end

  describe ".from_file" do
    it "loads YAML by extension" do
      with_tempfile("cfg.yml", VALID_YAML) do |path|
        config = ArrJanitor::Config.from_file(path)
        config.backends.first.name.should eq("My Sonarr")
      end
    end

    it "loads JSON by extension" do
      with_tempfile("cfg.json", VALID_JSON) do |path|
        config = ArrJanitor::Config.from_file(path)
        config.backends.first.interval.should eq("2h")
      end
    end

    it "falls back through YAML then JSON for an unknown extension" do
      with_tempfile("cfg.conf", VALID_JSON) do |path|
        config = ArrJanitor::Config.from_file(path)
        config.backends.first.name.should eq("My Sonarr")
      end
    end
  end

  describe "#interval_span" do
    it "parses minutes" do
      build_backend(interval: "30m").interval_span.should eq(30.minutes)
    end

    it "parses hours" do
      build_backend(interval: "2h").interval_span.should eq(2.hours)
    end

    it "parses days" do
      build_backend(interval: "1d").interval_span.should eq(1.day)
    end

    it "defaults to 20 minutes when nil" do
      build_backend(interval: nil).interval_span.should eq(20.minutes)
    end

    it "raises on an invalid value" do
      expect_raises(ArrJanitor::Config::Error, /invalid interval/) do
        build_backend(interval: "5x").interval_span
      end
    end
  end

  describe "#retention_span" do
    it "parses minutes/hours/days" do
      ArrJanitor::Config.new(retention: "90m").retention_span.should eq(90.minutes)
      ArrJanitor::Config.new(retention: "12h").retention_span.should eq(12.hours)
      ArrJanitor::Config.new(retention: "7d").retention_span.should eq(7.days)
    end

    it "defaults to 30 days when nil or blank" do
      ArrJanitor::Config.new(retention: nil).retention_span.should eq(30.days)
      ArrJanitor::Config.new(retention: "").retention_span.should eq(30.days)
    end

    it "raises on a malformed value" do
      expect_raises(ArrJanitor::Config::Error, /invalid retention/) do
        ArrJanitor::Config.new(retention: "soon").retention_span
      end
    end
  end

  describe "#database_path" do
    it "returns the configured path" do
      ArrJanitor::Config.new(database: "/var/lib/arr_janitor.db").database_path
        .should eq("/var/lib/arr_janitor.db")
    end

    it "falls back to the default when nil or blank" do
      ArrJanitor::Config.new(database: nil).database_path.should eq("arr_janitor.db")
      ArrJanitor::Config.new(database: "").database_path.should eq("arr_janitor.db")
    end
  end

  describe "#matches_bad_extension?" do
    it "matches a bare extension" do
      backend = build_backend(extensions_filter: ["scr"])
      backend.matches_bad_extension?("foo.scr").should be_true
    end

    it "matches a bare extension with a leading dot in the entry" do
      backend = build_backend(extensions_filter: [".exe"])
      backend.matches_bad_extension?("baz.EXE").should be_true
    end

    it "matches a glob against the basename" do
      backend = build_backend(extensions_filter: ["*.lnk"])
      backend.matches_bad_extension?("/downloads/bar.lnk").should be_true
    end

    it "matches case-insensitively" do
      backend = build_backend(extensions_filter: ["SCR"])
      backend.matches_bad_extension?("Foo.Scr").should be_true
    end

    it "does not match unrelated files" do
      backend = build_backend(extensions_filter: ["scr", "*.lnk"])
      backend.matches_bad_extension?("movie.mkv").should be_false
    end

    it "does not match an extension appearing mid-name" do
      backend = build_backend(extensions_filter: ["scr"])
      backend.matches_bad_extension?("descriptor.txt").should be_false
    end
  end

  describe "#validate" do
    it "returns self for a valid config" do
      config = ArrJanitor::Config.from_yaml(VALID_YAML)
      config.validate.should be(config)
    end

    it "fails when there are no backends" do
      config = ArrJanitor::Config.new
      config.validation_errors.first.should match(/at least one backend/)
    end

    it "fails when api_key is missing" do
      backend = build_backend(api_key: "")
      config = ArrJanitor::Config.new([backend])
      config.validation_errors.any?(&.includes?("api_key is required")).should be_true
    end

    it "fails a download client with neither api_key nor username+password" do
      client = ArrJanitor::Config::DownloadClient.new(name: "qbit")
      backend = build_backend(download_clients: [client])
      errors = config_with(backend).validation_errors
      errors.any?(&.includes?("requires api_key or both username and password")).should be_true
      errors.any?(&.includes?("qbit")).should be_true
    end

    it "accepts a download client with only username + password" do
      client = ArrJanitor::Config::DownloadClient.new(name: "qbit", username: "u", password: "p")
      backend = build_backend(download_clients: [client])
      config_with(backend).validation_errors.should be_empty
    end

    it "fails on an invalid type" do
      yaml = VALID_YAML.gsub("type: sonarr", "type: plex")
      config = ArrJanitor::Config.from_yaml(yaml)
      config.validation_errors.any?(&.includes?("type must be one of")).should be_true
    end

    it "fails on an empty extensions_filter" do
      backend = build_backend(extensions_filter: [] of String)
      config_with(backend).validation_errors.any?(&.includes?("extensions_filter must not be empty")).should be_true
    end

    it "fails when there are no download clients" do
      backend = build_backend(download_clients: [] of ArrJanitor::Config::DownloadClient)
      config_with(backend).validation_errors.any?(&.includes?("at least one download_client")).should be_true
    end

    it "fails on a malformed interval" do
      backend = build_backend(interval: "soon")
      config_with(backend).validation_errors.any?(&.includes?("interval")).should be_true
    end

    it "raises Config::Error listing all problems" do
      backend = build_backend(api_key: "", extensions_filter: [] of String)
      expect_raises(ArrJanitor::Config::Error, /invalid config/) do
        config_with(backend).validate
      end
    end
  end
end

private def build_backend(
  name : String = "My Sonarr",
  type : ArrJanitor::Config::BackendType? = ArrJanitor::Config::BackendType::Sonarr,
  url : String = "http://localhost:8080",
  api_key : String = "key",
  interval : String? = nil,
  extensions_filter : Array(String) = ["scr"],
  download_clients : Array(ArrJanitor::Config::DownloadClient) = [default_client],
) : ArrJanitor::Config::Backend
  ArrJanitor::Config::Backend.new(
    name: name, type: type, url: url, api_key: api_key,
    interval: interval, extensions_filter: extensions_filter,
    download_clients: download_clients,
  )
end

private def default_client : ArrJanitor::Config::DownloadClient
  ArrJanitor::Config::DownloadClient.new(name: "qbit", api_key: "abc")
end

private def config_with(backend : ArrJanitor::Config::Backend) : ArrJanitor::Config
  ArrJanitor::Config.new([backend])
end

private def with_tempfile(name : String, content : String, &)
  path = File.join(Dir.tempdir, "#{Random.rand(UInt32)}_#{name}")
  File.write(path, content)
  begin
    yield path
  ensure
    File.delete?(path)
  end
end
