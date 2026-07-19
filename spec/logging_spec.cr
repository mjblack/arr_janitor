require "./spec_helper"

describe ArrJanitor::Reporter do
  it "builds a LogEvent per level and sends it down the channel" do
    channel = Channel(ArrJanitor::LogEvent).new(8)
    reporter = ArrJanitor::Reporter.new(channel)

    reporter.debug("src.a", "debug message")
    reporter.info("src.b", "info message")
    reporter.warn("src.c", "warn message")

    boom = Exception.new("boom")
    reporter.error("src.d", "error message", boom)
    reporter.close

    events = [] of ArrJanitor::LogEvent
    while event = channel.receive?
      events << event
    end

    events.size.should eq(4)

    events[0].severity.should eq(::Log::Severity::Debug)
    events[0].source.should eq("src.a")
    events[0].message.should eq("debug message")
    events[0].exception.should be_nil

    events[1].severity.should eq(::Log::Severity::Info)
    events[2].severity.should eq(::Log::Severity::Warn)

    events[3].severity.should eq(::Log::Severity::Error)
    events[3].exception.should be(boom)
  end
end

describe ArrJanitor::LogConsumer do
  describe ".drain" do
    it "emits each queued event via Crystal's Log and stops when closed" do
      output = IO::Memory.new
      backend = ::Log::IOBackend.new(output, dispatcher: ::Log::DispatchMode::Sync)

      ::Log.setup(::Log::Severity::Debug, backend)

      channel = Channel(ArrJanitor::LogEvent).new(4)
      reporter = ArrJanitor::Reporter.new(channel)
      reporter.info("arr_janitor.test", "hello world")
      reporter.warn("arr_janitor.test", "danger ahead")
      reporter.close

      ArrJanitor::LogConsumer.drain(channel)

      log = output.to_s
      log.should contain("hello world")
      log.should contain("danger ahead")
      log.should contain("arr_janitor.test")
    ensure
      ::Log.setup(::Log::Severity::None)
    end
  end
end
