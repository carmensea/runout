#!/bin/sh
# Builds the production image and tests it end to end, as Railway would run it, against a fake
# Spotify and Last.fm on a Docker network with no internet route. Needs only Docker.
#
#   server/test/smoke/production/run.sh
#   PG_VERSION=17 INGESTION=false server/test/smoke/production/run.sh
#
# Keeps the database after the run with KEEP=1, for the merge rehearsal (docs/railway-deployment.md).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
PG_VERSION=${PG_VERSION:-18}
INGESTION=${INGESTION:-true}
NET=runout-smoke
STATE=$(mktemp -d)
chmod 755 "$STATE"

cleanup() {
  docker logs runout-smoke-app > "$STATE/app.log" 2>&1 || true
  tail -25 "$STATE/app.log" | cut -c1-200 >&2 || true
  [ "${KEEP:-}" = 1 ] || docker rm -f runout-smoke-app runout-smoke-pg runout-smoke-stub runout-smoke-driver > /dev/null 2>&1 || true
  [ "${KEEP:-}" = 1 ] || docker network rm "$NET" > /dev/null 2>&1 || true
}
trap cleanup EXIT

docker rm -f runout-smoke-app runout-smoke-pg runout-smoke-stub runout-smoke-driver > /dev/null 2>&1 || true
docker network rm "$NET" > /dev/null 2>&1 || true

docker build -q -t runout:smoke "$ROOT" > /dev/null

# The driver stops and inspects containers through the host's Docker socket, with the host's own CLI
# when that's a Linux binary (CI), or Docker's static client otherwise (a Mac).
DOCKER_CLI=$(command -v docker)
if [ "$(head -c 4 "$DOCKER_CLI" | tr -d '\0' | cut -c2-4)" != "ELF" ]; then
  case $(uname -m) in arm64 | aarch64) ARCH=aarch64 ;; *) ARCH=x86_64 ;; esac
  curl -fsSL "https://download.docker.com/linux/static/stable/$ARCH/docker-28.3.3.tgz" | tar xz -C "$STATE" docker/docker
  DOCKER_CLI="$STATE/docker/docker"
fi

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$STATE/stub.key" -out "$STATE/stub.crt" -days 2 -subj /CN=stub \
  -addext "subjectAltName=DNS:accounts.spotify.com,DNS:api.spotify.com,DNS:ws.audioscrobbler.com" 2> /dev/null
chmod 644 "$STATE/stub.key"
echo intruder > "$STATE/stub_user"
: > "$STATE/stub.log"
chmod 666 "$STATE/stub_user" "$STATE/stub.log"

docker network create --internal "$NET" > /dev/null
docker run -d --name runout-smoke-pg --network "$NET" -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=railway \
  -v "runout-smoke-pgdata-$$:/var/lib/postgresql" "postgres:$PG_VERSION" > /dev/null
until docker exec runout-smoke-pg pg_isready -U postgres -d railway -q; do sleep 1; done
docker run -d --name runout-smoke-stub --network "$NET" --network-alias accounts.spotify.com --network-alias api.spotify.com \
  --network-alias ws.audioscrobbler.com -v "$STATE:/state" -v "$HERE/stub.rb:/stub.rb:ro" ruby:3.4.7-slim ruby /stub.rb > /dev/null

key() { openssl rand -hex 32; }
docker run -d --name runout-smoke-app --network "$NET" --network-alias app -v "$STATE/stub.crt:/stub.crt:ro" \
  -e PORT=3000 -e APP_ORIGIN=https://runout.test -e APP_ORIGINS=https://old.runout.test -e SSL_CERT_FILE=/stub.crt \
  -e DATABASE_URL=postgresql://postgres:smoke@runout-smoke-pg:5432/railway \
  -e SECRET_KEY_BASE="$(key)" -e ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$(key)" \
  -e ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$(key)" -e ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$(key)" \
  -e LASTFM_API_KEY=stub -e LASTFM_SHARED_SECRET=stub -e LASTFM_ALLOWED_USERNAME=listener -e LASTFM_MIN_REQUEST_INTERVAL=0 \
  -e SPOTIFY_CLIENT_ID=stub -e SPOTIFY_CLIENT_SECRET=stub -e SPOTIFY_MIN_REQUEST_INTERVAL=0 \
  -e SPOTIFY_REDIRECT_URI=https://runout.test/api/auth/spotify/callback \
  -e SPOTIFY_INGESTION_ENABLED="$INGESTION" -e SPOTIFY_POLL_SCHEDULE="every minute" -e RUNOUT_PASSKEYS_ENABLED=true runout:smoke > /dev/null

docker run --name runout-smoke-driver --network "$NET" -e INGESTION="$INGESTION" -e MIGRATIONS=/migrate \
  -v "$STATE:/state" -v "$HERE/driver.rb:/driver.rb:ro" -v "$ROOT/server/db/migrate:/migrate:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$DOCKER_CLI:/usr/local/bin/docker:ro" ruby:3.4.7-slim ruby /driver.rb
