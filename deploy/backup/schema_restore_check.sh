#!/bin/sh
# Does the schema come back from pg_dump + pg_restore unchanged? The same comparison backup.sh
# makes (information_schema columns, indexes, constraint definitions), run with the tools inside a
# PostgreSQL container: `schema_restore_check.sh <container> <database>`. Exits 1 and prints the
# differences when a restore would fail the backup job's schema step.
set -eu
C=$1; DB=$2
SQL="select table_schema, table_name, column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema not in ('pg_catalog', 'information_schema') order by 1, 2, 3;
select schemaname, tablename, indexname, indexdef from pg_indexes where schemaname not in ('pg_catalog', 'information_schema') order by 1, 2, 3;
select conrelid::regclass::text, conname, pg_get_constraintdef(oid) from pg_constraint where connamespace not in ('pg_catalog'::regnamespace, 'information_schema'::regnamespace) order by 1, 2;"
docker exec "$C" sh -c "set -e
pg_dump -U postgres -Fc --no-owner --no-privileges -f /tmp/check.dump '$DB'
dropdb -U postgres --if-exists schema_restore_check
createdb -U postgres schema_restore_check
pg_restore -U postgres --no-owner --no-privileges --exit-on-error -d schema_restore_check /tmp/check.dump
printf '%s\n' \"$SQL\" | psql -U postgres -X -A -t -q -v ON_ERROR_STOP=1 -d '$DB' > /tmp/source.schema
printf '%s\n' \"$SQL\" | psql -U postgres -X -A -t -q -v ON_ERROR_STOP=1 -d schema_restore_check > /tmp/restored.schema
if diff /tmp/source.schema /tmp/restored.schema; then echo 'schema identical after restore (PostgreSQL '\"\$(psql -U postgres -At -c 'show server_version')\"')'; else echo 'SCHEMA DIFFERS AFTER RESTORE: write the constraint as column::text IN (...) (docs/railway-deployment.md, Schema gotcha)'; exit 1; fi"
