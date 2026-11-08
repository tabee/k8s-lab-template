-- filter.sql: reduce a loaded Gitea dump (in the staging schema, search_path is set by the caller) to what
-- the import keeps: users, organisations, teams, repositories (with wiki, issues, releases, LFS metadata) and
-- the access between them. Everything else is emptied. Every table is only touched if it exists, so the same
-- file works for the Gitea versions between the source and the lab.
--
-- Dropped on purpose:
--   * webhooks and their delivery log (decision: webhooks are not imported)
--   * login state and credentials that cannot be moved: sessions, access tokens, OAuth2 applications and
--     grants, 2FA and WebAuthn (encrypted with the old SECRET_KEY or bound to the old domain), SSH/GPG/deploy
--     keys, secrets, runner registrations
--   * Actions data (runs, tasks, artifacts, variables) and packages (registry content stays on the VPS)
--   * mirrors (their credentials are encrypted with the old SECRET_KEY), caches, notices, system settings,
--     background tasks, uploads
SET client_min_messages TO warning;

DO $$
DECLARE
  t text;
  names text[] := ARRAY[
    'webhook', 'hook_task',
    'session', 'auth_token', 'access_token',
    'oauth2_application', 'oauth2_authorization_code', 'oauth2_grant',
    'two_factor', 'webauthn_credential',
    'public_key', 'gpg_key', 'gpg_key_import', 'deploy_key', 'secret',
    'package', 'package_blob', 'package_blob_upload', 'package_cleanup_rule', 'package_file',
    'package_property', 'package_version',
    'mirror', 'push_mirror', 'repo_archiver', 'repo_indexer_status', 'upload', 'task',
    'notice', 'system_setting', 'app_state', 'dbfs_meta', 'dbfs_data'
  ];
BEGIN
  FOREACH t IN ARRAY names LOOP
    IF to_regclass(quote_ident(t)) IS NOT NULL THEN
      EXECUTE format('DELETE FROM %I', t);
    END IF;
  END LOOP;
  -- all Actions tables (names start with action_, the activity feed is the table "action" and stays)
  FOR t IN SELECT c.relname FROM pg_class c
           WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = current_schema())
             AND c.relkind = 'r' AND c.relname LIKE 'action\_%'
  LOOP
    EXECUTE format('DELETE FROM %I', t);
  END LOOP;
END $$;

-- repositories: no mirrors any more; repositories generated from a template lose the link (the
-- template repositories themselves are removed after the start through the Gitea API)
UPDATE repository SET is_mirror = false WHERE is_mirror;
UPDATE repository SET template_id = 0
 WHERE template_id <> 0 AND template_id IN (SELECT id FROM repository WHERE is_template);

-- external authentication (LDAP, OAuth2, SMTP sources): the source definitions hold credentials sealed with the
-- old SECRET_KEY, so they are not imported. Their users become local users without a password (an admin sets
-- one, or the user uses "forgot password"). The importer prints the names (manifest line "X").
DO $$
BEGIN
  IF to_regclass('external_login_user') IS NOT NULL THEN DELETE FROM external_login_user; END IF;
  IF to_regclass('login_source') IS NOT NULL THEN DELETE FROM login_source; END IF;
END $$;
UPDATE "user" SET login_type = 0, login_source = 0, login_name = '' WHERE login_type <> 0;
