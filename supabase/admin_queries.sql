-- Read only queries for looking at accounts as the person running the service. Paste one at a time in the Supabase SQL editor
-- (it runs with full rights, so nothing here is available to the app or to anyone signed in). Nothing here changes data.

-- 1. All accounts: who they are, when they joined, how much they use it
select u.id                         as account_id,          -- the identity of the account: auth.users.id, a uuid that never changes
       u.email,                                             -- what they sign in with (unique, but they can change it)
       d.first_name, d.last_name,
       u.created_at                 as joined,
       u.email_confirmed_at is not null as email_confirmed,
       u.last_sign_in_at,
       (select count(*) from public.profiles p where p.user_id = u.id)                                    as profiles,
       (select count(*) from public.profile_titles t join public.profiles p on p.id = t.profile_id where p.user_id = u.id) as list_and_ratings,
       (select count(*) from public.watch_progress w join public.profiles p on p.id = w.profile_id where p.user_id = u.id) as watched_titles,
       (select count(*) from auth.sessions s where s.user_id = u.id)                                      as signed_in_browsers
  from auth.users u
  left join public.account_details d on d.user_id = u.id
 order by u.created_at desc;

-- 2. One account by email: replace the address
select u.id as account_id, u.email, u.created_at, u.last_sign_in_at, u.raw_user_meta_data
  from auth.users u where lower(u.email) = lower('someone@example.com');

-- 3. The profiles of one account (replace the account id from query 1 or 2)
select p.id as profile_id, p.name, p.kind, p.is_main, p.auto_kids, p.has_pin, p.maturity, s.age_rating, s.game_handle, p.created_at
  from public.profiles p left join public.profile_settings s on s.profile_id = p.id
 where p.user_id = '00000000-0000-0000-0000-000000000000' order by p.sort_order;

-- 4. Recent security events of one account
select ts, event, meta from public.account_events where user_id = '00000000-0000-0000-0000-000000000000' order by ts desc limit 50;
