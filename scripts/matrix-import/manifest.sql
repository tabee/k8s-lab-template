-- Facts of a Synapse database as "M key value" lines. Used on the staged dump (inside the import transaction) and on
-- the live database, so both sides are counted by the same SQL. The lab admin (psql variable labadmin) is left out.
-- The tables exist in every Synapse schema since long before the supported versions.
SELECT 'M users ' || count(*) FROM users WHERE split_part(name, ':', 1) <> '@' || :'labadmin';
SELECT 'M rooms ' || count(*) FROM rooms;
SELECT 'M events ' || count(*) FROM events;
SELECT 'M max_stream ' || coalesce(max(stream_ordering), 0) FROM events;
SELECT 'M local_media ' || count(*) FROM local_media_repository;
SELECT 'M devices ' || count(*) FROM devices WHERE split_part(user_id, ':', 1) <> '@' || :'labadmin';
SELECT 'M e2e_device_keys ' || count(*) FROM e2e_device_keys_json WHERE split_part(user_id, ':', 1) <> '@' || :'labadmin';
SELECT 'M e2e_one_time_keys ' || count(*) FROM e2e_one_time_keys_json WHERE split_part(user_id, ':', 1) <> '@' || :'labadmin';
SELECT 'M e2e_room_keys ' || count(*) FROM e2e_room_keys WHERE split_part(user_id, ':', 1) <> '@' || :'labadmin';
SELECT 'M access_tokens ' || count(*) FROM access_tokens WHERE split_part(user_id, ':', 1) <> '@' || :'labadmin';
