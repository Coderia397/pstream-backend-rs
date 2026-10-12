-- Behaviour test for 20261011150000_main_profile_and_default_kids.sql. Run it in the SQL editor after the migration.
-- Everything rolls back: the block ends by raising an exception whose message is the report ("RESULT" then PASS or FAIL lines).
do $$
declare
  u uuid := gen_random_uuid();
  pm uuid; pk uuid; pa uuid; pb uuid;
  n integer; report text := '';
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ada@example.test', 'x', '{}', '{"first_name":"Ada","last_name":"Lovelace"}', now(), now());

  select id into pm from public.profiles where user_id = u and is_main;
  select id into pk from public.profiles where user_id = u and auto_kids;
  report := report || case when (select name from public.profiles where id = pm) = 'Ada' then 'PASS main profile is named after the first name' else 'FAIL main profile name' end || E'\n';
  report := report || case when (select kind from public.profiles where id = pk) = 'kids' and (select name from public.profiles where id = pk) = 'Kids' then 'PASS a Kids profile is created with the account' else 'FAIL Kids profile missing' end || E'\n';

  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'amr', json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint)))::text, true);
  set local role authenticated;

  -- the Kids profile does not count: four more regular profiles fit (main + 4 = 5), the next one does not
  insert into public.profiles (user_id, name) values (u, 'Two'), (u, 'Three'), (u, 'Four'), (u, 'Five');
  begin
    insert into public.profiles (user_id, name) values (u, 'Six');
    report := report || 'FAIL a sixth regular profile was allowed' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'profile limit reached' then 'PASS five regular profiles plus the Kids profile' else 'FAIL limit refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- a client cannot set the flags itself
  begin
    update public.profiles set is_main = true where user_id = u and name = 'Two';
    report := report || 'FAIL a client made a profile main' || E'\n';
  exception when others then
    -- refused either by the column privileges (no update right on is_main) or by the guard trigger; both are a pass
    report := report || case when sqlerrm = 'not allowed' or sqlerrm like 'permission denied for table profiles%' then 'PASS a client cannot set is_main' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    insert into public.profiles (user_id, name, auto_kids) values (u, 'Sneaky', true);
    report := report || 'FAIL a client hid a profile from the limit' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'not allowed' or sqlerrm like 'permission denied for table profiles%' then 'PASS a client cannot set auto_kids' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- the main profile cannot be deleted until another one takes its place
  begin
    delete from public.profiles where id = pm;
    report := report || 'FAIL the main profile was deleted' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'make another profile the main one%' then 'PASS the main profile cannot be deleted first' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- moving the main profile
  select id into pa from public.profiles where user_id = u and name = 'Two';
  begin
    perform public.set_main_profile(pk);
    report := report || 'FAIL a Kids profile became main' || E'\n';
  exception when others then
    report := report || case when sqlerrm like 'a Kids profile cannot%' then 'PASS a Kids profile cannot be main' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  perform public.set_main_profile(pa);
  report := report || case when (select is_main from public.profiles where id = pa) and not (select is_main from public.profiles where id = pm) then 'PASS the main profile moved after a recent sign in' else 'FAIL main profile did not move' end || E'\n';
  delete from public.profiles where id = pm;
  report := report || 'PASS the old main profile can be deleted after the move' || E'\n';

  -- an old password entry is refused
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'amr', json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint - 3600)))::text, true);
  select id into pb from public.profiles where user_id = u and name = 'Three';
  begin
    perform public.set_main_profile(pb);
    report := report || 'FAIL an old sign in moved the main profile' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'recent sign in required' then 'PASS a sign in older than five minutes is refused' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- sensitive actions with the stale sign in still in place
  begin
    perform public.reset_profile_pin(pb);
    report := report || 'FAIL a PIN was reset without a recent sign in' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'recent sign in required' then 'PASS resetting a PIN needs a recent sign in' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    perform public.delete_my_account();
    report := report || 'FAIL the account was deleted without a recent sign in' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'recent sign in required' then 'PASS deleting the account needs a recent sign in' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;
  begin
    update public.profiles set kind = 'kids', maturity = 'older_kids' where id = pb;
    report := report || 'FAIL a profile was switched to Kids without a recent sign in' || E'\n';
  exception when others then
    report := report || case when sqlerrm = 'recent sign in required' then 'PASS changing Kids or adult needs a recent sign in' else 'FAIL refused for another reason: ' || sqlerrm end || E'\n';
  end;

  -- names and data export need no recent sign in
  perform public.update_account_names('Augusta', 'King');
  report := report || case when (select first_name || ' ' || last_name from public.account_details) = 'Augusta King' then 'PASS names can be changed' else 'FAIL names not changed' end || E'\n';
  report := report || case when jsonb_array_length(public.export_my_data() -> 'profiles') >= 4 then 'PASS the data export lists the profiles' else 'FAIL data export' end || E'\n';

  reset role;
  raise exception E'RESULT\n%', report;
end $$;
