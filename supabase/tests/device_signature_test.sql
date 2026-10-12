-- Behaviour test for 20261012200000_device_signature.sql. Run it in the SQL editor after setup.sql.
-- Everything rolls back: the block ends by raising an exception whose message is the report ("RESULT" then PASS or FAIL lines).
do $$
declare
  u uuid := gen_random_uuid();
  other uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid();
  s2 uuid := gen_random_uuid();
  k1 text := 'device-key-aaaaaaaaaaaaaaaa';
  k2 text := 'device-key-bbbbbbbbbbbbbbbb';
  r jsonb; n integer; report text := '';
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ada@example.test', 'x', '{}', '{"first_name":"Ada","last_name":"Lovelace"}', now(), now()),
         (other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bob@example.test', 'x', '{}', '{"first_name":"Bob","last_name":"B"}', now(), now());
  insert into auth.sessions (id, user_id, created_at, updated_at, user_agent) values (s1, u, now(), now(), 'Raw agent one'), (s2, u, now(), now(), 'Raw agent two');

  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', s1, 'amr', json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint)))::text, true);
  set local role authenticated;

  -- first sign in from a browser: a new device
  r := public.register_device(k1, '{"browser":"Chrome","browser_major":156,"os":"Mac","device_type":"desktop","language":"en-GB","timezone":"Europe/London","screen":"1728x1117","user_agent":"Mozilla test","country":"GB"}'::jsonb);
  report := report || case when (r ->> 'is_new')::boolean then 'PASS a browser seen for the first time is a new device' else 'FAIL first sign in was not new' end || E'\n';

  -- same browser again, through a VPN in another country: the same device, the country is added, no new device
  r := public.register_device(k1, '{"browser":"Chrome","browser_major":157,"os":"Mac","device_type":"desktop","country":"NL"}'::jsonb);
  report := report || case when not (r ->> 'is_new')::boolean and (r ->> 'new_country')::boolean then 'PASS the same browser through a VPN is the same device with a new country' else 'FAIL VPN case' end || E'\n';
  reset role;
  select count(*) into n from public.account_devices where user_id = u;
  report := report || case when n = 1 then 'PASS still one device row' else 'FAIL device rows: ' || n end || E'\n';
  report := report || case when (select countries from public.account_devices where user_id = u) @> array['GB', 'NL'] and (select browser_major from public.account_devices where user_id = u) = 157 then 'PASS both countries are remembered and the browser version is updated' else 'FAIL countries or version' end || E'\n';
  report := report || case when (select count(*) from public.account_events where user_id = u and event = 'new_device') = 1 and (select count(*) from public.account_events where user_id = u and event = 'device_new_country') = 1 then 'PASS one new device entry and one quiet new country entry in the security log' else 'FAIL log entries' end || E'\n';

  -- the same country again adds nothing
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', s1, 'amr', '[]'::json)::text, true);
  set local role authenticated;
  r := public.register_device(k1, '{"country":"GB"}'::jsonb);
  report := report || case when not (r ->> 'new_country')::boolean then 'PASS a country already seen is not logged again' else 'FAIL repeated country' end || E'\n';

  -- a second browser (another key, another session)
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', s2, 'amr', '[]'::json)::text, true);
  r := public.register_device(k2, '{"browser":"Safari","os":"iPhone","device_type":"mobile","country":"GB"}'::jsonb);
  report := report || case when (r ->> 'is_new')::boolean then 'PASS a different browser is a second device' else 'FAIL second device' end || E'\n';

  -- the list joins sessions and devices
  select count(*) into n from public.list_my_sessions() where device_id is not null and browser is not null;
  report := report || case when n = 2 then 'PASS the device list shows the details of both sessions' else 'FAIL device list rows with details: ' || n end || E'\n';
  report := report || case when (select device_type from public.list_my_sessions() where id = s2) = 'mobile' and (select is_current from public.list_my_sessions() where id = s2) then 'PASS the current session is marked and carries its device type' else 'FAIL current session details' end || E'\n';

  -- rules
  begin
    perform public.register_device('short', '{}'::jsonb);
    report := report || 'FAIL a short key was accepted' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'invalid device key' then 'PASS a device key must be 16 to 64 characters' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  r := public.register_device('device-key-cccccccccccccccc', '{"device_type":"toaster","country":"gb1"}'::jsonb);
  reset role;
  report := report || case when (select device_type from public.account_devices where device_key = 'device-key-cccccccccccccccc') = 'other' and (select last_country from public.account_devices where device_key = 'device-key-cccccccccccccccc') is null
                      then 'PASS an unknown device type becomes other and a malformed country is dropped' else 'FAIL input clean up' end || E'\n';

  -- a client cannot write the table, and another account sees none of it
  set local role authenticated;
  begin
    insert into public.account_devices (user_id, device_key) values (u, 'device-key-dddddddddddddddd');
    report := report || 'FAIL a client wrote the devices table' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'permission denied%' then 'PASS only register_device can write devices' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', other, 'role', 'authenticated', 'amr', '[]'::json)::text, true);
  select count(*) into n from public.account_devices;
  report := report || case when n = 0 then 'PASS another account sees none of these devices' else 'FAIL another account saw ' || n || ' devices' end || E'\n';
  reset role;

  -- deleting the account removes the devices
  delete from auth.users where id = u;
  report := report || case when (select count(*) from public.account_devices where user_id = u) = 0 then 'PASS deleting the account removes its devices' else 'FAIL devices left' end || E'\n';

  raise exception E'RESULT\n%', report;
end $$;
