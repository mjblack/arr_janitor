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

    # Config path used when neither `--config`/`-c` nor a bare positional is
    # given — a `config.yml` in the current working directory.
    DEFAULT_CONFIG = "config.yml"

    # Environment variable holding the log level. Sits below `-l`/`--log-level`
    # but above the config's `log_level:` in the precedence chain.
    LOG_LEVEL_ENV = "ARR_JANITOR_LOG_LEVEL"

    # One-line usage string, printed for `-h`/`--help` and on parse errors.
    USAGE = "usage: arr_janitor [<config.yml> | -c|--config <path>] " \
            "[-D|--database <path>] [-l|--log-level <level>] " \
            "[-d|--daemon] [-n|--dry-run] [-h|--help]"

    # Parses *argv*, loads + validates the config, builds the backends and runs
    # the scheduler. Prints config errors to STDERR and exits non-zero.
    def self.run(argv : Array(String)) : Nil
      if help?(argv)
        puts USAGE
        exit 0
      end

      config =
        begin
          load_config(config_path(argv))
        rescue ex : Config::Error
          STDERR.puts ex.message
          exit 1
        end

      ArrJanitor.setup_logging(resolve_log_level(argv, config))

      backends = build_backends(config)
      if backends.empty?
        LOG.warn { "no supported backends configured; nothing to do, exiting" }
        return
      end

      effective_dry_run = config.dry_run? || dry_run?(argv)
      if effective_dry_run
        LOG.warn { "DRY RUN enabled — no downloads will be deleted, blocklisted, or searched" }
      end

      # Precedence: `--database`/`-D` overrides the config's `database:`, which
      # in turn falls back to `DEFAULT_DATABASE`.
      db_path = database_arg(argv) || config.database_path

      # In dry-run the store is never opened, so no database file is created and
      # the retention-sweep fiber never starts (a nil store/retention is a no-op
      # in `Scheduler`). Only log the persistence path when a store is opened.
      store =
        begin
          build_store(effective_dry_run, db_path)
        rescue ex : Store::Error
          STDERR.puts ex.message
          exit 1
        end
      LOG.info { "persistence database: #{db_path}" } unless store.nil?

      janitor = Janitor.new(store: store, dry_run: effective_dry_run)
      scheduler = Scheduler.new(backends, janitor,
        store: store,
        retention: store.nil? ? nil : config.retention_span)

      # Default: a single scan pass over every backend, then exit. `-d`/`--daemon`
      # runs the continuous scheduler (fiber-per-backend loop, retention sweep,
      # graceful shutdown on SIGINT/SIGTERM).
      if daemon?(argv)
        scheduler.run
      else
        scheduler.run_once
      end
    end

    # Selects the `Store` for this run: `nil` in dry-run (strictly read-only, so
    # no database file is created), otherwise the store opened (creating if
    # necessary) at *path*. Factored out so the store wiring is unit-testable
    # without starting the scheduler.
    def self.build_store(dry_run : Bool, path : String) : Store?
      return nil if dry_run
      Store.open(path)
    end

    # The value-taking flags. The argument immediately after one of these is
    # that flag's value, so it must never be mistaken for the bare positional
    # config path (nor for a boolean flag). Note the case distinction: `-D` is
    # `--database` (a value flag) while `-d` is `--daemon` (a boolean flag).
    VALUE_FLAGS = {"--config", "-c", "--database", "-D", "--log-level", "-l"}

    # The resolved config path from *argv*: an explicit `--config`/`-c` value or,
    # failing that, the first bare positional argument, defaulting to
    # `DEFAULT_CONFIG`. The argument following any value flag (e.g. a `-D`/
    # `--database` path) is skipped, never returned as the config path.
    def self.config_path(argv : Array(String)) : String
      i = 0
      while i < argv.size
        arg = argv[i]
        if arg == "--config" || arg == "-c"
          value = argv[i + 1]?
          return value unless value.nil?
        elsif VALUE_FLAGS.includes?(arg)
          i += 1 # skip this value flag's value
        elsif !arg.starts_with?('-')
          return arg
        end
        i += 1
      end
      DEFAULT_CONFIG
    end

    # The `--database`/`-D` override from *argv*, or `nil` when absent. When set
    # it takes precedence over the config's `database:` value. The value after a
    # `-c`/`--config` is skipped so a config path that happens to look like `-D`
    # is not mistaken for this flag.
    def self.database_arg(argv : Array(String)) : String?
      i = 0
      while i < argv.size
        arg = argv[i]
        if arg == "--database" || arg == "-D"
          return argv[i + 1]?
        elsif VALUE_FLAGS.includes?(arg)
          i += 1 # skip this value flag's value
        end
        i += 1
      end
      nil
    end

    # The `--log-level`/`-l` value from *argv*, or `nil` when absent. The value
    # after another value flag (e.g. a `-c`/`--config` path) is skipped so it is
    # never mistaken for the log level. `-l` is distinct from `-d`/`-D`/`-n`.
    def self.log_level_arg(argv : Array(String)) : String?
      i = 0
      while i < argv.size
        arg = argv[i]
        if arg == "--log-level" || arg == "-l"
          return argv[i + 1]?
        elsif VALUE_FLAGS.includes?(arg)
          i += 1 # skip this value flag's value
        end
        i += 1
      end
      nil
    end

    # Resolves the effective log level from *argv* and *config*, applying the
    # precedence (highest first): `-l`/`--log-level` → `ARR_JANITOR_LOG_LEVEL`
    # env → config `log_level:` → `Info`. The first non-blank source wins and is
    # parsed via `ArrJanitor.parse_log_level?`; an invalid value from that source
    # prints a clear error to STDERR listing the valid levels and exits `1`
    # (matching how `run` handles config/store errors) rather than silently
    # falling back. Returns `Info` when every source is nil/blank.
    def self.resolve_log_level(argv : Array(String), config : Config) : ::Log::Severity
      chosen =
        first_present(log_level_arg(argv)) ||
          first_present(ENV[LOG_LEVEL_ENV]?) ||
          first_present(config.log_level)

      return ::Log::Severity::Info if chosen.nil?

      if level = ArrJanitor.parse_log_level?(chosen)
        level
      else
        STDERR.puts "invalid log level #{chosen.inspect} (valid: #{LOG_LEVEL_NAMES})"
        exit 1
      end
    end

    # Returns *value* stripped when it is non-nil and non-blank, else `nil`.
    private def self.first_present(value : String?) : String?
      return nil if value.nil?
      stripped = value.strip
      stripped.blank? ? nil : stripped
    end

    # Whether *argv* requests a dry run via `--dry-run`/`-n`. Combined with the
    # config's own `dry_run` (either enables it) in `run`.
    def self.dry_run?(argv : Array(String)) : Bool
      argv.any? { |arg| arg == "--dry-run" || arg == "-n" }
    end

    # Whether *argv* requests daemon (continuous) mode via `--daemon`/`-d`.
    # When absent the CLI runs a single scan pass and exits.
    def self.daemon?(argv : Array(String)) : Bool
      argv.any? { |arg| arg == "--daemon" || arg == "-d" }
    end

    # Whether *argv* requests the usage message via `--help`/`-h`.
    def self.help?(argv : Array(String)) : Bool
      argv.any? { |arg| arg == "--help" || arg == "-h" }
    end

    # Loads and validates the config at *path*. Raises `Config::Error` on a
    # missing/unparseable file or a validation failure.
    def self.load_config(path : String) : Config
      Config.from_file(path).validate
    end

    # Builds a concrete `Backend` for each configured backend. `sonarr` backends
    # become `SonarrBackend`s and `radarr` backends become `RadarrBackend`s.
    # Returns the built backends.
    def self.build_backends(config : Config) : Array(Backend)
      backends = [] of Backend

      config.backends.each do |backend_config|
        case backend_config.type
        when Config::BackendType::Sonarr
          backends << SonarrBackend.new(backend_config)
        when Config::BackendType::Radarr
          backends << RadarrBackend.new(backend_config)
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
