require "./spec_helper"

# Builds a sample `TorrentFile` with the given *name* via JSON (the struct has
# no constructor). Passing `nil` yields a file whose `name` is absent.
private def torrent_file(name : String?) : QBittorrent::Model::TorrentFile
  json = name.nil? ? %({"index": 0}) : {index: 0, name: name}.to_json
  QBittorrent::Model::TorrentFile.from_json(json)
end

# Builds a `TorrentInfo` from JSON (the model has no public constructor).
private def torrent_info(json : String) : QBittorrent::Model::TorrentInfo
  QBittorrent::Model::TorrentInfo.from_json(json)
end

# Convenience constructor for `TorrentSnapshot` predicate specs.
private def snapshot(state : String?, num_seeds : Int32? = 0)
  ArrJanitor::DownloadClient::TorrentSnapshot.new(
    hash: "abc",
    state: state,
    num_seeds: num_seeds,
  )
end

describe ArrJanitor::DownloadClient do
  describe ".build" do
    it "builds a qBittorrent client (case-insensitive)" do
      client = ArrJanitor::DownloadClient.build(
        "qBitTorrent", "http://localhost:8080",
        api_key: nil, username: "admin", password: "secret")
      client.should be_a(ArrJanitor::DownloadClient::QBittorrent)
    end

    it "returns nil for an unsupported implementation" do
      client = ArrJanitor::DownloadClient.build(
        "transmission", "http://localhost:9091",
        api_key: "key", username: nil, password: nil)
      client.should be_nil
    end

    it "raises when qBittorrent is missing a username" do
      expect_raises(ArrJanitor::DownloadClient::Error, /username and password/) do
        ArrJanitor::DownloadClient.build(
          "qbittorrent", "http://localhost:8080",
          api_key: nil, username: nil, password: "secret")
      end
    end

    it "raises when qBittorrent is missing a password" do
      expect_raises(ArrJanitor::DownloadClient::Error, /username and password/) do
        ArrJanitor::DownloadClient.build(
          "qbittorrent", "http://localhost:8080",
          api_key: nil, username: "admin", password: nil)
      end
    end

    it "raises when qBittorrent credentials are blank" do
      expect_raises(ArrJanitor::DownloadClient::Error) do
        ArrJanitor::DownloadClient.build(
          "qbittorrent", "http://localhost:8080",
          api_key: nil, username: "admin", password: "")
      end
    end
  end

  describe ArrJanitor::DownloadClient::QBittorrent do
    describe ".extract_paths" do
      it "maps each TorrentFile to its name" do
        files = [
          torrent_file("Show/Episode.mkv"),
          torrent_file("Show/Episode.exe"),
        ]
        ArrJanitor::DownloadClient::QBittorrent.extract_paths(files)
          .should eq(["Show/Episode.mkv", "Show/Episode.exe"])
      end

      it "drops files whose name is nil" do
        files = [
          torrent_file("keep.mkv"),
          torrent_file(nil),
          torrent_file("also.nfo"),
        ]
        ArrJanitor::DownloadClient::QBittorrent.extract_paths(files)
          .should eq(["keep.mkv", "also.nfo"])
      end

      it "returns an empty array for no files" do
        empty = [] of QBittorrent::Model::TorrentFile
        ArrJanitor::DownloadClient::QBittorrent.extract_paths(empty).should be_empty
      end
    end

    describe ".translate_api_error" do
      it "maps a 404 to TorrentNotFound" do
        api_error = QBittorrent::ApiError.new(404, "Not Found")
        error = ArrJanitor::DownloadClient::QBittorrent.translate_api_error("HASH", api_error)
        error.should be_a(ArrJanitor::DownloadClient::TorrentNotFound)
        error.message.to_s.should contain("HASH")
        error.message.to_s.should contain("404")
        error.cause.should eq(api_error)
      end

      it "maps other non-2xx statuses to a generic Error carrying the cause" do
        api_error = QBittorrent::ApiError.new(409, "Conflict")
        error = ArrJanitor::DownloadClient::QBittorrent.translate_api_error("HASH", api_error)
        error.should be_a(ArrJanitor::DownloadClient::Error)
        error.should_not be_a(ArrJanitor::DownloadClient::TorrentNotFound)
        error.cause.should eq(api_error)
      end
    end

    describe ".snapshot_from" do
      it "maps state, num_seeds, and added_on off a JSON TorrentInfo" do
        info = torrent_info(<<-JSON)
          {
            "hash": "8c212779b4abde7c6bc608063a0d008b7e40ce32",
            "state": "metaDL",
            "num_seeds": 0,
            "added_on": 1700000000
          }
          JSON

        snapshot = ArrJanitor::DownloadClient::QBittorrent.snapshot_from(info)
        snapshot.hash.should eq("8c212779b4abde7c6bc608063a0d008b7e40ce32")
        # Wire token via TorrentState#to_api — not the enum name "MetaDL".
        snapshot.state.should eq("metaDL")
        snapshot.num_seeds.should eq(0)
        snapshot.added_on.should eq(Time.unix(1_700_000_000))
        snapshot.added_on.try(&.utc?).should be_true
      end

      it "maps a missing added_on to nil" do
        info = torrent_info(%({"hash": "abc", "state": "downloading", "num_seeds": 1}))
        snapshot = ArrJanitor::DownloadClient::QBittorrent.snapshot_from(info)
        snapshot.added_on.should be_nil
        snapshot.state.should eq("downloading")
        snapshot.num_seeds.should eq(1)
      end

      it "maps a missing state to nil" do
        info = torrent_info(%({"hash": "abc", "num_seeds": 0}))
        snapshot = ArrJanitor::DownloadClient::QBittorrent.snapshot_from(info)
        snapshot.state.should be_nil
        snapshot.num_seeds.should eq(0)
      end
    end

    describe ".snapshot_from_list" do
      it "maps the first TorrentInfo into a snapshot" do
        info = torrent_info(%({"hash": "abc", "state": "stalledDL", "num_seeds": 0}))
        snapshot = ArrJanitor::DownloadClient::QBittorrent.snapshot_from_list(
          "abc", [info])
        snapshot.hash.should eq("abc")
        snapshot.state.should eq("stalledDL")
        snapshot.num_seeds.should eq(0)
      end

      it "raises TorrentNotFound for an empty info list" do
        empty = [] of QBittorrent::Model::TorrentInfo
        expect_raises(ArrJanitor::DownloadClient::TorrentNotFound, /MISSING/) do
          ArrJanitor::DownloadClient::QBittorrent.snapshot_from_list("MISSING", empty)
        end
      end
    end
  end
end

describe ArrJanitor::DownloadClient::TorrentSnapshot do
  describe "#metadata_downloading?" do
    it "is true only for the metaDL wire token" do
      snapshot("metaDL").metadata_downloading?.should be_true
    end

    it "is false for other states, including case variants" do
      snapshot("downloading").metadata_downloading?.should be_false
      snapshot("stalledDL").metadata_downloading?.should be_false
      snapshot("MetaDL").metadata_downloading?.should be_false
      snapshot(nil).metadata_downloading?.should be_false
    end
  end

  describe "#stalled_zero_seeds?" do
    it "is true for stalledDL/downloading/forcedDL with zero seeds" do
      snapshot("stalledDL", 0).stalled_zero_seeds?.should be_true
      snapshot("downloading", 0).stalled_zero_seeds?.should be_true
      snapshot("forcedDL", 0).stalled_zero_seeds?.should be_true
    end

    it "is false for metaDL, uploading, queuedDL, stoppedDL with zero seeds" do
      snapshot("metaDL", 0).stalled_zero_seeds?.should be_false
      snapshot("uploading", 0).stalled_zero_seeds?.should be_false
      snapshot("queuedDL", 0).stalled_zero_seeds?.should be_false
      snapshot("stoppedDL", 0).stalled_zero_seeds?.should be_false
      snapshot("pausedDL", 0).stalled_zero_seeds?.should be_false
    end

    it "is false when num_seeds is greater than zero" do
      snapshot("stalledDL", 1).stalled_zero_seeds?.should be_false
      snapshot("downloading", 5).stalled_zero_seeds?.should be_false
      snapshot("forcedDL", 1).stalled_zero_seeds?.should be_false
    end

    it "is false when num_seeds or state is nil" do
      snapshot("stalledDL", nil).stalled_zero_seeds?.should be_false
      snapshot(nil, 0).stalled_zero_seeds?.should be_false
    end
  end
end
