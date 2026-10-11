-- A main profile that can be moved after a recent sign in, and a Kids profile created with every account.
-- Decisions (owner, 2026-10-11): the account asks for first and last name at signup; the main profile is named after the first
-- name; a deletable Kids profile with the striped icon is created automatically and does not count toward the profile limit;
-- the main profile can be moved to another profile after the person proves who they are again.

alter table public.profiles add column if not exists is_main boolean not null default false;
alter table public.profiles add column if not exists auto_kids boolean not null default false;

create unique index if not exists profiles_one_main on public.profiles (user_id) where is_main;
create unique index if not exists profiles_one_auto_kids on public.profiles (user_id) where auto_kids;

-- Only the functions below may set the two flags. A signed in client cannot make itself main or hide a profile from the limit.
create or replace function public.profile_flags_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('streams.flags', true), '') = 'on' then
    return new;
  end if;
  if tg_op = 'INSERT' and (new.is_main or new.auto_kids) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and (new.is_main is distinct from old.is_main or new.auto_kids is distinct from old.auto_kids) then
    raise exception 'not allowed' using errcode = '42501';
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

-- A new account gets its main profile, named after the first name, and the Kids profile.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare
  v_name text;
begin
  perform set_config('streams.flags', 'on', true);
  v_name := left(
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'first_name'), ''),
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

-- Moves the main profile. The access token must come from a sign in in the last five minutes, so the app asks for the
-- password again first.
create or replace function public.set_main_profile(p_profile uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare
  v_owner uuid;
  v_kind  text;
  v_iat   bigint;
begin
  select user_id, kind into v_owner, v_kind from public.profiles where id = p_profile;
  if v_owner is null or v_owner is distinct from (select auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_kind = 'kids' then
    raise exception 'a Kids profile cannot be the main profile' using errcode = '22023';
  end if;
  v_iat := coalesce((auth.jwt() ->> 'iat')::bigint, 0);
  if extract(epoch from now())::bigint - v_iat > 300 then
    raise exception 'recent sign in required' using errcode = '28000';
  end if;
  perform set_config('streams.flags', 'on', true);
  update public.profiles set is_main = false where user_id = v_owner and is_main and id <> p_profile;
  update public.profiles set is_main = true where id = p_profile;
  perform set_config('streams.flags', 'off', true);
  perform public.log_account_event(v_owner, 'main_profile_changed', jsonb_build_object('profile_id', p_profile));
end $$;

revoke all on function public.set_main_profile(uuid) from public, anon;
grant execute on function public.set_main_profile(uuid) to authenticated;
