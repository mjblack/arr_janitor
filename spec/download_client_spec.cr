require "./spec_helper"

# Builds a sample `TorrentFile` with the given *name* via JSON (the struct has
# no constructor). Passing `nil` yields a file whose `name` is absent.
private def torrent_file(name : String?) : QBittorrent::Model::TorrentFile
  json = name.nil? ? %({"index": 0}) : {index: 0, name: name}.to_json
  QBittorrent::Model::TorrentFile.from_json(json)
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
  end
end
