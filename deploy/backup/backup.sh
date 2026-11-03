#!/bin/bash
# Dumps the database at one consistent snapshot, proves the dump restores into a disposable server in
# this container, encrypts it to the owner's certificate, pushes only ciphertext to a private
# repository, confirms what arrived, then applies retention. A backup that fails any step isn't kept.
#
# Tool errors are never echoed: pg_dump and pg_restore messages can quote row data. Logs hold only step
# names and counts, never credentials or contents.
#
# Needs: BACKUP_DATABASE_URL (a read-only role), BACKUP_PUBLIC_CERT, BACKUP_REPO.
# BACKUP_DEPLOY_KEY: SSH key that can write only to that repository (not needed for a local path).
# Optional: BACKUP_CHECK_SQL (one query; must give the same result in source and restore),
# BACKUP_KEEP_DAILY (30), BACKUP_KEEP_MONTHLY (12), BACKUP_MAX_BYTES (95 MB: GitHub refuses 100 MB files).
set -euo pipefail
umask 077

: "${BACKUP_DATABASE_URL:?}" "${BACKUP_PUBLIC_CERT:?}" "${BACKUP_REPO:?}"
KEEP_DAILY=${BACKUP_KEEP_DAILY:-30}
KEEP_MONTHLY=${BACKUP_KEEP_MONTHLY:-12}
MAX_BYTES=${BACKUP_MAX_BYTES:-95000000}
export PGCONNECT_TIMEOUT=30

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")
LOCAL_UP=""
SRC_PID=""
STEP="start"

log() { echo "backup: $*"; }
cleanup() {
  status=$?
  trap - EXIT
  [ -n "$LOCAL_UP" ] && pg_ctl -D "$WORK/pg" -m immediate -w stop > /dev/null 2>&1 || true
  [ -n "$SRC_PID" ] && kill "$SRC_PID" 2> /dev/null || true
  rm -rf "$WORK"
  [ "$status" -eq 0 ] || echo "backup: FAILED at step: $STEP (exit $status); nothing further was kept" >&2
  exit "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

sha() { openssl dgst -sha256 -r "$1" | cut -d' ' -f1; }

STAT_SQL="select count(*), 0 from pg_tables where schemaname not in ('pg_catalog', 'information_schema')"
COUNT_SQL="select format('select %L, count(*) from %I.%I', schemaname || '.' || tablename, schemaname, tablename) from pg_tables where schemaname not in ('pg_catalog', 'information_schema') order by 1 \\gexec"
SCHEMA_SQL="select table_schema, table_name, column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema not in ('pg_catalog', 'information_schema') order by 1, 2, 3;
select schemaname, tablename, indexname, indexdef from pg_indexes where schemaname not in ('pg_catalog', 'information_schema') order by 1, 2, 3;
select conrelid::regclass::text, conname, pg_get_constraintdef(oid) from pg_constraint where connamespace not in ('pg_catalog'::regnamespace, 'information_schema'::regnamespace) order by 1, 2;"

# One long-lived read-only session holds the snapshot, so the source's counts describe exactly what
# pg_dump saw, even while plays are arriving.
mkfifo "$WORK/in" "$WORK/out"
psql "$BACKUP_DATABASE_URL" -w -X -A -t -q -v ON_ERROR_STOP=1 < "$WORK/in" > "$WORK/out" 2> "$WORK/src.err" &
SRC_PID=$!
exec 3> "$WORK/in" 4< "$WORK/out"

# Sends SQL to that session, and writes its output to file $2.
source_query() {
  printf '%s\n\\echo __END__\n' "$1" >&3
  : > "$2"
  while IFS= read -r -t 600 line <&4; do
    [ "$line" = "__END__" ] && return 0
    printf '%s\n' "$line" >> "$2"
  done
  return 1
}

STEP="connect"
source_query "begin isolation level repeatable read read only; select pg_export_snapshot();" "$WORK/snap"
SNAPSHOT=$(cat "$WORK/snap")
[ -n "$SNAPSHOT" ]
source_query "select split_part(version(), ' ', 2);" "$WORK/version"
log "connected; server $(cat "$WORK/version")"

STEP="dump"
pg_dump "$BACKUP_DATABASE_URL" -w -Fc --no-owner --no-privileges --snapshot="$SNAPSHOT" -f "$WORK/db.dump" 2> /dev/null
DUMP_BYTES=$(wc -c < "$WORK/db.dump" | tr -d ' ')
log "dumped $DUMP_BYTES bytes"

STEP="read source counts"
source_query "$COUNT_SQL" "$WORK/source.counts"
source_query "$SCHEMA_SQL" "$WORK/source.schema"
: > "$WORK/source.check"
[ -z "${BACKUP_CHECK_SQL:-}" ] || source_query "$BACKUP_CHECK_SQL;" "$WORK/source.check"
source_query "commit;" /dev/null
exec 3>&- 4<&-
wait "$SRC_PID" 2> /dev/null || true
SRC_PID=""

STEP="start disposable server"
initdb -D "$WORK/pg" -A trust -U restore -E UTF8 --no-sync > /dev/null 2>&1
pg_ctl -D "$WORK/pg" -w -l /dev/null -o "-c listen_addresses='' -c unix_socket_directories='$WORK' -c fsync=off" start > /dev/null 2>&1
LOCAL_UP=1
LOCAL=(-h "$WORK" -U restore)
createdb "${LOCAL[@]}" restore_check > /dev/null 2>&1

STEP="restore"
pg_restore "${LOCAL[@]}" -d restore_check --no-owner --no-privileges --exit-on-error "$WORK/db.dump" > /dev/null 2>&1

restored() { psql "${LOCAL[@]}" -d restore_check -X -A -t -q -v ON_ERROR_STOP=1 -c "$1" > "$2" 2> /dev/null; }

STEP="compare schema"
printf '%s\n' "$SCHEMA_SQL" | psql "${LOCAL[@]}" -d restore_check -X -A -t -q -v ON_ERROR_STOP=1 > "$WORK/restored.schema" 2> /dev/null
cmp -s "$WORK/source.schema" "$WORK/restored.schema"

STEP="compare row counts"
printf '%s\n' "$COUNT_SQL" | psql "${LOCAL[@]}" -d restore_check -X -A -t -q -v ON_ERROR_STOP=1 > "$WORK/restored.counts" 2> /dev/null
cmp -s "$WORK/source.counts" "$WORK/restored.counts"
TABLES=$(wc -l < "$WORK/restored.counts" | tr -d ' ')
ROWS=$(awk -F'|' '{ s += $2 } END { print s + 0 }' "$WORK/restored.counts")
[ "$TABLES" -gt 0 ]
[ "$ROWS" -gt 0 ]
log "restored: schema identical; $TABLES tables, $ROWS rows, every count identical"

if [ -n "${BACKUP_CHECK_SQL:-}" ]; then
  STEP="compare integrity check"
  restored "$BACKUP_CHECK_SQL" "$WORK/restored.check"
  cmp -s "$WORK/source.check" "$WORK/restored.check"
  log "integrity check identical"
fi

STEP="check table and index integrity"
pg_amcheck "${LOCAL[@]}" -d restore_check --install-missing --heapallindexed > /dev/null 2>&1
log "pg_amcheck clean"
DUMP_SHA=$(sha "$WORK/db.dump")

STEP="stop disposable server"
pg_ctl -D "$WORK/pg" -m fast -w stop > /dev/null 2>&1
LOCAL_UP=""
rm -rf "$WORK/pg"

STEP="encrypt"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BRANCH="backup/$STAMP"
printf '%s\n' "$BACKUP_PUBLIC_CERT" > "$WORK/cert.pem"
mkdir "$WORK/repo"
openssl cms -encrypt -aes-256-cbc -binary -outform DER -in "$WORK/db.dump" -out "$WORK/repo/db.dump.cms" "$WORK/cert.pem" 2> /dev/null
rm -f "$WORK/db.dump"
CIPHER_BYTES=$(wc -c < "$WORK/repo/db.dump.cms" | tr -d ' ')
[ "$CIPHER_BYTES" -gt 0 ]
[ "$CIPHER_BYTES" -le "$MAX_BYTES" ]
CIPHER_SHA=$(sha "$WORK/repo/db.dump.cms")
cat > "$WORK/repo/manifest.txt" << MANIFEST
created_at=$STAMP
server=$(cat "$WORK/version")
tables=$TABLES
rows=$ROWS
dump_bytes=$DUMP_BYTES
dump_sha256=$DUMP_SHA
encrypted_bytes=$CIPHER_BYTES
encrypted_sha256=$CIPHER_SHA
MANIFEST

STEP="upload"
if [ -n "${BACKUP_DEPLOY_KEY:-}" ]; then
  printf '%s\n' "$BACKUP_DEPLOY_KEY" > "$WORK/key"
  chmod 600 "$WORK/key"
  export GIT_SSH_COMMAND="ssh -i $WORK/key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts"
fi
unset BACKUP_DEPLOY_KEY BACKUP_DATABASE_URL
git -C "$WORK/repo" init -q -b "$BRANCH"
git -C "$WORK/repo" add db.dump.cms manifest.txt
git -C "$WORK/repo" -c user.name=runout-backup -c user.email=backup@invalid commit -q -m "Backup $STAMP"
git -C "$WORK/repo" push -q "$BACKUP_REPO" "HEAD:refs/heads/$BRANCH" > /dev/null 2>&1

STEP="confirm upload"
git clone -q --depth 1 --single-branch --branch "$BRANCH" "$BACKUP_REPO" "$WORK/check" > /dev/null 2>&1
[ "$(sha "$WORK/check/db.dump.cms")" = "$CIPHER_SHA" ]
log "uploaded and confirmed $BRANCH: $CIPHER_BYTES encrypted bytes"

STEP="retention"
# Newest KEEP_DAILY, plus the newest of each older month for KEEP_MONTHLY months.
git ls-remote --heads "$BACKUP_REPO" 'refs/heads/backup/*' | sed 's|.*refs/heads/||' | sort -r > "$WORK/branches"
grep -qx "$BRANCH" "$WORK/branches"
awk -v daily="$KEEP_DAILY" -v monthly="$KEEP_MONTHLY" '
  NR <= daily { next }
  { month = substr($0, 8, 6)
    if (!(month in seen) && kept < monthly) { seen[month] = 1; kept++; next }
    print }' "$WORK/branches" > "$WORK/expired"
DELETED=0
while IFS= read -r old; do
  git -C "$WORK/repo" push -q "$BACKUP_REPO" --delete "$old" > /dev/null 2>&1
  DELETED=$((DELETED + 1))
done < "$WORK/expired"

STEP="done"
log "OK $STAMP: $TABLES tables, $ROWS rows; removed $DELETED expired backups"
