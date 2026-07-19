module ArrJanitor
  # Runs the configured backends: one worker fiber per backend, each looping and
  # running a scan whenever its backend is `due?`, then calling `schedule_next`.
  #
  # Workers never touch Crystal's `Log` directly — they emit `LogEvent`s through
  # a shared `Reporter`/`Channel(LogEvent)` that the **main (calling) fiber**
  # drains via `LogConsumer.drain`, so console output stays ordered across the
  # `-Dpreview_mt` worker threads.
  #
  # `#run_due` is the decomposed, fiber-free scheduling core (iterate the
  # backends once, run each due one) so the scheduling decision is unit-testable
  # without spawning fibers or sleeping.
  class Scheduler
    # How long a worker waits between due-checks (also the shutdown latency
    # ceiling — a worker wakes early when the stop signal arrives).
    TICK = 1.second

    # How often the retention-sweep fiber deletes aged `processed_downloads`
    # rows. Long by design — the audit log is swept on a TTL, not per tick.
    SWEEP_INTERVAL = 1.hour

    # The channel-backed facade workers log through; exposed for tests.
    getter reporter : Reporter

    # The log channel workers feed and the main fiber drains; exposed for tests.
    getter channel : Channel(LogEvent)

    def initialize(@backends : Array(Backend), @janitor : Janitor = Janitor.new,
                   @channel : Channel(LogEvent) = Channel(LogEvent).new(1024),
                   @tick : Time::Span = TICK, @store : Store? = nil,
                   @retention : Time::Span? = nil,
                   @sweep_interval : Time::Span = SWEEP_INTERVAL)
      @reporter = Reporter.new(@channel)
      @stop = Channel(Nil).new
    end

    # Iterates the backends once, running every `due?` backend through the
    # janitor and advancing its `next_run`. The fiber-free core of the worker
    # loop — call it directly in tests to exercise scheduling without fibers.
    def run_due(now = Time.local) : Nil
      @backends.each { |backend| run_if_due(backend, now) }
    end

    # Traps `INT`/`TERM`, spawns one worker fiber per backend, then drains the
    # log channel on the calling (main) fiber until shutdown. A helper fiber
    # closes the log channel once every worker has stopped, which lets the drain
    # loop finish and this method return.
    def run : Nil
      setup_signal_handlers

      # One fiber per backend, plus an optional retention-sweep fiber. Every
      # fiber signals `done` when it stops so shutdown can wait for all of them.
      worker_count = @backends.size
      worker_count += 1 if sweeping?

      done = Channel(Nil).new(worker_count)
      @backends.each do |backend|
        spawn do
          run_worker(backend)
        ensure
          done.send(nil)
        end
      end

      if sweeping?
        spawn do
          run_sweeper
        ensure
          done.send(nil)
        end
      end

      # Once stop is signalled, wait for every worker (incl. the sweep fiber) to
      # finish so none sends to a closed channel, close the store, then close the
      # log channel to end the drain.
      spawn do
        @stop.receive?
        worker_count.times { done.receive }
        @store.try &.close
        @channel.close
      end

      LogConsumer.drain(@channel)
    end

    # Signals the workers to stop. Idempotent — safe to call from a signal
    # handler that may fire more than once.
    def stop : Nil
      @stop.close
    rescue Channel::ClosedError
      # already stopping
    end

    private def setup_signal_handlers : Nil
      {% if flag?(:unix) %}
        Signal::INT.trap { stop }
        Signal::TERM.trap { stop }
      {% end %}
    end

    # A single backend's worker loop: run when due, then wait a tick — waking
    # early if a stop is signalled.
    private def run_worker(backend : Backend) : Nil
      until @stop.closed?
        run_if_due(backend)
        break if wait_for_stop(@tick)
      end
    end

    # Whether a retention-sweep fiber should run: only when both a store and a
    # retention window are configured.
    private def sweeping? : Bool
      !@store.nil? && !@retention.nil?
    end

    # Deletes `processed_downloads` rows older than the configured retention
    # window and logs how many were removed. A no-op when no store/retention is
    # configured. The fiber-free core of the sweep loop — call it directly in
    # tests to exercise the sweep without spawning a fiber.
    def sweep_once : Nil
      store = @store
      retention = @retention
      return if store.nil? || retention.nil?

      deleted = store.sweep(retention)
      @reporter.info("arr_janitor.sweep",
        "retention sweep removed #{deleted} processed download row(s) older than #{retention}")
    end

    # The retention-sweep loop: sweep once shortly after start, then on the
    # `SWEEP_INTERVAL` cadence, waking early to exit promptly when a stop is
    # signalled.
    private def run_sweeper : Nil
      # A brief initial delay lets startup logging settle; exit without sweeping
      # if a stop arrives first.
      return if wait_for_stop(@tick)
      sweep_safely

      until @stop.closed?
        break if wait_for_stop(@sweep_interval)
        sweep_safely
      end
    end

    # Runs one sweep, logging (and swallowing) any error so a transient DB
    # failure never kills the sweeper fiber — it just retries next cadence.
    private def sweep_safely : Nil
      sweep_once
    rescue ex
      @reporter.error("arr_janitor.sweep", "retention sweep failed", ex)
    end

    # Waits up to *span* for the stop signal. Returns `true` when a stop was
    # observed (the caller should exit), `false` when *span* elapsed.
    private def wait_for_stop(span : Time::Span) : Bool
      select
      when @stop.receive?
        true
      when timeout(span)
        false
      end
    end

    private def run_if_due(backend : Backend, now = Time.local) : Nil
      return unless backend.due?(now)

      begin
        @janitor.process(backend, @reporter)
      rescue ex
        # A scan-wide failure (e.g. the queue fetch itself raising) is logged,
        # not fatal; the backend is still rescheduled so it retries next tick.
        @reporter.error("arr_janitor.backend.#{backend.name}", "scan failed", ex)
      ensure
        backend.schedule_next(now)
      end
    end
  end
end
