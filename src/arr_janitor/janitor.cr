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

    def initialize(@resolver : DownloadClientResolver = DEFAULT_RESOLVER)
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

      info = backend.download_client_info(name)
      if info.nil?
        reporter.warn(source, "download client #{name.inspect} not found in #{backend.name}")
        return
      end

      creds = backend.config.download_clients.find { |candidate| candidate.name == name }
      if creds.nil?
        reporter.warn(source, "no configured credentials for '#{name}'")
        return
      end

      client = @resolver.call(info.implementation, info.base_url, creds.api_key, creds.username, creds.password)
      if client.nil?
        reporter.info(source, "unsupported download client implementation '#{info.implementation}'")
        return
      end

      hash = item.download_id
      return if hash.nil?

      files = client.files_for(hash)
      bad = files.select { |path| backend.config.matches_bad_extension?(path) }

      if bad.empty?
        reporter.debug(source, "clean download #{item.title.inspect}")
        return
      end

      reporter.warn(source, "bad extension(s) in '#{item.title}': #{bad.join(", ")}")
      backend.delete_and_blocklist(item)
      reporter.info(source, "removed + blocklisted '#{item.title}'")

      if backend.released?(item)
        backend.search(item)
        reporter.info(source, "search re-triggered")
      else
        reporter.info(source, "not released yet; skipping search")
      end
    end
  end
end
