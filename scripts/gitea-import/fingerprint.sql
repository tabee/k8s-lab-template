-- fingerprint.sql: one hash over the user, organisation and repository content of the live database, to
-- tell "still exactly what the last import left" from "someone worked here since". :labadmin is the name
-- of the lab admin (created by the chart, not part of an import). Prints one line, a sha256.
SELECT encode(sha256(convert_to(coalesce(string_agg(x, E'\n' ORDER BY x), ''), 'UTF8')), 'hex') FROM (
  SELECT 'u:' || lower_name AS x FROM "user" WHERE id > 0 AND lower_name <> lower(:'labadmin')
  UNION ALL SELECT 'r:' || lower(owner_name) || '/' || lower_name || ':' || updated_unix FROM repository
  UNION ALL SELECT 'i:' || count(*) FROM issue
  UNION ALL SELECT 'c:' || count(*) FROM comment
  UNION ALL SELECT 'p:' || count(*) FROM pull_request
  UNION ALL SELECT 'l:' || count(*) FROM release
) s;
