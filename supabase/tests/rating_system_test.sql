-- Behaviour test for 20261013100000_rating_system.sql. Run it in the SQL editor after setup.sql.
-- Everything rolls back: the block ends by raising an exception whose message is the report ("RESULT" then PASS or FAIL lines).
do $$
declare
  u uuid := gen_random_uuid();
  other uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid();
  s2 uuid := gen_random_uuid();
  r text; report text := '';
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ada@example.test', 'x', '{}', '{"first_name":"Ada","last_name":"L"}', now(), now()),
         (other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bob@example.test', 'x', '{}', '{"first_name":"Bob","last_name":"B"}', now(), now());
  insert into auth.sessions (id, user_id, created_at, updated_at) values (s1, u, now(), now()), (s2, u, now(), now());

  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', s1)::text, true);
  set local role authenticated;

  -- no device known yet: british labels
  r := public.my_rating_system();
  report := report || case when r = 'uk' then 'PASS with no device the default is british' else 'FAIL default: ' || r end || E'\n';

  -- a device seen in the United States on this session: american on auto
  perform public.register_device('device-key-aaaaaaaaaaaaaaaa', '{"browser":"Chrome","device_type":"desktop","country":"US"}'::jsonb);
  r := public.my_rating_system();
  report := report || case when r = 'us' then 'PASS the country of the session device decides on auto' else 'FAIL us device: ' || r end || E'\n';

  -- a second session on another device in Britain: that session reads british
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', s2)::text, true);
  perform public.register_device('device-key-bbbbbbbbbbbbbbbb', '{"browser":"Safari","device_type":"mobile","country":"GB"}'::jsonb);
  r := public.my_rating_system();
  report := report || case when r = 'uk' then 'PASS another session on a british device reads british' else 'FAIL gb session: ' || r end || E'\n';
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', s1)::text, true);
  r := public.my_rating_system();
  report := report || case when r = 'us' then 'PASS the first session still reads american' else 'FAIL first session: ' || r end || E'\n';

  -- an unlisted country falls back to british
  perform public.register_device('device-key-cccccccccccccccc', '{"browser":"Firefox","device_type":"desktop","country":"JP"}'::jsonb);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', gen_random_uuid())::text, true);

  -- an explicit choice wins over the country
  perform public.set_rating_system('uk');
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', s1)::text, true);
  r := public.my_rating_system();
  report := report || case when r = 'uk' then 'PASS the account choice wins over the device country' else 'FAIL choice uk: ' || r end || E'\n';
  perform public.set_rating_system('us');
  r := public.my_rating_system();
  report := report || case when r = 'us' then 'PASS the account can choose american' else 'FAIL choice us: ' || r end || E'\n';
  perform public.set_rating_system('auto');
  r := public.my_rating_system();
  report := report || case when r = 'us' then 'PASS back on auto follows the device again' else 'FAIL back to auto: ' || r end || E'\n';

  -- only known systems are accepted
  begin
    perform public.set_rating_system('klingon');
    report := report || 'FAIL an unknown system was accepted' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'unknown rating system' then 'PASS an unknown system is refused' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- another account is not touched and the table cannot be written by a client
  reset role;
  report := report || case when (select rating_system from public.account_details where user_id = other) = 'auto' then 'PASS another account keeps auto' else 'FAIL other account changed' end || E'\n';
  set local role authenticated;
  begin
    insert into public.rating_system_by_country (country, system) values ('FR', 'us');
    report := report || 'FAIL a client wrote the country table' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'permission denied%' then 'PASS the country table cannot be written by a client' else 'FAIL country table: ' || sqlerrm end || E'\n';
  end;
  reset role;
  set local role anon;
  begin
    perform public.my_rating_system();
    report := report || 'FAIL anonymous called my_rating_system' || E'\n';
  exception when others then
    report := report || 'PASS anonymous cannot call my_rating_system' || E'\n';
  end;
  reset role;

  raise exception E'RESULT\n%', report;
end $$;
