-- Behaviour test for 20261012100000_devices_and_profile_preferences.sql. Run it in the SQL editor after setup.sql.
-- Everything rolls back: the block ends by raising an exception whose message is the report ("RESULT" then PASS or FAIL lines).
do $$
declare
  u uuid := gen_random_uuid();
  other uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid();
  s2 uuid := gen_random_uuid();
  pm uuid; pk uuid;
  n integer; report text := '';
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ada@example.test', 'x', '{}', '{"first_name":"Ada","last_name":"Lovelace"}', now(), now()),
         (other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bob@example.test', 'x', '{}', '{"first_name":"Bob","last_name":"B"}', now(), now());
  insert into auth.sessions (id, user_id, created_at, updated_at, user_agent) values (s1, u, now(), now(), 'Test Browser A'), (s2, u, now(), now(), 'Test Browser B');
  select id into pm from public.profiles where user_id = u and is_main;

  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', s1, 'amr', json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint)))::text, true);
  set local role authenticated;

  select count(*) into n from public.list_my_sessions();
  report := report || case when n = 2 then 'PASS both sessions of the account are listed' else 'FAIL sessions listed: ' || n end || E'\n';
  report := report || case when (select is_current from public.list_my_sessions() where id = s1) and not (select is_current from public.list_my_sessions() where id = s2) then 'PASS the current session is marked' else 'FAIL current session flag' end || E'\n';

  perform public.revoke_my_session(s2);
  select count(*) into n from public.list_my_sessions();
  report := report || case when n = 1 then 'PASS another session can be signed out' else 'FAIL session count after revoke: ' || n end || E'\n';

  -- a session of another account is not touched
  reset role;
  insert into auth.sessions (id, user_id, created_at, updated_at) values (gen_random_uuid(), other, now(), now());
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', s1, 'amr', json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint)))::text, true);
  set local role authenticated;
  perform public.revoke_my_session((select id from auth.sessions where user_id = other limit 1));
  reset role;
  report := report || case when (select count(*) from auth.sessions where user_id = other) = 1 then 'PASS another account''s session is not removed' else 'FAIL removed a session of another account' end || E'\n';

  -- an old sign in cannot revoke
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', s1, 'amr', json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint - 4000)))::text, true);
  set local role authenticated;
  begin
    perform public.revoke_my_session(s1);
    report := report || 'FAIL revoked with an old sign in' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'recent sign in required' then 'PASS signing out a device needs a recent sign in' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- account switches
  perform public.set_account_switch('test_participation', false);
  reset role;
  report := report || case when not (select test_participation from public.account_details where user_id = u) then 'PASS a switch is saved' else 'FAIL switch not saved' end || E'\n';
  set local role authenticated;
  begin
    perform public.set_account_switch('is_main', true);
    report := report || 'FAIL an unknown switch was accepted' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'unknown switch' then 'PASS only known switches can be set' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- game handle: 3 to 16 letters and digits, unique ignoring case
  update public.profile_settings set game_handle = 'BoldFox42' where profile_id = pm;
  begin
    update public.profile_settings set game_handle = 'bad handle!' where profile_id = pm;
    report := report || 'FAIL an invalid game handle was accepted' || E'\n';
  exception when check_violation then
    report := report || 'PASS a game handle must be 3 to 16 letters and digits' || E'\n';
  end;
  select id into pk from public.profiles where user_id = u and auto_kids;
  begin
    update public.profile_settings set game_handle = 'boldfox42' where profile_id = pk;
    report := report || 'FAIL a game handle was used twice' || E'\n';
  exception when unique_violation then
    report := report || 'PASS a game handle is unique ignoring case' || E'\n';
  end;

  reset role;
  raise exception 'RESULT%', E'\n' || report;
end $$;
