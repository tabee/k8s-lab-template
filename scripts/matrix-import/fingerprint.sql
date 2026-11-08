-- One value that changes when someone uses the lab Matrix (accounts, rooms, events, media). Devices and tokens are
-- left out on purpose: the acceptance itself logs in. The lab admin is left out.
SELECT md5(concat_ws('|',
  (SELECT count(*) FROM users WHERE split_part(name, ':', 1) <> '@' || :'labadmin'),
  (SELECT count(*) FROM rooms),
  (SELECT count(*) FROM events),
  (SELECT coalesce(max(stream_ordering), 0) FROM events),
  (SELECT count(*) FROM local_media_repository)));
