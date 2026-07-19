require "yaml"
require "json"

module ArrJanitor
  # Application configuration: a list of Sonarr/Radarr backends to watch, each
  # with its own poll interval, bad-extension filter, and download-client
  # credentials. Parses from either YAML or JSON.
  class Config
    include YAML::Serializable
    include JSON::Serializable

    # Raised when a config file cannot be parsed or fails validation.
    class Error < Exception
    end

    # Which *arr flavour a backend speaks. Serialized as lowercase
    # `sonarr`/`radarr`.
    enum BackendType
      Sonarr
      Radarr

      def to_yaml(yaml : YAML::Nodes::Builder) : Nil
        yaml.scalar(to_s.downcase)
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s.downcase)
      end
    end

    # Credentials for a download client. The client's host/port/type are
    # resolved from the *arr's own download-client config (matched by `name`);
    # only the credentials live here.
    class DownloadClient
      include YAML::Serializable
      include JSON::Serializable

      property name : String
      property api_key : String?
      property username : String?
      property password : String?

      def initialize(@name : String, @api_key : String? = nil,
                     @username : String? = nil, @password : String? = nil)
      end
    end

    # A single Sonarr/Radarr instance to watch.
    class Backend
      include YAML::Serializable
      include JSON::Serializable

      # Interval when none is configured.
      DEFAULT_INTERVAL = 20.minutes

      # `<int>` followed by a `m`/`h`/`d` unit.
      INTERVAL_PATTERN = /\A(\d+)([mhd])\z/

      property name : String

      # Parsed leniently so an unknown value surfaces as a validation error
      # rather than a parse crash. `nil` means the raw value was invalid.
      @[YAML::Field(converter: ArrJanitor::Config::Backend::BackendTypeConverter)]
      @[JSON::Field(converter: ArrJanitor::Config::Backend::BackendTypeConverter)]
      property type : BackendType?

      property url : String
      property api_key : String
      property interval : String?

      @[YAML::Field(key: "extensions_filter")]
      @[JSON::Field(key: "extensions_filter")]
      property extensions_filter : Array(String) = [] of String

      @[YAML::Field(key: "download_clients")]
      @[JSON::Field(key: "download_clients")]
      property download_clients : Array(DownloadClient) = [] of DownloadClient

      def initialize(@name : String, @type : BackendType?, @url : String,
                     @api_key : String, @interval : String? = nil,
                     @extensions_filter : Array(String) = [] of String,
                     @download_clients : Array(DownloadClient) = [] of DownloadClient)
      end

      # The poll interval as a `Time::Span`. Defaults to `DEFAULT_INTERVAL`
      # when unset; raises `Config::Error` on a malformed value.
      def interval_span : Time::Span
        raw = interval
        return DEFAULT_INTERVAL if raw.nil?

        if md = INTERVAL_PATTERN.match(raw)
          amount = md[1].to_i
          case md[2]
          when "m" then amount.minutes
          when "h" then amount.hours
          when "d" then amount.days
          else          raise Error.new("invalid interval unit: #{raw.inspect}")
          end
        else
          raise Error.new("invalid interval: #{raw.inspect} (expected <int>[m|h|d])")
        end
      end

      # Whether `filename` matches any entry in `extensions_filter`. An entry
      # containing a glob metachar (`*`, `?`, `[`) is matched as a glob against
      # the basename (case-insensitive); otherwise it is treated as an
      # extension matching files ending in `.<entry>` (case-insensitive; a
      # leading `.` is tolerated).
      def matches_bad_extension?(filename : String) : Bool
        basename = File.basename(filename).downcase

        extensions_filter.any? do |entry|
          if entry.matches?(/[*?\[]/)
            File.match?(entry.downcase, basename)
          else
            ext = entry.lchop('.').downcase
            basename.ends_with?(".#{ext}")
          end
        end
      end

      # Leniently parses `BackendType`, yielding `nil` for unknown values so
      # validation can report a helpful message.
      module BackendTypeConverter
        def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : BackendType?
          unless node.is_a?(YAML::Nodes::Scalar)
            node.raise "Expected scalar, not #{node.class}"
          end
          BackendType.parse?(node.value)
        end

        def self.to_yaml(value : BackendType?, yaml : YAML::Nodes::Builder) : Nil
          value.to_yaml(yaml)
        end

        def self.from_json(pull : JSON::PullParser) : BackendType?
          BackendType.parse?(pull.read_string)
        end

        def self.to_json(value : BackendType?, json : JSON::Builder) : Nil
          value.to_json(json)
        end
      end
    end

    # Default SQLite database path when none is configured.
    DEFAULT_DATABASE = "arr_janitor.db"

    # Default retention window for `processed_downloads` audit rows.
    DEFAULT_RETENTION = 30.days

    property backends : Array(Backend) = [] of Backend

    # Optional path to the SQLite persistence database. See `#database_path`.
    property database : String?

    # Optional retention window for processed-download audit rows, as
    # `<int>[m|h|d]`. See `#retention_span`.
    property retention : String?

    # When `true`, act as a dry run: log intended deletes/blocklists/searches
    # without mutating Sonarr/qBittorrent or writing to the store. Can also be
    # enabled at runtime via the `--dry-run`/`-n` CLI flag.
    property? dry_run : Bool = false

    def initialize(@backends : Array(Backend) = [] of Backend,
                   @database : String? = nil, @retention : String? = nil,
                   @dry_run : Bool = false)
    end

    # The SQLite database path, falling back to `DEFAULT_DATABASE`.
    def database_path : String
      path = database
      (path.nil? || path.blank?) ? DEFAULT_DATABASE : path
    end

    # The retention window as a `Time::Span`. Defaults to `DEFAULT_RETENTION`
    # when unset/blank; raises `Config::Error` on a malformed value.
    def retention_span : Time::Span
      raw = retention
      return DEFAULT_RETENTION if raw.nil? || raw.blank?

      if md = Backend::INTERVAL_PATTERN.match(raw)
        amount = md[1].to_i
        case md[2]
        when "m" then amount.minutes
        when "h" then amount.hours
        when "d" then amount.days
        else          raise Error.new("invalid retention unit: #{raw.inspect}")
        end
      else
        raise Error.new("invalid retention: #{raw.inspect} (expected <int>[m|h|d])")
      end
    end

    # Loads a config from `path`. YAML wins: `.yml`/`.yaml` parse as YAML,
    # `.json` as JSON, and anything else tries YAML first then JSON.
    def self.from_file(path : String) : Config
      content = File.read(path)

      case File.extname(path).downcase
      when ".yml", ".yaml"
        from_yaml(content)
      when ".json"
        from_json(content)
      else
        begin
          from_yaml(content)
        rescue
          from_json(content)
        end
      end
    rescue ex : File::Error
      raise Error.new("cannot read config file #{path.inspect}: #{ex.message}")
    end

    # Parses a config from a YAML string.
    def self.from_yaml(string : String) : Config
      document = YAML::Nodes.parse(string)
      node = document.nodes.first? || YAML::Nodes::Scalar.new("")
      new(YAML::ParseContext.new, node)
    rescue ex : YAML::ParseException
      raise Error.new("invalid YAML config: #{ex.message}")
    end

    # Parses a config from a JSON string.
    def self.from_json(string : String) : Config
      new(JSON::PullParser.new(string))
    rescue ex : JSON::ParseException
      raise Error.new("invalid JSON config: #{ex.message}")
    end

    # Returns a list of all validation problems (empty when valid).
    def validation_errors : Array(String)
      return ["config must define at least one backend"] if backends.empty?

      errors = [] of String
      backends.each_with_index do |backend, i|
        label = backend.name.blank? ? "backend ##{i + 1}" : "backend #{backend.name.inspect}"
        validate_backend(backend, label, errors)
      end
      errors
    end

    private def validate_backend(backend : Backend, label : String, errors : Array(String)) : Nil
      errors << "#{label}: name is required" if backend.name.blank?
      errors << "#{label}: url is required" if backend.url.blank?
      errors << "#{label}: api_key is required" if backend.api_key.blank?
      errors << "#{label}: type must be one of sonarr, radarr" if backend.type.nil?

      if (raw = backend.interval) && !raw.matches?(Backend::INTERVAL_PATTERN)
        errors << "#{label}: interval #{raw.inspect} is invalid (expected <int>[m|h|d])"
      end

      errors << "#{label}: extensions_filter must not be empty" if backend.extensions_filter.empty?
      errors << "#{label}: at least one download_client is required" if backend.download_clients.empty?

      backend.download_clients.each_with_index do |client, j|
        validate_client(client, label, j, errors)
      end
    end

    private def validate_client(client : DownloadClient, label : String, index : Int32, errors : Array(String)) : Nil
      client_label = client.name.blank? ? "download_client ##{index + 1}" : "download_client #{client.name.inspect}"
      errors << "#{label}: #{client_label}: name is required" if client.name.blank?

      has_api_key = present?(client.api_key)
      has_user_pass = present?(client.username) && present?(client.password)
      unless has_api_key || has_user_pass
        errors << "#{label}: #{client_label}: requires api_key or both username and password"
      end
    end

    # Whether an optional string is present and non-blank.
    private def present?(value : String?) : Bool
      !(value.nil? || value.blank?)
    end

    # Validates the config, raising `Config::Error` listing all problems.
    # Returns `self` when valid.
    def validate : self
      errors = validation_errors
      unless errors.empty?
        raise Error.new("invalid config:\n  - #{errors.join("\n  - ")}")
      end
      self
    end
  end
end
