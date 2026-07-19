require "./spec_helper"

# A `Backend` whose `due?` is directly controllable and that records when its
# queue is read — enough to observe which backends the scheduler acts on. No
# network.
private class StubBackend < ArrJanitor::Backend
  getter queue_reads = 0
  property span : Time::Span

  def initialize(@name : String, due : Bool, @span : Time::Span = 20.minutes)
    # `next_run` nil => due on first tick; a far-future time => not due.
    @next_run = due ? nil : Time.utc(2999, 1, 1)
  end

  def interval_span : Time::Span
    @span
  end

  getter name : String

  def config : ArrJanitor::Config::Backend
    ArrJanitor::Config::Backend.new(
      name: @name,
      type: ArrJanitor::Config::BackendType::Sonarr,
      url: "http://localhost:8989",
      api_key: "key")
  end

  def queue : Array(ArrJanitor::QueueItem)
    @queue_reads += 1
    [] of ArrJanitor::QueueItem
  end

  def released?(item : ArrJanitor::QueueItem) : Bool
    false
  end

  def delete_and_blocklist(item : ArrJanitor::QueueItem) : Nil
  end

  def search(item : ArrJanitor::QueueItem) : Nil
  end

  def download_client_info(name : String) : ArrJanitor::DownloadClientInfo?
    nil
  end
end

# A `Janitor` that records which backends it was asked to process instead of
# doing any real work.
private class RecordingJanitor < ArrJanitor::Janitor
  getter processed = [] of ArrJanitor::Backend

  def initialize
    super()
  end

  def process(backend : ArrJanitor::Backend, reporter : ArrJanitor::Reporter) : Nil
    @processed << backend
  end
end

private NOW = Time.utc(2026, 7, 18, 12, 0, 0)

describe ArrJanitor::Scheduler do
  describe "#run_due" do
    it "processes only the due backends" do
      due = StubBackend.new("due", due: true)
      not_due = StubBackend.new("not-due", due: false)
      janitor = RecordingJanitor.new
      scheduler = ArrJanitor::Scheduler.new([due, not_due] of ArrJanitor::Backend, janitor)

      scheduler.run_due(NOW)

      janitor.processed.map(&.name).should eq(["due"])
    end

    it "advances next_run for a backend it ran" do
      due = StubBackend.new("due", due: true, span: 30.minutes)
      scheduler = ArrJanitor::Scheduler.new([due] of ArrJanitor::Backend, RecordingJanitor.new)

      due.next_run.should be_nil
      scheduler.run_due(NOW)
      due.next_run.should eq(NOW + 30.minutes)
    end

    it "leaves a not-due backend's next_run untouched" do
      not_due = StubBackend.new("not-due", due: false)
      original = not_due.next_run
      scheduler = ArrJanitor::Scheduler.new([not_due] of ArrJanitor::Backend, RecordingJanitor.new)

      scheduler.run_due(NOW)
      not_due.next_run.should eq(original)
    end

    it "reschedules and does not run a backend again on the next pass" do
      due = StubBackend.new("due", due: true, span: 20.minutes)
      janitor = RecordingJanitor.new
      scheduler = ArrJanitor::Scheduler.new([due] of ArrJanitor::Backend, janitor)

      scheduler.run_due(NOW)            # runs, schedules next at NOW+20m
      scheduler.run_due(NOW + 1.minute) # still before next_run: skipped
      janitor.processed.size.should eq(1)

      scheduler.run_due(NOW + 20.minutes) # due again
      janitor.processed.size.should eq(2)
    end
  end
end
