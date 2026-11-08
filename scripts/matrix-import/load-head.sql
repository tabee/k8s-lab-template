-- First part of the import transaction. The live schema is renamed away inside the transaction; the dump (plain
-- pg_dump SQL, everything qualified with public.) builds a new schema public. Nothing is visible to other sessions
-- until COMMIT, and a ROLLBACK (dry run, or any error) leaves the live database exactly as it was.
BEGIN;
SET LOCAL lock_timeout = '30s';
ALTER SCHEMA public RENAME TO mxi_old;
CREATE SCHEMA public;
GRANT USAGE ON SCHEMA public TO PUBLIC;
