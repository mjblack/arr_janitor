require "log"

module ArrJanitor
  # The valid `::Log::Severity` names, lowercased, for use in error messages
  # when an invalid log level is supplied via CLI flag, env var, or config.
  LOG_LEVEL_NAMES = "trace, debug, info, notice, warn, error, fatal, none"

  # Parses *value* into a `::Log::Severity`, case-insensitively, returning `nil`
  # when it is not a valid level name. A thin wrapper over
  # `::Log::Severity.parse?` so callers (CLI resolver, config validation) share
  # one parse path and one notion of "valid".
  def self.parse_log_level?(value : String) : ::Log::Severity?
    ::Log::Severity.parse?(value)
  end

  # A single log record produced by a worker fiber. Workers never touch Crystal's
  # `Log` directly; they build `LogEvent`s (via a `Reporter`) and hand them off
  # over a channel so the main fiber can emit them in a serialized order.
  struct LogEvent
    getter severity : ::Log::Severity
    getter source : String
    getter message : String
    getter exception : Exception?

    def initialize(@severity : ::Log::Severity, @source : String,
                   @message : String, @exception : Exception? = nil)
    end
  end

  # Worker-facing logging facade. Wraps a `Channel(LogEvent)`; each level helper
  # builds a `LogEvent` and sends it down the channel for the main-fiber
  # `LogConsumer` to emit. Safe to call from any fiber/thread.
  class Reporter
    def initialize(@channel : Channel(LogEvent))
    end

    def debug(source : String, message : String, exception : Exception? = nil) : Nil
      emit(::Log::Severity::Debug, source, message, exception)
    end

    def info(source : String, message : String, exception : Exception? = nil) : Nil
      emit(::Log::Severity::Info, source, message, exception)
    end

    def warn(source : String, message : String, exception : Exception? = nil) : Nil
      emit(::Log::Severity::Warn, source, message, exception)
    end

    def error(source : String, message : String, exception : Exception? = nil) : Nil
      emit(::Log::Severity::Error, source, message, exception)
    end

    # Closes the underlying channel, signalling the consumer to stop draining.
    def close : Nil
      @channel.close
    end

    private def emit(severity : ::Log::Severity, source : String,
                     message : String, exception : Exception?) : Nil
      @channel.send(LogEvent.new(severity, source, message, exception))
    end
  end

  # Drains `LogEvent`s off the channel on the main fiber and emits each one via
  # Crystal's `Log`, so console output stays ordered across worker threads.
  module LogConsumer
    # Receives events until the channel is closed, emitting each via
    # `Log.for(source)`.
    def self.drain(channel : Channel(LogEvent)) : Nil
      while event = channel.receive?
        emit(event)
      end
    end

    # Emits a single event via `Log.for(source)`, dispatching to the method for
    # its severity (Crystal's `Log` has no generic `log(severity)` entry point).
    private def self.emit(event : LogEvent) : Nil
      log = ::Log.for(event.source)
      ex = event.exception
      message = event.message

      case event.severity
      when .trace?  then log.trace(exception: ex) { message }
      when .debug?  then log.debug(exception: ex) { message }
      when .info?   then log.info(exception: ex) { message }
      when .notice? then log.notice(exception: ex) { message }
      when .warn?   then log.warn(exception: ex) { message }
      when .error?  then log.error(exception: ex) { message }
      when .fatal?  then log.fatal(exception: ex) { message }
      else               log.info(exception: ex) { message }
      end
    end
  end

  # Configures a Crystal `Log` backend writing to *io* (stdout by default) at the
  # given severity *level*.
  def self.setup_logging(level : ::Log::Severity = ::Log::Severity::Info,
                         io : IO = STDOUT) : Nil
    backend = ::Log::IOBackend.new(io, dispatcher: ::Log::DispatchMode::Sync)
    ::Log.setup(level, backend)
  end
end
