-- Checks on the loaded dump, still inside the transaction. A problem prints "MXI-ABORT text" and ends the
-- session (psql \q): the open transaction is rolled back. matrix-import.sh adds manifest.sql, the line MXI-LOADED and COMMIT or ROLLBACK after this file.
-- pg_dump ends with an empty search_path
SET search_path TO public;
SELECT to_regclass('public.users') IS NOT NULL AND to_regclass('public.rooms') IS NOT NULL
  AND to_regclass('public.events') IS NOT NULL AND to_regclass('public.schema_version') IS NOT NULL AS tables_ok \gset
\if :tables_ok
\else
  \echo MXI-ABORT the SQL did not create the Synapse tables (users, rooms, events, schema_version)
  \q
\endif
SELECT count(*) > 0 AS foreign_users FROM users WHERE name NOT LIKE '%:' || :'server_name' \gset
\if :foreign_users
  \echo MXI-ABORT the dump holds users that do not belong to server_name :server_name
  \q
\endif
SELECT count(*) > 0 AS clash FROM users WHERE name = '@' || :'labadmin' || ':' || :'server_name' \gset
\if :clash
  \echo MXI-ABORT the dump has a user named like the lab admin (:labadmin). ensure-admin would treat it as present and keep its password and admin flag. Rename the lab admin in secrets/matrix/matrix-admin.sops.yaml (lab.sh init) or the user on the source, then run again.
  \q
\endif
SELECT 'V ' || max(version) FROM schema_version;
