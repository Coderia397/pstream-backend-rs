-- Behaviour and security test for 20261004130000_accounts_core.sql.
-- Run with the Supabase MCP execute_sql or the SQL editor. Everything rolls back: the block always ends by raising an
-- exception whose message is the report ("RESULT" followed by PASS or FAIL lines). Each refusal is checked for its reason,
-- so a check cannot pass because of an unrelated error.
do $$
declare
  u1 uuid := gen_random_uuid();
  u2 uuid := gen_random_uuid();
  p1 uuid; p2 uuid; pk uuid;
  n integer; ok boolean; r jsonb;
  report text := '';
  t0 timestamptz := now() - interval '1 hour';
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (u1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'one@example.test', 'x', '{}', '{"full_name":"Tester One"}', now(), now()),
         (u2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'two@example.test', 'x', '{}', '{}', now(), now());

  select id into p1 from public.profiles where user_id = u1;
  select id into p2 from public.profiles where user_id = u2;
  report := report || case when p1 is not null and p2 is not null then 'PASS first profile created for each new account' else 'FAIL first profile missing' end || E'\n';
  report := report || case when (select name from public.profiles where id = p1) = 'Tester One' and (select name from public.profiles where id = p2) = 'two' then 'PASS first profile is named from the account (full name, else email name)' else 'FAIL first profile names' end || E'\n';
  select count(*) into n from public.profile_settings where profile_id in (p1, p2);
  report := report || case when n = 2 then 'PASS settings row created with each profile' else 'FAIL settings rows: ' || n end || E'\n';
  select count(*) into n from public.account_events where user_id in (u1, u2) and event = 'profile_created';
  report := report || case when n = 2 then 'PASS profile creation is logged' else 'FAIL profile_created events: ' || n end || E'\n';

  -- act as user one
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.profiles;
  report := report || case when n = 1 then 'PASS user one sees only their profile' else 'FAIL user one sees ' || n || ' profiles' end || E'\n';
  select count(*) into n from public.profiles where id = p2;
  report := report || case when n = 0 then 'PASS other user''s profile is invisible' else 'FAIL other user''s profile visible' end || E'\n';

  begin
    insert into public.profile_titles (profile_id, media_type, tmdb_id, in_list) values (p2, 'movie', 550, true);
    report := report || 'FAIL wrote a title into another user''s profile' || E'\n';
  exception when others then
    report := report || case when sqlerrm like '%row-level security%' then 'PASS cannot write into another user''s profile (row level security)' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- last write wins: a newer client write stands, an older one is ignored
  insert into public.profile_titles (profile_id, media_type, tmdb_id, in_list, client_updated_at) values (p1, 'movie', 550, true, now());
  insert into public.profile_titles (profile_id, media_type, tmdb_id, in_list, client_updated_at) values (p1, 'movie', 550, false, t0)
    on conflict (profile_id, media_type, tmdb_id) do update set in_list = excluded.in_list, client_updated_at = excluded.client_updated_at;
  select in_list into ok from public.profile_titles where profile_id = p1 and tmdb_id = 550;
  report := report || case when ok then 'PASS an older write does not overwrite a newer one' else 'FAIL older write won' end || E'\n';
  insert into public.profile_titles (profile_id, media_type, tmdb_id, in_list, client_updated_at) values (p1, 'movie', 550, false, now() + interval '1 minute')
    on conflict (profile_id, media_type, tmdb_id) do update set in_list = excluded.in_list, client_updated_at = excluded.client_updated_at;
  select in_list into ok from public.profile_titles where profile_id = p1 and tmdb_id = 550;
  report := report || case when not ok then 'PASS a newer write replaces an older one' else 'FAIL newer write lost' end || E'\n';
  insert into public.profile_titles (profile_id, media_type, tmdb_id, in_list, client_updated_at) values (p1, 'movie', 551, true, now() + interval '2 days');
  report := report || case when (select client_updated_at from public.profile_titles where profile_id = p1 and tmdb_id = 551) < now() + interval '6 minutes' then 'PASS a device clock far in the future is clamped to 5 minutes' else 'FAIL future timestamp not clamped' end || E'\n';

  -- batch push and incremental pull
  r := public.sync_push(p1, '[{"media_type":"tv","tmdb_id":1396,"in_list":true,"rating":"love"}]'::jsonb,
                            '[{"media_type":"tv","tmdb_id":1396,"season":1,"episode":2,"position_seconds":600,"duration_seconds":2700}]'::jsonb);
  report := report || case when (r ->> 'titles')::int = 1 and (r ->> 'progress')::int = 1 then 'PASS sync_push stores a batch' else 'FAIL sync_push ' || r::text end || E'\n';
  r := public.sync_pull(p1, 'epoch');
  report := report || case when jsonb_array_length(r -> 'titles') = 3 and jsonb_array_length(r -> 'progress') = 1 then 'PASS sync_pull returns the changes' else 'FAIL sync_pull ' || r::text end || E'\n';
  report := report || case when (r ->> 'cursor')::timestamptz < now() then 'PASS pull cursor trails the clock' else 'FAIL pull cursor is ahead of the clock' end || E'\n';
  report := report || case when (public.sync_pull(p1, 'infinity'::timestamptz) ->> 'cursor') is not null and jsonb_array_length(public.sync_pull(p1, 'infinity'::timestamptz) -> 'titles') = 0 then 'PASS nothing is returned after the cursor' else 'FAIL pull after the end' end || E'\n';
  r := public.sync_pull(p2, 'epoch');
  report := report || case when jsonb_array_length(r -> 'titles') = 0 then 'PASS sync_pull of another user''s profile is empty' else 'FAIL sync_pull leaked rows' end || E'\n';
  begin
    perform public.sync_push(p2, '[{"media_type":"movie","tmdb_id":1}]'::jsonb);
    report := report || 'FAIL sync_push into another user''s profile' || E'\n';
  exception when others then
    report := report || case when sqlerrm like '%row-level security%' then 'PASS sync_push into another user''s profile is refused (row level security)' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    perform public.sync_push(p1, (select jsonb_agg(jsonb_build_object('media_type', 'movie', 'tmdb_id', g)) from generate_series(1, 501) g));
    report := report || 'FAIL a batch of 501 was accepted' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'batch too large' then 'PASS a batch over 500 is refused' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- profile rules
  begin
    for n in 1..5 loop
      insert into public.profiles (user_id, name) values (u1, 'Extra ' || n);
    end loop;
    report := report || 'FAIL more than 5 profiles allowed' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'profile limit reached' then 'PASS profile limit of 5 holds' else 'FAIL limit refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    insert into public.profiles (user_id, name, kind, maturity) values (u1, 'Kid', 'kids', 'adult');
    report := report || 'FAIL a kids profile with adult maturity was accepted' || E'\n';
  exception when others then
    report := report || case when sqlerrm like '%profiles_kids_maturity%' then 'PASS a kids profile cannot have adult maturity' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  insert into public.profiles (user_id, name, kind, maturity) values (u1, 'Kid', 'kids', 'older_kids') returning id into pk;
  begin
    insert into public.profiles (user_id, name) values (u1, ' kid ');
    report := report || 'FAIL a duplicate profile name was accepted' || E'\n';
  exception when others then
    report := report || case when sqlerrm like '%profiles_user_name_key%' then 'PASS profile names are unique per account, ignoring case and spaces' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    update public.profiles set has_pin = true where id = p1;
    report := report || 'FAIL client changed has_pin' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'permission denied%' then 'PASS has_pin cannot be changed by the client' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  delete from public.profiles where id = pk;
  begin
    delete from public.profiles where id = p1;
    report := report || 'FAIL the last profile was deleted' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'an account needs at least one profile' then 'PASS the last profile of an account cannot be deleted' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- PIN
  perform public.set_profile_pin(p1, '1234');
  report := report || case when public.verify_profile_pin(p1, '1234') then 'PASS correct PIN accepted' else 'FAIL correct PIN rejected' end || E'\n';
  report := report || case when not public.verify_profile_pin(p1, '0000') then 'PASS wrong PIN rejected' else 'FAIL wrong PIN accepted' end || E'\n';
  begin
    perform public.set_profile_pin(p1, '9999');
    report := report || 'FAIL PIN changed without the current PIN' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'the current PIN is required' then 'PASS changing the PIN needs the current PIN' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    perform pin_hash from public.profile_pins;
    report := report || 'FAIL PIN table readable' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'permission denied%' then 'PASS PIN table is not readable by clients' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    perform public.pin_attempt(p1, '1234');
    report := report || 'FAIL the internal PIN helper is callable by clients' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'permission denied%' then 'PASS the internal PIN helper is not callable by clients' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  -- guesses through clear and set share the counter with verify: one wrong verify above, three wrong clears, one wrong set = 5
  ok := true;
  for n in 1..3 loop
    if public.clear_profile_pin(p1, '1111') then ok := false; end if;
  end loop;
  report := report || case when ok then 'PASS wrong PIN on clear is refused' else 'FAIL clear accepted a wrong PIN' end || E'\n';
  report := report || case when not public.set_profile_pin(p1, '5555', '2222') then 'PASS wrong current PIN on set is refused' else 'FAIL set accepted a wrong current PIN' end || E'\n';
  begin
    perform public.verify_profile_pin(p1, '1234');
    report := report || 'FAIL profile not locked after 5 wrong tries across verify, clear and set' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'too many attempts%' then 'PASS 5 wrong tries across verify, clear and set lock the profile' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    perform public.clear_profile_pin(p1, '1234');
    report := report || 'FAIL clear works while locked' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'too many attempts%' then 'PASS clear is refused while locked' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    perform public.set_profile_pin(p2, '4321');
    report := report || 'FAIL set a PIN on another user''s profile' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'not allowed' then 'PASS a PIN cannot be set on another user''s profile' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- audit log is readable by the owner and not writable
  select count(*) into n from public.account_events;
  report := report || case when n >= 3 then 'PASS owner can read their account events (' || n || ')' else 'FAIL account events ' || n end || E'\n';
  select count(*) into n from public.account_events where user_id = u2;
  report := report || case when n = 0 then 'PASS account events of other users are invisible' else 'FAIL account events leaked: ' || n end || E'\n';
  begin
    insert into public.account_events (user_id, event) values (u1, 'forged');
    report := report || 'FAIL client wrote an account event' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'permission denied%' then 'PASS clients cannot write account events' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- anonymous access
  reset role;
  set local role anon;
  begin
    perform count(*) from public.profiles;
    report := report || 'FAIL anonymous can read profiles' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'permission denied%' then 'PASS anonymous has no access to profiles' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    perform public.sync_pull(p1);
    report := report || 'FAIL anonymous can call sync_pull' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'permission denied%' then 'PASS anonymous cannot call the sync functions' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  reset role;

  -- deleting the account removes everything
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;
  select count(*) into n from public.profiles where user_id = u2;
  report := report || case when n = 0 then 'PASS deleting the account removes its profiles' else 'FAIL profiles left after account deletion' end || E'\n';
  select count(*) into n from public.profile_settings where profile_id = p2;
  report := report || case when n = 0 then 'PASS deleting the account removes the profile data' else 'FAIL profile data left after account deletion' end || E'\n';
  select count(*) into n from public.account_events where user_id = u2;
  report := report || case when n = 0 then 'PASS deleting the account removes its audit rows' else 'FAIL audit rows left after account deletion' end || E'\n';

  raise exception E'RESULT\n%', report;
end $$;
