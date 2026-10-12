-- Behaviour test: a second profile with every kind of data, deleted, then the whole account deleted. Run it in the SQL editor
-- after setup.sql. Everything rolls back: the block ends by raising an exception whose message is the report ("RESULT", then
-- PASS or FAIL lines, and a COUNT line before and after each deletion so you can see exactly what stays and what goes).
do $$
declare
  a uuid := gen_random_uuid();   -- the account under test
  b uuid := gen_random_uuid();   -- another account, to prove nothing leaks across
  pm uuid; ps uuid; pb uuid;
  n integer; report text := '';
  claims_a text; claims_b text;

begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ada@example.test', 'x', '{}', '{"first_name":"Ada","last_name":"Lovelace"}', now(), now()),
         (b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bob@example.test', 'x', '{}', '{"first_name":"Bob","last_name":"Byron"}', now(), now());
  select id into pm from public.profiles where user_id = a and is_main;
  select id into pb from public.profiles where user_id = b and is_main;
  claims_a := json_build_object('sub', a, 'role', 'authenticated', 'amr', json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint)))::text;
  claims_b := json_build_object('sub', b, 'role', 'authenticated', 'amr', json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint)))::text;

  -- the main profile gets some data too, so we can see that it is not touched later
  perform set_config('request.jwt.claims', claims_a, true);
  set local role authenticated;
  perform public.sync_push(pm, '[{"media_type":"movie","tmdb_id":603,"in_list":true,"rating":"love"}]'::jsonb,
                               '[{"media_type":"movie","tmdb_id":603,"position_seconds":120,"duration_seconds":8160}]'::jsonb);
  update public.profile_settings set autoplay_next = false, game_handle = 'MainFox1' where profile_id = pm;

  -- the secondary profile with everything filled in --------------------------------------------------------------------------
  insert into public.profiles (user_id, name, avatar, kind, maturity, sort_order) values (a, 'Second', 'fox', 'adult', 'teens', 2) returning id into ps;
  update public.profile_settings
     set autoplay_next = false, autoplay_previews = false, audio_language = 'fr', subtitle_language = 'off', ui_language = 'fr',
         subtitle_style = '{"size":2,"color":"yellow","edge":"shadow","edge_color":"black","background":"none"}'::jsonb,
         data_usage = 'low', notifications = '{"email":false,"push.new_arrivals":true}'::jsonb,
         blocked_titles = '["Some Show","Another Film"]'::jsonb, game_handle = 'SecondFox7', age_rating = '15'
   where profile_id = ps;
  perform public.set_profile_pin(ps, '1234');
  perform public.sync_push(ps, '[{"media_type":"movie","tmdb_id":27205,"in_list":true,"rating":"up"},{"media_type":"tv","tmdb_id":1399,"in_list":false,"rating":"love"}]'::jsonb,
                               '[{"media_type":"tv","tmdb_id":1399,"season":1,"episode":3,"position_seconds":600,"duration_seconds":3300},{"media_type":"movie","tmdb_id":27205,"position_seconds":4000,"duration_seconds":8880,"completed":true}]'::jsonb);
  insert into public.profile_taste (profile_id, genre_weights, taste_version) values (ps, '{"878": 0.9, "18": 0.4}'::jsonb, 3);
  insert into public.feed_events (profile_id, event, media_type, tmdb_id, row_title, position) values (ps, 'click', 'movie', 27205, 'Because you watched', 2), (ps, 'start', 'movie', 27205, 'Top picks', 0);

  -- what is stored for the secondary profile, counted as the owner of the database
  reset role;
  report := report || 'COUNT before deleting the secondary profile: ' ||
    'profile=' || (select count(*) from public.profiles where id = ps) ||
    ' settings=' || (select count(*) from public.profile_settings where profile_id = ps) ||
    ' pin=' || (select count(*) from public.profile_pins where profile_id = ps) ||
    ' titles=' || (select count(*) from public.profile_titles where profile_id = ps) ||
    ' progress=' || (select count(*) from public.watch_progress where profile_id = ps) ||
    ' taste=' || (select count(*) from public.profile_taste where profile_id = ps) ||
    ' feed_events=' || (select count(*) from public.feed_events where profile_id = ps) || E'\n';
  report := report || case when (select count(*) from public.profile_settings where profile_id = ps and game_handle = 'SecondFox7' and age_rating = '15' and data_usage = 'low' and ui_language = 'fr' and jsonb_array_length(blocked_titles) = 2) = 1
                      then 'PASS every setting of the secondary profile was saved' else 'FAIL settings not saved' end || E'\n';
  report := report || case when (select has_pin from public.profiles where id = ps) and (select count(*) from public.profile_pins where profile_id = ps) = 1 then 'PASS the PIN is stored as a hash and the profile is flagged' else 'FAIL PIN' end || E'\n';
  report := report || case when (select pin_hash from public.profile_pins where profile_id = ps) <> '1234' then 'PASS the PIN itself is not stored' else 'FAIL the PIN is stored in the clear' end || E'\n';

  -- another account cannot see or delete it ------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', claims_b, true);
  set local role authenticated;
  select count(*) into n from public.profile_titles where profile_id = ps;
  report := report || case when n = 0 then 'PASS another account cannot read the profile data' else 'FAIL another account read ' || n || ' rows' end || E'\n';
  delete from public.profiles where id = ps;
  reset role;
  report := report || case when exists (select 1 from public.profiles where id = ps) then 'PASS another account cannot delete the profile' else 'FAIL another account deleted the profile' end || E'\n';

  -- delete the secondary profile as its owner ----------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', claims_a, true);
  set local role authenticated;
  delete from public.profiles where id = ps;
  reset role;
  report := report || 'COUNT after deleting the secondary profile:  ' ||
    'profile=' || (select count(*) from public.profiles where id = ps) ||
    ' settings=' || (select count(*) from public.profile_settings where profile_id = ps) ||
    ' pin=' || (select count(*) from public.profile_pins where profile_id = ps) ||
    ' titles=' || (select count(*) from public.profile_titles where profile_id = ps) ||
    ' progress=' || (select count(*) from public.watch_progress where profile_id = ps) ||
    ' taste=' || (select count(*) from public.profile_taste where profile_id = ps) ||
    ' feed_events=' || (select count(*) from public.feed_events where profile_id = ps) || E'\n';
  report := report || case when
      (select count(*) from public.profiles where id = ps) + (select count(*) from public.profile_settings where profile_id = ps) + (select count(*) from public.profile_pins where profile_id = ps)
    + (select count(*) from public.profile_titles where profile_id = ps) + (select count(*) from public.watch_progress where profile_id = ps)
    + (select count(*) from public.profile_taste where profile_id = ps) + (select count(*) from public.feed_events where profile_id = ps) = 0
      then 'PASS deleting a profile removes its settings, PIN, list, ratings, progress, taste and events' else 'FAIL something of the profile is left' end || E'\n';
  report := report || case when (select count(*) from public.profile_titles where profile_id = pm) = 1 and (select count(*) from public.watch_progress where profile_id = pm) = 1 and (select game_handle from public.profile_settings where profile_id = pm) = 'MainFox1'
                      then 'PASS the main profile and its data are untouched' else 'FAIL the main profile lost data' end || E'\n';
  report := report || case when exists (select 1 from auth.users where id = a) and exists (select 1 from public.account_details where user_id = a) then 'PASS the account itself is still there' else 'FAIL the account changed' end || E'\n';
  report := report || case when (select count(*) from public.account_events where user_id = a and event = 'profile_deleted') = 1 then 'PASS the deletion was written to the security log' else 'FAIL no security log entry' end || E'\n';

  -- the game handle is free again
  perform set_config('request.jwt.claims', claims_a, true);
  set local role authenticated;
  update public.profile_settings set game_handle = 'SecondFox7' where profile_id = pm;
  reset role;
  report := report || 'PASS a deleted profile frees its game handle' || E'\n';

  -- delete the whole account ----------------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', claims_a, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;
  report := report || 'COUNT after deleting the account (account a):  ' ||
    'user=' || (select count(*) from auth.users where id = a) ||
    ' details=' || (select count(*) from public.account_details where user_id = a) ||
    ' profiles=' || (select count(*) from public.profiles where user_id = a) ||
    ' settings=' || (select count(*) from public.profile_settings where profile_id = pm) ||
    ' titles=' || (select count(*) from public.profile_titles where profile_id = pm) ||
    ' progress=' || (select count(*) from public.watch_progress where profile_id = pm) ||
    ' events=' || (select count(*) from public.account_events where user_id = a) || E'\n';
  report := report || case when (select count(*) from auth.users where id = a) + (select count(*) from public.account_details where user_id = a) + (select count(*) from public.profiles where user_id = a)
                              + (select count(*) from public.profile_settings where profile_id = pm) + (select count(*) from public.profile_titles where profile_id = pm)
                              + (select count(*) from public.watch_progress where profile_id = pm) + (select count(*) from public.account_events where user_id = a) = 0
                      then 'PASS deleting the account removes the user, details, profiles, all profile data and the security log' else 'FAIL something of the account is left' end || E'\n';
  report := report || case when exists (select 1 from auth.users where id = b) and (select count(*) from public.profiles where user_id = b) = 2 then 'PASS the other account is untouched' else 'FAIL the other account changed' end || E'\n';

  raise exception E'RESULT\n%', report;
end $$;
