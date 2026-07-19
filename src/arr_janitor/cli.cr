require "log"

module ArrJanitor
  # Command-line entrypoint: parses the config path, loads + validates the
  # config, builds a `Backend` per configured backend, and hands them to the
  # `Scheduler`.
  #
  # The loading/building steps are factored into `load_config` and
  # `build_backends` so they can be unit-tested without starting the (long
  # running) scheduler.
  module CLI
    # `Log` source for CLI-phase messages (config load, backend construction).
    # These run on the main fiber before the scheduler exists, so they go
    # straight to `Log` rather than through the worker `Reporter`.
    LOG = ::Log.for("arr_janitor.cli")

    # Parses *argv*, loads + validates the config, builds the backends and runs
    # the scheduler. Prints config errors to STDERR and exits non-zero.
    def self.run(argv : Array(String)) : Nil
      path = config_path(argv)
      if path.nil?
        STDERR.puts "usage: arr_janitor <config.yml> | --config <path>"
        exit 1
      end

      config =
        begin
          load_config(path)
        rescue ex : Config::Error
          STDERR.puts ex.message
          exit 1
        end

      ArrJanitor.setup_logging

      backends = build_backends(config)
      if backends.empty?
        LOG.warn { "no supported backends configured; nothing to do, exiting" }
        return
      end

      Scheduler.new(backends).run
    end

    # Extracts the config path from *argv*: a bare first argument, or the value
    # following `--config`/`-c`. Returns `nil` when none is given.
    def self.config_path(argv : Array(String)) : String?
      argv.each_with_index do |arg, i|
        case arg
        when "--config", "-c"
          return argv[i + 1]?
        else
          return arg unless arg.starts_with?('-')
        end
      end
      nil
    end

    # Loads and validates the config at *path*. Raises `Config::Error` on a
    # missing/unparseable file or a validation failure.
    def self.load_config(path : String) : Config
      Config.from_file(path).validate
    end

    # Builds a concrete `Backend` for each configured backend. `sonarr` backends
    # become `SonarrBackend`s; `radarr` backends are logged and skipped (not yet
    # supported). Returns the built backends.
    def self.build_backends(config : Config) : Array(Backend)
      backends = [] of Backend

      config.backends.each do |backend_config|
        case backend_config.type
        when Config::BackendType::Sonarr
          backends << SonarrBackend.new(backend_config)
        when Config::BackendType::Radarr
          LOG.info { "radarr backend #{backend_config.name.inspect} not yet supported, skipping" }
        else
          # A nil type is rejected by validation, so this is unreachable in
          # practice; skip defensively rather than crash.
          LOG.warn { "backend #{backend_config.name.inspect} has no recognised type, skipping" }
        end
      end

      backends
    end
  end
end
