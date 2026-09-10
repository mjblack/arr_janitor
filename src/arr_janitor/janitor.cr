module ArrJanitor
  # Builds a `DownloadClient` from an *arr download-client implementation name,
  # its resolved base URL, and the matched credentials. Injected into `Janitor`
  # so the queue-processing pipeline can be unit-tested without constructing a
  # real network client; the default delegates to `DownloadClient.build`.
  alias DownloadClientResolver = Proc(String, String, String?, String?, String?, DownloadClient?)

  # Processes a single backend's download queue, removing and blocklisting any
  # download that contains a bad file extension and re-triggering a search when
  # the episode/movie has already been released.
  #
  # Download-client construction is injected via a `DownloadClientResolver` so
  # the pipeline is testable offline; by default it delegates to
  # `DownloadClient.build`.
  class Janitor
    # The default resolver: delegates straight to `DownloadClient.build`.
    DEFAULT_RESOLVER = DownloadClientResolver.new do |implementation, base_url, api_key, username, password|
      DownloadClient.build(implementation, base_url, api_key, username, password)
    end

    # Optional persistence for the processed-download audit log. When `nil`
    # (the default) recording is a no-op, so the pipeline runs unchanged.
    #
    # When `dry_run` is `true`, the read path is unchanged but no mutation is
    # performed: intended deletes/blocklists/searches are logged with a
    # `[DRY RUN]` prefix and nothing is written to the store.
    def initialize(@resolver : DownloadClientResolver = DEFAULT_RESOLVER,
                   @store : Store? = nil, @dry_run : Bool = false)
    end

    # Scans `backend.queue`, acting on each item. Every item is processed inside
    # its own `begin/rescue`, so a failure on one item is logged via *reporter*
    # and the scan continues with the rest.
    def process(backend : Backend, reporter : Reporter) : Nil
      source = "arr_janitor.backend.#{backend.name}"

      backend.queue.each do |item|
        process_item(backend, item, reporter, source)
      rescue ex
        reporter.error(source, "error processing queue item #{item.title.inspect}", ex)
      end
    end

    private def process_item(backend : Backend, item : QueueItem,
                             reporter : Reporter, source : String) : Nil
      name = item.download_client
      if name.nil?
        reporter.info(source, "queue item #{item.title.inspect} has no download client; skipping")
        return
      end

      client = resolve_client(backend, reporter, source, name)
      return unless client

      hash = item.download_id
      return if hash.nil?

      snapshot = fetch_snapshot(client, hash, item, name, reporter, source)
      return unless snapshot

      return if consider_metadata(backend, item, reporter, source, hash, snapshot)

      files = fetch_files(client, hash, item, name, reporter, source)
      return unless files

      bad = files.select { |path| backend.config.matches_bad_extension?(path) }
      if bad.empty?
        reporter.debug(source, "clean download #{item.title.inspect}")
        return
      end

      reporter.warn(source, "bad extension(s) in '#{item.title}': #{bad.join(", ")}")
      act_or_dry_run(backend, item, reporter, source, hash, bad, "removed_blocklisted",
        "bad: #{bad.join(", ")}")
    end

    # Resolves the download client named *name*, logging and returning `nil`
    # when the *arr doesn't know it, credentials are missing, or the
    # implementation is unsupported.
    private def resolve_client(backend : Backend, reporter : Reporter,
                               source : String, name : String) : DownloadClient?
      info = backend.download_client_info(name)
      if info.nil?
        reporter.warn(source, "download client #{name.inspect} not found in #{backend.name}")
        return nil
      end

      creds = backend.config.download_clients.find { |candidate| candidate.name == name }
      if creds.nil?
        reporter.warn(source, "no configured credentials for '#{name}'")
        return nil
      end

      client = @resolver.call(info.implementation, info.base_url, creds.api_key, creds.username, creds.password)
      if client.nil?
        reporter.info(source, "unsupported download client implementation '#{info.implementation}'")
        return nil
      end

      client
    end

    private def fetch_snapshot(client : DownloadClient, hash : String, item : QueueItem,
                               client_name : String, reporter : Reporter,
                               source : String) : DownloadClient::TorrentSnapshot?
      client.info_for(hash)
    rescue DownloadClient::TorrentNotFound
      reporter.warn(source, "torrent for #{item.title.inspect} not found in '#{client_name}'; skipping")
      nil
    rescue ex : DownloadClient::Error
      reporter.warn(source, "could not inspect torrent for #{item.title.inspect} from '#{client_name}': #{ex.message}; skipping")
      nil
    end

    private def fetch_files(client : DownloadClient, hash : String, item : QueueItem,
                            client_name : String, reporter : Reporter,
                            source : String) : Array(String)?
      client.files_for(hash)
    rescue DownloadClient::TorrentNotFound
      reporter.warn(source, "torrent for #{item.title.inspect} not found in '#{client_name}'; skipping")
      nil
    rescue ex : DownloadClient::Error
      reporter.warn(source, "could not list files for #{item.title.inspect} from '#{client_name}': #{ex.message}; skipping")
      nil
    end

    # Metadata-downloading cleanup. Returns `true` when the item is fully
    # handled (acted on, or still waiting out the timeout) so `files_for`
    # must be skipped. A torrent that has left `metaDL` has its leftover
    # first-seen clock cleared, then falls through (`false`).
    private def consider_metadata(backend : Backend, item : QueueItem,
                                  reporter : Reporter, source : String,
                                  hash : String,
                                  snapshot : DownloadClient::TorrentSnapshot) : Bool
      if backend.config.metadata_downloading_enabled? && snapshot.metadata_downloading?
        timeout = backend.config.metadata_downloading_timeout
        elapsed = metadata_elapsed(snapshot, backend.name, hash)

        if (waited = elapsed) && waited >= timeout
          reporter.warn(source,
            "'#{item.title}' stuck downloading metadata for #{format_duration(waited)} (timeout #{format_duration(timeout)})")
          act_or_dry_run(backend, item, reporter, source, hash, [] of String,
            "removed_blocklisted_metadata", "stuck downloading metadata")
          return true
        end

        unless @dry_run
          @store.try &.mark_metadata(backend.name, hash)
        end
        waited_text = elapsed ? " for #{format_duration(elapsed)}" : ""
        reporter.debug(source,
          "'#{item.title}' downloading metadata#{waited_text} (timeout #{format_duration(timeout)}); waiting")
        return true
      end

      unless @dry_run
        if (store = @store) && store.first_seen_metadata(backend.name, hash)
          store.clear_metadata(backend.name, hash)
        end
      end
      false
    end

    # Elapsed time in metadata-download: prefer `added_on`, else the store's
    # first-seen clock. `nil` means we have no clock yet (first sight without
    # `added_on`).
    private def metadata_elapsed(snapshot : DownloadClient::TorrentSnapshot,
                                 backend_name : String, hash : String) : Time::Span?
      now = Time.utc
      if added_on = snapshot.added_on
        now - added_on
      elsif first_seen = @store.try &.first_seen_metadata(backend_name, hash)
        now - first_seen
      else
        nil
      end
    end

    # Compact duration for log lines (`15m`, `2h`, `1d`) matching the config
    # interval syntax.
    private def format_duration(span : Time::Span) : String
      minutes = span.total_minutes.to_i
      if minutes >= 1440 && minutes.divisible_by?(1440)
        "#{minutes // 1440}d"
      elsif minutes >= 60 && minutes.divisible_by?(60)
        "#{minutes // 60}h"
      else
        "#{minutes}m"
      end
    end

    # Dispatches to `act` or `act_dry_run` based on `@dry_run`. `reason` is the
    # parenthetical used only on the dry-run log line.
    private def act_or_dry_run(backend : Backend, item : QueueItem,
                               reporter : Reporter, source : String,
                               hash : String, matched : Array(String),
                               action : String, reason : String) : Nil
      if @dry_run
        act_dry_run(backend, item, reporter, source, reason)
      else
        act(backend, item, reporter, source, hash, matched, action)
      end
    end

    # The mutating action path: delete + blocklist, record to the store, and
    # re-trigger a search when the episode/movie has already been released.
    # `action` is the `processed_downloads` action string; `matched` is the
    # set of paths/extensions that triggered it (empty for metadata cleanup).
    private def act(backend : Backend, item : QueueItem, reporter : Reporter,
                    source : String, hash : String, matched : Array(String),
                    action : String) : Nil
      backend.delete_and_blocklist(item)
      reporter.info(source, "removed + blocklisted '#{item.title}'")
      @store.try &.record_processed(backend.name, hash, item.title, action, matched)

      if backend.released?(item)
        backend.search(item)
        reporter.info(source, "search re-triggered")
      else
        reporter.info(source, "not released yet; skipping search")
      end
    end

    # The dry-run action path: log the intended delete/blocklist and search
    # decision without mutating the backend or store. The release check is a
    # read-only call, so it still runs to report what a real run would do.
    # `reason` is the parenthetical in the would-delete line (e.g. `bad: …`
    # or `stuck downloading metadata`).
    private def act_dry_run(backend : Backend, item : QueueItem,
                            reporter : Reporter, source : String,
                            reason : String) : Nil
      reporter.warn(source, "[DRY RUN] would delete + blocklist '#{item.title}' (#{reason})")

      if backend.released?(item)
        reporter.info(source, "[DRY RUN] would re-trigger search for '#{item.title}'")
      else
        reporter.info(source, "[DRY RUN] not released; would skip search")
      end
    end
  end
end
