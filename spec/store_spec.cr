require "./spec_helper"
require "wait_group"

# Runs the block with a fresh `Store` backed by a temp-file SQLite database in a
# throwaway directory, closing the store and removing the directory afterwards.
# A temp *file* (not `:memory:`) is required because an in-memory database is
# not shared across the connection-pool's connections.
private def with_store(&)
  dir = File.tempname("arr_janitor_store")
  Dir.mkdir_p(dir)
  path = File.join(dir, "test.db")
  store = ArrJanitor::Store.open(path)
  begin
    yield store
  ensure
    store.close
    FileUtils.rm_rf(dir)
  end
end

describe ArrJanitor::Store do
  describe ".open" do
    it "is idempotent across repeated opens (migrate + WAL)" do
      dir = File.tempname("arr_janitor_store")
      Dir.mkdir_p(dir)
      path = File.join(dir, "test.db")
      begin
        s1 = ArrJanitor::Store.open(path)
        s1.record_processed("sonarr", "H1", "T", "removed_blocklisted", ["exe"])
        s1.close

        s2 = ArrJanitor::Store.open(path)
        s2.processed?("sonarr", "H1").should be_true
        s2.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "creates a missing parent directory instead of failing to connect" do
      base = File.tempname("arr_janitor_store")
      path = File.join(base, "nested", "test.db")
      begin
        Dir.exists?(File.dirname(path)).should be_false
        store = ArrJanitor::Store.open(path)
        File.exists?(path).should be_true
        store.close
      ensure
        FileUtils.rm_rf(base)
      end
    end

    it "raises Store::Error (not a bare DB::ConnectionRefused) when the path can't be opened" do
      dir = File.tempname("arr_janitor_store")
      Dir.mkdir_p(dir)
      begin
        # Opening a *directory* as the database file fails in SQLite; it must
        # surface as a clear Store::Error, not an unhandled DB::ConnectionRefused.
        expect_raises(ArrJanitor::Store::Error, /cannot open SQLite database/) do
          ArrJanitor::Store.open(dir)
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "#record_processed / #processed?" do
    it "records a processed download and reports it as processed" do
      with_store do |store|
        store.processed?("sonarr", "HASH").should be_false
        store.record_processed("sonarr", "HASH", "Bad.Release", "removed_blocklisted", ["exe", "scr"])
        store.processed?("sonarr", "HASH").should be_true
        # A different backend/id is untouched.
        store.processed?("radarr", "HASH").should be_false
      end
    end

    it "accepts an empty matched-extensions set" do
      with_store do |store|
        store.record_processed("sonarr", "H2", "T", "removed_blocklisted", [] of String)
        store.processed?("sonarr", "H2").should be_true
      end
    end
  end

  describe "#sweep" do
    it "deletes only aged rows and returns the count removed" do
      with_store do |store|
        # Two aged rows (created 40 days ago) and one fresh row. The OLD rows are
        # backdated through the public API via the `created_at` parameter.
        old = Time.utc - 40.days
        store.record_processed("sonarr", "OLD1", "a", "removed_blocklisted", ["exe"], created_at: old)
        store.record_processed("sonarr", "OLD2", "b", "removed_blocklisted", ["exe"], created_at: old)
        store.record_processed("sonarr", "NEW1", "c", "removed_blocklisted", ["exe"])

        deleted = store.sweep(30.days)
        deleted.should eq(2_i64)

        store.processed?("sonarr", "OLD1").should be_false
        store.processed?("sonarr", "OLD2").should be_false
        store.processed?("sonarr", "NEW1").should be_true
      end
    end

    it "returns zero when nothing is old enough" do
      with_store do |store|
        store.record_processed("sonarr", "NEW1", "c", "removed_blocklisted", ["exe"])
        store.sweep(30.days).should eq(0_i64)
      end
    end
  end

  describe "#mark_stalled / #first_seen_stalled / #clear_state" do
    it "records the first-seen time once and keeps it stable on re-mark" do
      with_store do |store|
        store.first_seen_stalled("sonarr", "HASH").should be_nil

        t0 = Time.utc(2026, 1, 1, 12, 0, 0)
        store.mark_stalled("sonarr", "HASH", t0)
        store.first_seen_stalled("sonarr", "HASH").should eq(t0)

        # Re-marking later must not move the first-seen time.
        store.mark_stalled("sonarr", "HASH", t0 + 5.hours)
        store.first_seen_stalled("sonarr", "HASH").should eq(t0)
      end
    end

    it "clears stored state" do
      with_store do |store|
        store.mark_stalled("sonarr", "HASH")
        store.first_seen_stalled("sonarr", "HASH").should_not be_nil
        store.clear_state("sonarr", "HASH")
        store.first_seen_stalled("sonarr", "HASH").should be_nil
      end
    end
  end

  describe "concurrent writers" do
    # Documents the block-and-retry intent: with WAL + a per-connection
    # busy_timeout applied to every pooled connection, many fibers writing at
    # once must all land without raising `SQLITE_BUSY`. Best-effort — it only
    # actually exercises multiple pool connections under `-Dpreview_mt`, but is
    # a valid single-threaded smoke test otherwise.
    it "lands every row from many concurrent fibers without raising" do
      with_store do |store|
        fiber_count = 40
        wg = WaitGroup.new(fiber_count)
        errors = Channel(Exception).new(fiber_count)

        fiber_count.times do |i|
          spawn do
            begin
              store.record_processed(
                "sonarr", "HASH-#{i}", "T#{i}", "removed_blocklisted", ["exe"])
              # Interleave some stalled-state writes for extra contention.
              store.mark_stalled("sonarr", "STALL-#{i}") if i.even?
            rescue ex
              errors.send(ex)
            ensure
              wg.done
            end
          end
        end

        wg.wait
        errors.close

        # No fiber should have raised.
        if err = errors.receive?
          fail("concurrent writer raised: #{err.class}: #{err.message}")
        end

        # Every processed row landed.
        fiber_count.times do |i|
          store.processed?("sonarr", "HASH-#{i}").should be_true
        end
      end
    end
  end
end
