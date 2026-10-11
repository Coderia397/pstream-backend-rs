-- Accounts, second step (owner decisions of 2026-10-11).
--   * The account asks for a first and a last name at signup. The main profile is named after the first name.
--   * Every account gets a Kids profile with the striped icon. It can be deleted and does not count toward the limit of five.
--   * The main profile can be moved to another profile after the person proves who they are again.
--   * Actions that a child on a signed in parent session must not be able to do (moving the main profile, changing a profile to
--     Kids or adult, resetting a PIN, deleting the account) need a password entry in the last five minutes.
-- Everything here can be run again: columns, tables and indexes are created only when missing, functions are replaced, and the
-- backfill touches only accounts that still need it.

alter table public.profiles add column if not exists is_main boolean not null default false;
alter table public.profiles add column if not exists auto_kids boolean not null default false;
create unique index if not exists profiles_one_main on public.profiles (user_id) where is_main;
create unique index if not exists profiles_one_auto_kids on public.profiles (user_id) where auto_kids;

-- Name of the person behind the account (shown on the Account page; the main profile starts from the first name) ----------------
create table if not exists public.account_details (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  first_name text not null default '' check (char_length(first_name) <= 60),
  last_name  text not null default '' check (char_length(last_name) <= 60),
  updated_at timestamptz not null default now()
);
comment on table public.account_details is 'First and last name given at signup. Changed only through update_account_names.';
alter table public.account_details enable row level security;
drop policy if exists account_details_owner_select on public.account_details;
create policy account_details_owner_select on public.account_details for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.account_details from anon, authenticated;
grant select on public.account_details to authenticated;

-- Proof of a recent sign in -------------------------------------------------------------------------------------------------
-- The time the password (or a one time code, link or provider) was last used is in the token's authentication methods (amr). A
-- token refresh keeps that time, so a stolen refresh token cannot pass for a fresh sign in the way the token's own issue time
-- could. The app asks for the password again, which creates a new sign in, before it calls one of the functions below.
create or replace function public.require_recent_sign_in(p_seconds integer default 300) returns void
language plpgsql stable set search_path = public as $$
declare
  v_last bigint;
begin
  select max((e ->> 'timestamp')::bigint) into v_last
    from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) e
   where e ->> 'method' in ('password', 'otp', 'magiclink', 'oauth');
  if v_last is null or extract(epoch from now())::bigint - v_last > p_seconds then
    raise exception 'recent sign in required' using errcode = '28000';
  end if;
end $$;

-- The two flags, the Kids rules and the sensitive changes ----------------------------------------------------------------------
-- Columns is_main and auto_kids are not granted to clients at all; this trigger is a second lock, and it adds the rule that
-- changing a profile between Kids and adult, or its maturity, needs a recent sign in.
create or replace function public.profile_flags_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.is_main and new.kind = 'kids' then
    raise exception 'a Kids profile cannot be the main profile' using errcode = '22023';
  end if;
  if coalesce(current_setting('streams.flags', true), '') = 'on' then
    return new;
  end if;
  if tg_op = 'INSERT' and (new.is_main or new.auto_kids) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' then
    if new.is_main is distinct from old.is_main or new.auto_kids is distinct from old.auto_kids then
      raise exception 'not allowed' using errcode = '42501';
    end if;
    if new.kind is distinct from old.kind or new.maturity is distinct from old.maturity then
      perform public.require_recent_sign_in();
    end if;
  end if;
  return new;
end $$;

drop trigger if exists profiles_flags_guard on public.profiles;
create trigger profiles_flags_guard before insert or update on public.profiles
  for each row execute function public.profile_flags_guard();

-- Five profiles per account. The automatic Kids profile is not counted.
create or replace function public.enforce_profile_limit() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.auto_kids then
    return new;
  end if;
  -- two parallel inserts for one account must not both pass the count
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));
  if (select count(*) from public.profiles where user_id = new.user_id and not auto_kids) >= 5 then
    raise exception 'profile limit reached' using errcode = 'P0001';
  end if;
  return new;
end $$;

-- A new account gets its details, its main profile (named after the first name) and the Kids profile.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare
  v_first text := left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'first_name'), ''), ''), 60);
  v_last  text := left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'last_name'), ''), ''), 60);
  v_name  text;
begin
  perform set_config('streams.flags', 'on', true);
  insert into public.account_details (user_id, first_name, last_name) values (new.id, v_first, v_last)
    on conflict (user_id) do nothing;
  v_name := left(
    coalesce(
      nullif(v_first, ''),
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'Me'),
    30);
  if lower(btrim(v_name)) = 'kids' then
    v_name := 'Me';
  end if;
  insert into public.profiles (user_id, name, is_main, sort_order) values (new.id, v_name, true, 0);
  insert into public.profiles (user_id, name, avatar, kind, maturity, auto_kids, sort_order)
  values (new.id, 'Kids', 'kids', 'kids', 'older_kids', true, 1);
  perform set_config('streams.flags', 'off', true);
  return new;
end $$;

-- The last profile stays, and so does the main one until another profile has taken its place.
create or replace function public.keep_last_profile() returns trigger
language plpgsql set search_path = public, auth as $$
begin
  if exists (select 1 from auth.users u where u.id = old.user_id) then
    if (select count(*) from public.profiles where user_id = old.user_id) <= 1 then
      raise exception 'an account needs at least one profile' using errcode = 'P0001';
    end if;
    if old.is_main then
      raise exception 'make another profile the main one before deleting this one' using errcode = 'P0001';
    end if;
  end if;
  return old;
end $$;

-- Functions the app calls ------------------------------------------------------------------------------------------------------
create or replace function public.set_main_profile(p_profile uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare
  v_owner uuid;
  v_kind  text;
begin
  select user_id, kind into v_owner, v_kind from public.profiles where id = p_profile;
  if v_owner is null or v_owner is distinct from (select auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_kind = 'kids' then
    raise exception 'a Kids profile cannot be the main profile' using errcode = '22023';
  end if;
  perform public.require_recent_sign_in();
  perform set_config('streams.flags', 'on', true);
  update public.profiles set is_main = false where user_id = v_owner and is_main and id <> p_profile;
  update public.profiles set is_main = true where id = p_profile;
  perform set_config('streams.flags', 'off', true);
  perform public.log_account_event(v_owner, 'main_profile_changed', jsonb_build_object('profile_id', p_profile));
end $$;

-- Forgot the PIN: after entering the account password again, the PIN of one of your profiles is removed and a new one can be set.
create or replace function public.reset_profile_pin(p_profile uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare
  v_owner uuid;
begin
  select user_id into v_owner from public.profiles where id = p_profile;
  if v_owner is null or v_owner is distinct from (select auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  perform public.require_recent_sign_in();
  delete from public.profile_pins where profile_id = p_profile;
  perform set_config('streams.flags', 'on', true);
  update public.profiles set has_pin = false where id = p_profile;
  perform set_config('streams.flags', 'off', true);
  perform public.log_account_event(v_owner, 'pin_reset', jsonb_build_object('profile_id', p_profile));
end $$;

-- Change the first or last name. The main profile follows when it still carries the old first name.
create or replace function public.update_account_names(p_first text, p_last text) returns void
language plpgsql security definer set search_path = public, auth as $$
declare
  v_user uuid := (select auth.uid());
  v_old  text;
  v_first text := left(btrim(coalesce(p_first, '')), 60);
  v_last  text := left(btrim(coalesce(p_last, '')), 60);
begin
  if v_user is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_first = '' or v_last = '' then
    raise exception 'first and last name are required' using errcode = '22023';
  end if;
  select first_name into v_old from public.account_details where user_id = v_user;
  insert into public.account_details (user_id, first_name, last_name) values (v_user, v_first, v_last)
    on conflict (user_id) do update set first_name = excluded.first_name, last_name = excluded.last_name, updated_at = now();
  update auth.users
     set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
         || jsonb_build_object('first_name', v_first, 'last_name', v_last, 'full_name', btrim(v_first || ' ' || v_last))
   where id = v_user;
  update public.profiles set name = left(v_first, 30)
   where user_id = v_user and is_main and lower(btrim(name)) = lower(btrim(coalesce(v_old, '')))
     and not exists (select 1 from public.profiles o where o.user_id = v_user and not o.is_main and lower(btrim(o.name)) = lower(btrim(left(v_first, 30))));
end $$;

-- Delete the account, only right after the password has been entered again.
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  perform public.require_recent_sign_in();
  delete from auth.users where id = (select auth.uid());
end $$;

-- Everything held about the signed in person, for the right of access in the Privacy Policy. Row level security applies, so it
-- can only ever return their own rows. PIN hashes are not included.
create or replace function public.export_my_data() returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'exported_at', now(),
    'account', (select to_jsonb(a) - 'user_id' from public.account_details a limit 1),
    'profiles', (select coalesce(jsonb_agg(to_jsonb(p) - 'user_id' order by p.sort_order), '[]'::jsonb) from public.profiles p),
    'my_list_and_ratings', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.profile_titles t),
    'watch_progress', (select coalesce(jsonb_agg(to_jsonb(w)), '[]'::jsonb) from public.watch_progress w),
    'settings', (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from public.profile_settings s),
    'security_events', (select coalesce(jsonb_agg(to_jsonb(e) - 'user_id' order by e.ts desc), '[]'::jsonb) from public.account_events e)
  )
$$;

revoke all on function public.require_recent_sign_in(integer), public.profile_flags_guard(), public.handle_new_user(), public.keep_last_profile(), public.enforce_profile_limit() from public, anon, authenticated;
revoke all on function public.set_main_profile(uuid), public.reset_profile_pin(uuid), public.update_account_names(text, text), public.delete_my_account(), public.export_my_data() from public, anon;
grant execute on function public.set_main_profile(uuid), public.reset_profile_pin(uuid), public.update_account_names(text, text), public.delete_my_account(), public.export_my_data() to authenticated;
grant execute on function public.require_recent_sign_in(integer) to authenticated;

-- Accounts that existed before this step: details from the signup data, and the oldest adult profile becomes the main one. ------
do $$
begin
  perform set_config('streams.flags', 'on', true);
  insert into public.account_details (user_id, first_name, last_name)
  select u.id, left(coalesce(u.raw_user_meta_data ->> 'first_name', ''), 60), left(coalesce(u.raw_user_meta_data ->> 'last_name', ''), 60)
    from auth.users u
  on conflict (user_id) do nothing;
  update public.profiles p set is_main = true
   where p.id in (select distinct on (user_id) id from public.profiles where kind = 'adult' order by user_id, created_at)
     and not exists (select 1 from public.profiles m where m.user_id = p.user_id and m.is_main);
  perform set_config('streams.flags', 'off', true);
end $$;
