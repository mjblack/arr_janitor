# Multi-stage build for ArrJanitor.
#
# Both dependencies (mjblack/sonarr, mjblack/qbittorrent.cr) are public GitHub
# repos, so `shards install` fetches them over HTTPS with no token or secret.
#
# Build:
#   docker build -t arr_janitor .

# ---------------------------------------------------------------------------
# Builder stage: compile a release binary with the multi-threaded runtime.
# ---------------------------------------------------------------------------
FROM crystallang/crystal:1.20.2 AS build

# crystal-sqlite3 links against libsqlite3 and needs its dev headers to build.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy only the dependency manifests first so `shards install` is cached and
# only re-runs when the manifests change. shard.lock IS committed for this app.
COPY shard.yml shard.lock ./

# Fetch dependencies. Both deps are public GitHub repos, so no token is needed.
RUN shards install --production

# Copy the rest of the source and build the release binary. -Dpreview_mt enables
# Crystal's multi-threaded runtime (backend fibers run across threads).
COPY . .
# `bin/` is excluded by .dockerignore, so create the output dir before linking
# (the linker will not create a missing parent directory for -o).
RUN mkdir -p /app/bin \
    && crystal build -Dpreview_mt src/main.cr -o /app/bin/arr_janitor --release

# ---------------------------------------------------------------------------
# Runtime stage: a slim image with only the shared libs the binary links.
# ---------------------------------------------------------------------------
FROM debian:12-slim

# libsqlite3-0 is the runtime SQLite lib; libyaml-0-2 backs YAML config parsing
# (the binary links libyaml); ca-certificates for HTTPS to the *arr / download
# client; tzdata for correct local-time handling.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       libsqlite3-0 libyaml-0-2 ca-certificates tzdata gosu \
    && rm -rf /var/lib/apt/lists/*

# /config holds the mounted (read-only) config; /data holds the SQLite database.
# No fixed runtime user is baked in — the entrypoint fixes /data ownership and
# drops privileges at startup (see below).
RUN mkdir -p /config /data

COPY --from=build /app/bin/arr_janitor /usr/local/bin/arr_janitor
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Persist config and the database across container restarts.
VOLUME ["/config", "/data"]

# Number of Crystal runtime worker threads (-Dpreview_mt). Documented and
# overridable at run time (e.g. -e CRYSTAL_WORKERS=8).
ENV CRYSTAL_WORKERS=4

# The app runs as this UID/GID. At startup the entrypoint (as root) chowns the
# bind-mounted /data to PUID:PGID — fixing the common case where `docker compose
# up` creates a root-owned ./data — then drops to that user via gosu. Set these
# to your host user so the mount stays writable and the DB files are owned by you.
ENV PUID=1000 PGID=1000

# Working directory is the writable data volume. The database location is set
# explicitly by the `--database` param below, not by the CWD.
WORKDIR /data

# The entrypoint chowns /data to PUID:PGID, then drops privileges (gosu) and runs
# arr_janitor with the CMD below. Runs as a daemon by default; override CMD
# without --daemon for a single-pass run:
#   docker run ... --config /config/config.yml --database /data/arr_janitor.db
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["--config", "/config/config.yml", "--database", "/data/arr_janitor.db", "--daemon"]
