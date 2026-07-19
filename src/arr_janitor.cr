require "sonarr"
require "qbittorrent"

# ArrJanitor watches Sonarr/Radarr download queues, removes and blocklists
# downloads that contain bad file extensions, and re-triggers a search when the
# episode/movie is released.
module ArrJanitor
  VERSION = "0.1.0"
end

require "./arr_janitor/config"
