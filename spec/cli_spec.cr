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

    it "skips a radarr backend (not yet supported)" do
      config = ArrJanitor::Config.new([
        ArrJanitor::Config::Backend.new(
          name: "My Sonarr", type: ArrJanitor::Config::BackendType::Sonarr,
          url: "http://localhost:8989", api_key: "k"),
        ArrJanitor::Config::Backend.new(
          name: "My Radarr", type: ArrJanitor::Config::BackendType::Radarr,
          url: "http://localhost:7878", api_key: "k"),
      ])

      backends = ArrJanitor::CLI.build_backends(config)
      backends.map(&.name).should eq(["My Sonarr"])
    end

    it "returns an empty array when only unsupported backends are configured" do
      config = ArrJanitor::Config.new([
        ArrJanitor::Config::Backend.new(
          name: "My Radarr", type: ArrJanitor::Config::BackendType::Radarr,
          url: "http://localhost:7878", api_key: "k"),
      ])

      ArrJanitor::CLI.build_backends(config).should be_empty
    end
  end
end
