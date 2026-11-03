#!/bin/bash
# Tests the backup image against PostgreSQL 18, with a local bare repository as the destination and
# plays being written during the backup. Needs only Docker and openssl. Run by CI.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
chmod 777 "$T"
NET=bk-test
PG=bk-test-pg
fails=0
check() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
cleanup() { docker rm -f "$PG" > /dev/null 2>&1; docker network rm "$NET" > /dev/null 2>&1; rm -rf "$T" 2> /dev/null; }
trap cleanup EXIT
cleanup; T=$(mktemp -d); chmod 777 "$T"

docker build -q -t runout-backup:test "$HERE" > /dev/null || exit 1
docker network create "$NET" > /dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD=superpw -e POSTGRES_DB=railway postgres:18 > /dev/null
until docker exec "$PG" pg_isready -U postgres -d railway -q; do sleep 1; done
sleep 2
sql() { docker exec -i "$PG" psql -U postgres -d railway -X -A -t -q -c "$1"; }
sql "create table plays(id bigserial primary key, body text not null); insert into plays(body) select 'secretrow' || g from generate_series(1, 20000) g;
     create table notes(id int references plays(id), n text); insert into notes select g, 'n' from generate_series(1, 100) g;
     create role backup_ro login password 'robackuppw'; grant pg_read_all_data to backup_ro;"

umask 077
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.key" -out "$T/k.crt" -days 2 -subj /CN=t 2> /dev/null
umask 022
git init -q --bare "$T/dest.git"
git init -q "$T/seed"
git -C "$T/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed
# 2 recent days; 3 in one old month; 2 in another; 1 in each of 2 older ones.
for d in 20261101T100000Z 20261102T100000Z 20261010T100000Z 20261011T100000Z 20261012T100000Z 20260910T100000Z 20260911T100000Z 20260805T100000Z 20260705T100000Z; do
  git -C "$T/seed" push -q "$T/dest.git" "HEAD:refs/heads/backup/$d"
done
git -C "$T/seed" push -q "$T/dest.git" "HEAD:refs/heads/main"
chmod -R a+rwX "$T/dest.git"
# The destination belongs to the runner here, and Git's local transport ignores config set by environment.
printf '[safe]\n\tdirectory = *\n' > "$T/gitconfig"
chmod 644 "$T/gitconfig"

branches() { git -C "$T/dest.git" for-each-ref --format='%(refname:short)' 'refs/heads/backup/*' | sort; }
URL=postgresql://backup_ro:robackuppw@$PG:5432/railway
run() { # extra docker -e options, then the log file is $T/log
  docker run --rm --network "$NET" -v "$T/dest.git:/dest.git" -v "$T/gitconfig:/tmp/.gitconfig:ro" \
    -e BACKUP_REPO=/dest.git -e "BACKUP_PUBLIC_CERT=$(cat "$T/k.crt")" "$@" runout-backup:test > "$T/log" 2>&1
  rc=$?
  # The job's umask keeps what it writes private, so this test can only read it after opening it up.
  docker run --rm --user 0 -v "$T/dest.git:/dest.git" runout-backup:test chmod -R a+rwX /dest.git
  return "$rc"
}

# Plays keep arriving throughout: only a shared snapshot gives identical counts.
( while docker exec "$PG" psql -U postgres -d railway -X -q -c "insert into plays(body) select 'secretrow-live' from generate_series(1, 50)" > /dev/null 2>&1; do sleep 0.1; done ) &
WRITER=$!
run -e "BACKUP_DATABASE_URL=$URL" -e BACKUP_KEEP_DAILY=3 -e BACKUP_KEEP_MONTHLY=2 -e "BACKUP_CHECK_SQL=select count(*) from notes"
rc=$?
kill "$WRITER" 2> /dev/null
wait "$WRITER" 2> /dev/null
sed -E 's/[0-9]{8}T[0-9]{6}Z/STAMP/g' "$T/log"
check "backup succeeds with writes arriving, every count identical" "$rc"
grep -q 'every count identical' "$T/log"; check "log reports the comparison" $?
grep -q 'pg_amcheck clean' "$T/log"; check "log reports pg_amcheck" $?
! grep -q -E 'robackuppw|superpw|secretrow|BEGIN' "$T/log"; check "no credentials or contents in the log" $?

NEW=$(branches | tail -1)
# Newest 3: NEW, 1102, 1101. Then the newest of each older month, up to 2: 1012, 0911.
EXPECTED=$(printf 'backup/20260911T100000Z\nbackup/20261012T100000Z\nbackup/20261101T100000Z\nbackup/20261102T100000Z\n%s' "$NEW")
[ "$(branches)" = "$EXPECTED" ]; check "retention keeps 3 daily and 2 monthly" $?
git -C "$T/dest.git" rev-parse -q --verify refs/heads/main > /dev/null; check "retention leaves other branches alone" $?

git clone -q --branch "$NEW" "$T/dest.git" "$T/c" 2> /dev/null
! grep -a -q secretrow "$T/c/db.dump.cms"; check "the stored file holds no plaintext" $?
openssl cms -decrypt -binary -inform DER -inkey "$T/k.key" -in "$T/c/db.dump.cms" -out "$T/d.dump" 2> /dev/null; check "decrypts with the private key" $?
[ "$(openssl dgst -sha256 -r "$T/d.dump" | cut -d' ' -f1)" = "$(sed -n 's/^dump_sha256=//p' "$T/c/manifest.txt")" ]; check "decrypted dump matches the manifest" $?
docker exec "$PG" createdb -U postgres drill
docker exec -i "$PG" pg_restore -U postgres -d drill --no-owner --no-privileges --exit-on-error < "$T/d.dump" > /dev/null 2>&1; check "owner's restore works" $?
ROWS=$(docker exec "$PG" psql -U postgres -d drill -X -A -t -c "select (select count(*) from plays) + (select count(*) from notes)")
[ "$ROWS" = "$(sed -n 's/^rows=//p' "$T/c/manifest.txt")" ]; check "owner's restore has the manifest's rows ($ROWS)" $?
[ "$(sql "select count(*) from pg_database where datname = 'restore_check'")" = 0 ]; check "the production server gained no restore database" $?
docker exec "$PG" psql -U backup_ro -d railway -X -c "delete from notes" > /dev/null 2>&1; [ $? -ne 0 ]; check "the backup role can't write" $?

BEFORE=$(branches)
refused() { name=$1; shift; run "$@"; rc=$?; [ "$rc" -ne 0 ] && [ "$(branches)" = "$BEFORE" ] && ! grep -q -E 'robackuppw|superpw|wrongpw|secretrow' "$T/log"; check "refused and kept nothing: $name ($(tail -1 "$T/log" | cut -c1-60))" $?; }
refused "wrong password" -e "BACKUP_DATABASE_URL=postgresql://backup_ro:wrongpw@$PG:5432/railway"
refused "unreachable database" -e "BACKUP_DATABASE_URL=postgresql://backup_ro:x@nohost:5432/railway"
refused "integrity check differs" -e "BACKUP_DATABASE_URL=$URL" -e "BACKUP_CHECK_SQL=select random()"
refused "bad certificate" -e "BACKUP_DATABASE_URL=$URL" -e BACKUP_PUBLIC_CERT=garbage
refused "too large for the destination" -e "BACKUP_DATABASE_URL=$URL" -e BACKUP_MAX_BYTES=10
sql "create database empty_db; grant connect on database empty_db to backup_ro"
refused "empty database" -e "BACKUP_DATABASE_URL=postgresql://backup_ro:robackuppw@$PG:5432/empty_db"
run -e "BACKUP_DATABASE_URL=$URL" -e BACKUP_REPO=/dest.git/missing; rc=$?; [ "$rc" -ne 0 ]; check "refused: unreachable destination" $?

echo "FAILS=$fails"
exit "$fails"
