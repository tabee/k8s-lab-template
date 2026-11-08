-- manifest.sql: facts about the (filtered) staged dump, one per line, "KEY value". Run with -At and the
-- search_path of the staging schema. No secret is printed (names and counts only).
SELECT 'U ' || lower_name FROM "user" WHERE id > 0 AND type = 0 ORDER BY lower_name;
SELECT 'O ' || lower_name FROM "user" WHERE id > 0 AND type = 1 ORDER BY lower_name;
SELECT 'R ' || lower(owner_name) || '/' || lower_name FROM repository WHERE NOT is_template ORDER BY 1;
SELECT 'T ' || lower(owner_name) || '/' || lower_name FROM repository WHERE is_template ORDER BY 1;
SELECT 'X ' || lower_name FROM "user" WHERE id > 0 AND login_type <> 0 ORDER BY lower_name;
SELECT 'A ' || coalesce(passwd_hash_algo, '') || ' ' || count(*) FROM "user"
 WHERE id > 0 AND type = 0 AND passwd <> '' GROUP BY passwd_hash_algo ORDER BY 1;
SELECT 'V ' || version FROM version ORDER BY id DESC LIMIT 1;
