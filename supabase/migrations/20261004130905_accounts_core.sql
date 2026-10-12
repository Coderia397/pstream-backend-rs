-- streams accounts, v2 (design: notes/06-accounts-audit-and-design.md, review notes in notes/23-accounts-architecture.md)
-- Account = Supabase auth user. Up to 5 profiles per account. Everything per profile hangs off profiles.id.
--
-- Properties this migration guarantees:
--  * Security: row level security on every table; anonymous users have no privileges; no client callable function can
--    read or change another user's data; PINs are hashed in a table no client can read; trigger functions are not callable.
--  * Multi device sync: every synced row carries the client's own timestamp; an older write never overwrites a newer
--    one (last write wins, decided in the database, so retries and out of order outboxes are safe); a batch push and an
--    incremental pull each take one round trip; server time cursors never go backwards.
--  * Audit: security relevant account events are logged and readable by the owner.
--  * PIN: one attempt counter and one lock shared by verify, set and clear (guessing through set or clear is not possible).
--  * Hygiene: retention job for event tables, everything rebuilds from this file.

create extension if not exists pgcrypto with schema extensions;

-- profiles ----------------------------------------------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 30),
  avatar      text not null default 'default' check (char_length(avatar) <= 64),
  kind        text not null default 'adult' check (kind in ('adult', 'kids')),
  maturity    text not null default 'adult' check (maturity in ('little_kids', 'older_kids', 'teens', 'adult')),
  has_pin     boolean not null default false,
  sort_order  smallint not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint profiles_kids_maturity check (kind <> 'kids' or maturity in ('little_kids', 'older_kids'))
);
create unique index profiles_user_name_key on public.profiles (user_id, lower(btrim(name)));
comment on table public.profiles is 'Netflix style profiles: up to 5 per account, optional kids maturity, optional hashed PIN (profile_pins).';

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end $$;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

create or replace function public.enforce_profile_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- two parallel inserts for one account must not both pass the count
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));
  if (select count(*) from public.profiles where user_id = new.user_id) >= 5 then
    raise exception 'profile limit reached' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger profiles_limit before insert on public.profiles
  for each row execute function public.enforce_profile_limit();

-- the last profile of a live account cannot be deleted (deleting the account itself still cascades)
create or replace function public.keep_last_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from auth.users u where u.id = old.user_id)
     and (select count(*) from public.profiles where user_id = old.user_id) <= 1 then
    raise exception 'an account needs at least one profile' using errcode = 'P0001';
  end if;
  return old;
end $$;
create trigger profiles_keep_last before delete on public.profiles
  for each row execute function public.keep_last_profile();

-- PIN hashes live apart from profiles; RLS is on and no policy exists, so only the functions below can touch them
create table public.profile_pins (
  profile_id       uuid primary key references public.profiles (id) on delete cascade,
  pin_hash         text not null,
  failed_attempts  smallint not null default 0,
  locked_until     timestamptz,
  updated_at       timestamptz not null default now()
);

-- audit log ---------------------------------------------------------------------------------------------------------
create table public.account_events (
  id       bigint generated always as identity primary key,
  user_id  uuid not null references auth.users (id) on delete cascade,
  ts       timestamptz not null default now(),
  event    text not null,
  meta     jsonb not null default '{}'::jsonb
);
create index account_events_user_ts_idx on public.account_events (user_id, ts desc);
comment on table public.account_events is 'Security relevant events (profile created or deleted, PIN set, cleared or locked). Written by functions only.';

create or replace function public.log_account_event(p_user uuid, p_event text, p_meta jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from auth.users u where u.id = p_user) then
    insert into public.account_events (user_id, event, meta) values (p_user, p_event, coalesce(p_meta, '{}'::jsonb));
  end if;
end $$;

create or replace function public.audit_profiles()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform public.log_account_event(new.user_id, 'profile_created', jsonb_build_object('profile_id', new.id, 'kind', new.kind));
    return new;
  end if;
  perform public.log_account_event(old.user_id, 'profile_deleted', jsonb_build_object('profile_id', old.id));
  return old;
end $$;
create trigger profiles_audit after insert or delete on public.profiles
  for each row execute function public.audit_profiles();

-- per profile data (multi device sync) ------------------------------------------------------------------------------
-- client_updated_at is the device's own clock (clamped to 5 minutes ahead of the server); updated_at is the server's
-- clock and is the pull cursor. A write with an older client_updated_at than the stored row is ignored.
create or replace function public.sync_row_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.client_updated_at := least(new.client_updated_at, now() + interval '5 minutes');
  if tg_op = 'UPDATE' and new.client_updated_at < old.client_updated_at then
    return null;
  end if;
  new.updated_at := clock_timestamp();
  return new;
end $$;

create table public.profile_titles (
  profile_id         uuid not null references public.profiles (id) on delete cascade,
  media_type         text not null check (media_type in ('movie', 'tv')),
  tmdb_id            integer not null check (tmdb_id > 0),
  in_list            boolean not null default false,
  rating             text check (rating in ('down', 'up', 'love')),
  added_at           timestamptz,
  client_updated_at  timestamptz not null default now(),
  updated_at         timestamptz not null default clock_timestamp(),
  primary key (profile_id, media_type, tmdb_id)
);
create index profile_titles_list_idx on public.profile_titles (profile_id, added_at desc) where in_list;
create index profile_titles_pull_idx on public.profile_titles (profile_id, updated_at);
create trigger profile_titles_guard before insert or update on public.profile_titles
  for each row execute function public.sync_row_guard();
comment on table public.profile_titles is 'My List and ratings, one row per profile and title. Removal is in_list = false so other devices learn about it.';

create table public.watch_progress (
  profile_id         uuid not null references public.profiles (id) on delete cascade,
  media_type         text not null check (media_type in ('movie', 'tv')),
  tmdb_id            integer not null check (tmdb_id > 0),
  season             smallint not null default 0 check (season >= 0),
  episode            smallint not null default 0 check (episode >= 0),
  position_seconds   integer not null default 0 check (position_seconds >= 0),
  duration_seconds   integer not null default 0 check (duration_seconds >= 0),
  completed          boolean not null default false,
  hidden             boolean not null default false,
  client_updated_at  timestamptz not null default now(),
  updated_at         timestamptz not null default clock_timestamp(),
  primary key (profile_id, media_type, tmdb_id, season, episode)
);
create index watch_progress_recent_idx on public.watch_progress (profile_id, client_updated_at desc);
create index watch_progress_pull_idx on public.watch_progress (profile_id, updated_at);
create trigger watch_progress_guard before insert or update on public.watch_progress
  for each row execute function public.sync_row_guard();
comment on table public.watch_progress is 'Continue Watching and viewing activity. hidden = removed from the viewing activity list.';

create table public.profile_settings (
  profile_id         uuid primary key references public.profiles (id) on delete cascade,
  autoplay_next      boolean not null default true,
  autoplay_previews  boolean not null default true,
  audio_language     text,
  subtitle_language  text,
  subtitle_style     jsonb not null default '{}'::jsonb,
  ui_language        text,
  client_updated_at  timestamptz not null default now(),
  updated_at         timestamptz not null default clock_timestamp()
);
create trigger profile_settings_guard before insert or update on public.profile_settings
  for each row execute function public.sync_row_guard();

create table public.profile_taste (
  profile_id     uuid primary key references public.profiles (id) on delete cascade,
  genre_weights  jsonb not null default '{}'::jsonb,
  taste_version  integer not null default 0,
  updated_at     timestamptz not null default clock_timestamp()
);
create trigger profile_taste_touch before update on public.profile_taste
  for each row execute function public.touch_updated_at();

create table public.feed_events (
  id          bigint generated always as identity primary key,
  profile_id  uuid not null references public.profiles (id) on delete cascade,
  ts          timestamptz not null default now(),
  event       text not null check (event in ('impression', 'click', 'start', 'complete', 'like', 'skip', 'add_list', 'remove_list')),
  media_type  text check (media_type in ('movie', 'tv')),
  tmdb_id     integer,
  row_title   text,
  position    smallint
);
create index feed_events_profile_ts_idx on public.feed_events (profile_id, ts desc);

create or replace function public.create_profile_defaults()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profile_settings (profile_id) values (new.id) on conflict do nothing;
  return new;
end $$;
create trigger profiles_defaults after insert on public.profiles
  for each row execute function public.create_profile_defaults();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (user_id, name)
  values (
    new.id,
    left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
                  nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'Me'), 30)
  );
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- sync API: one round trip each way; both run with the caller's rights, so row level security decides what is visible ---
create or replace function public.sync_push(p_profile uuid, p_titles jsonb default '[]'::jsonb, p_progress jsonb default '[]'::jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  n_titles   integer := 0;
  n_progress integer := 0;
begin
  if jsonb_array_length(p_titles) > 500 or jsonb_array_length(p_progress) > 500 then
    raise exception 'batch too large' using errcode = '54000';
  end if;

  insert into public.profile_titles (profile_id, media_type, tmdb_id, in_list, rating, added_at, client_updated_at)
  select p_profile, r.media_type, r.tmdb_id, coalesce(r.in_list, false), r.rating, r.added_at, coalesce(r.client_updated_at, now())
  from jsonb_to_recordset(p_titles) as r(media_type text, tmdb_id integer, in_list boolean, rating text, added_at timestamptz, client_updated_at timestamptz)
  on conflict (profile_id, media_type, tmdb_id) do update
    set in_list = excluded.in_list, rating = excluded.rating, added_at = excluded.added_at,
        client_updated_at = excluded.client_updated_at;
  get diagnostics n_titles = row_count;

  insert into public.watch_progress (profile_id, media_type, tmdb_id, season, episode, position_seconds, duration_seconds, completed, hidden, client_updated_at)
  select p_profile, r.media_type, r.tmdb_id, coalesce(r.season, 0), coalesce(r.episode, 0), coalesce(r.position_seconds, 0),
         coalesce(r.duration_seconds, 0), coalesce(r.completed, false), coalesce(r.hidden, false), coalesce(r.client_updated_at, now())
  from jsonb_to_recordset(p_progress) as r(media_type text, tmdb_id integer, season smallint, episode smallint, position_seconds integer,
                                           duration_seconds integer, completed boolean, hidden boolean, client_updated_at timestamptz)
  on conflict (profile_id, media_type, tmdb_id, season, episode) do update
    set position_seconds = excluded.position_seconds, duration_seconds = excluded.duration_seconds,
        completed = excluded.completed, hidden = excluded.hidden, client_updated_at = excluded.client_updated_at;
  get diagnostics n_progress = row_count;

  return jsonb_build_object('titles', n_titles, 'progress', n_progress, 'server_time', clock_timestamp());
end $$;

-- changes since a cursor (use the returned cursor next time); has_more means pull again
create or replace function public.sync_pull(p_profile uuid, p_since timestamptz default 'epoch')
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  v_titles    jsonb;
  v_progress  jsonb;
  v_settings  jsonb;
  -- the cursor trails the clock by 5 seconds: a row written by a slower, still open transaction gets an older updated_at
  -- than rows already pulled, and would be skipped forever otherwise. Repeats are harmless, clients merge by client_updated_at.
  v_cursor    timestamptz := clock_timestamp() - interval '5 seconds';
  v_t_n       integer;
  v_p_n       integer;
  v_t_max     timestamptz;
  v_p_max     timestamptz;
  v_limit     constant integer := 2000;
begin
  select coalesce(jsonb_agg(to_jsonb(t) - 'profile_id' order by t.updated_at), '[]'::jsonb), count(*), max(t.updated_at)
    into v_titles, v_t_n, v_t_max
    from (select * from public.profile_titles where profile_id = p_profile and updated_at > p_since order by updated_at limit v_limit) t;
  select coalesce(jsonb_agg(to_jsonb(w) - 'profile_id' order by w.updated_at), '[]'::jsonb), count(*), max(w.updated_at)
    into v_progress, v_p_n, v_p_max
    from (select * from public.watch_progress where profile_id = p_profile and updated_at > p_since order by updated_at limit v_limit) w;
  select to_jsonb(s) - 'profile_id' into v_settings
    from public.profile_settings s where s.profile_id = p_profile and s.updated_at > p_since;
  if v_t_n >= v_limit then v_cursor := least(v_cursor, v_t_max); end if;
  if v_p_n >= v_limit then v_cursor := least(v_cursor, v_p_max); end if;
  v_cursor := greatest(v_cursor, p_since);
  return jsonb_build_object('cursor', v_cursor, 'has_more', (v_t_n >= v_limit or v_p_n >= v_limit),
                            'titles', v_titles, 'progress', v_progress, 'settings', v_settings);
end $$;

-- PIN functions (the only way to read or write a PIN) -------------------------------------------------------------------
-- Every comparison of a PIN goes through pin_attempt, so verifying, changing and clearing share one attempt counter and one
-- lock (5 wrong tries lock the profile for 15 minutes). Without that, set or clear could be used to guess the PIN.
-- The row is locked while counting, so parallel guesses cannot all read the same counter. A wrong PIN returns false instead
-- of raising, because an exception would roll back the counter update.
create or replace function public.pin_attempt(p_profile uuid, p_pin text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_owner  uuid;
  v_row    public.profile_pins%rowtype;
  v_failed smallint;
begin
  select user_id into v_owner from public.profiles where id = p_profile;
  if v_owner is null or v_owner is distinct from (select auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v_row from public.profile_pins where profile_id = p_profile for update;
  if not found then
    return true;
  end if;
  if v_row.locked_until is not null and v_row.locked_until > now() then
    raise exception 'too many attempts, try again later' using errcode = '55000';
  end if;
  if p_pin is not null and extensions.crypt(p_pin, v_row.pin_hash) = v_row.pin_hash then
    update public.profile_pins set failed_attempts = 0, locked_until = null where profile_id = p_profile;
    return true;
  end if;
  v_failed := v_row.failed_attempts + 1;
  if v_failed >= 5 then
    update public.profile_pins set failed_attempts = 0, locked_until = now() + interval '15 minutes' where profile_id = p_profile;
    perform public.log_account_event(v_owner, 'pin_locked', jsonb_build_object('profile_id', p_profile));
  else
    update public.profile_pins set failed_attempts = v_failed where profile_id = p_profile;
  end if;
  return false;
end $$;

-- true when the PIN matches or none is set
create or replace function public.verify_profile_pin(p_profile uuid, p_pin text)
returns boolean language sql security definer set search_path = '' as $$
  select public.pin_attempt(p_profile, p_pin);
$$;

-- true when the PIN was set; false when the current PIN was wrong (counted); raises when the current PIN is missing or the profile is locked
create or replace function public.set_profile_pin(p_profile uuid, p_pin text, p_current text default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid;
  v_has   boolean;
begin
  select user_id into v_owner from public.profiles where id = p_profile;
  if v_owner is null or v_owner is distinct from (select auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'the PIN is 4 digits' using errcode = '22023';
  end if;
  select exists (select 1 from public.profile_pins where profile_id = p_profile) into v_has;
  if v_has then
    if p_current is null then
      raise exception 'the current PIN is required' using errcode = '28000';
    end if;
    if not public.pin_attempt(p_profile, p_current) then
      return false;
    end if;
  end if;
  insert into public.profile_pins (profile_id, pin_hash)
  values (p_profile, extensions.crypt(p_pin, extensions.gen_salt('bf', 10)))
  on conflict (profile_id) do update
    set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null, updated_at = now();
  update public.profiles set has_pin = true where id = p_profile;
  perform public.log_account_event(v_owner, 'pin_set', jsonb_build_object('profile_id', p_profile));
  return true;
end $$;

-- true when cleared (or none was set); false when the current PIN was wrong (counted)
create or replace function public.clear_profile_pin(p_profile uuid, p_current text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid;
  v_has   boolean;
begin
  select user_id into v_owner from public.profiles where id = p_profile;
  if v_owner is null or v_owner is distinct from (select auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select exists (select 1 from public.profile_pins where profile_id = p_profile) into v_has;
  if not v_has then
    return true;
  end if;
  if p_current is null then
    raise exception 'the current PIN is required' using errcode = '28000';
  end if;
  if not public.pin_attempt(p_profile, p_current) then
    return false;
  end if;
  delete from public.profile_pins where profile_id = p_profile;
  update public.profiles set has_pin = false where id = p_profile;
  perform public.log_account_event(v_owner, 'pin_cleared', jsonb_build_object('profile_id', p_profile));
  return true;
end $$;

create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  delete from auth.users where id = (select auth.uid());
end $$;

-- row level security ------------------------------------------------------------------------------------------------------
alter table public.profiles         enable row level security;
alter table public.profile_pins     enable row level security;
alter table public.account_events   enable row level security;
alter table public.profile_titles   enable row level security;
alter table public.watch_progress   enable row level security;
alter table public.profile_settings enable row level security;
alter table public.profile_taste    enable row level security;
alter table public.feed_events      enable row level security;

create policy profiles_owner on public.profiles for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy account_events_owner on public.account_events for select to authenticated
  using (user_id = (select auth.uid()));

create policy owner_all on public.profile_titles for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = profile_titles.profile_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from public.profiles p where p.id = profile_titles.profile_id and p.user_id = (select auth.uid())));
create policy owner_all on public.watch_progress for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = watch_progress.profile_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from public.profiles p where p.id = watch_progress.profile_id and p.user_id = (select auth.uid())));
create policy owner_all on public.profile_settings for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = profile_settings.profile_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from public.profiles p where p.id = profile_settings.profile_id and p.user_id = (select auth.uid())));
create policy owner_all on public.profile_taste for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = profile_taste.profile_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from public.profiles p where p.id = profile_taste.profile_id and p.user_id = (select auth.uid())));
create policy owner_select on public.feed_events for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = feed_events.profile_id and p.user_id = (select auth.uid())));
create policy owner_insert on public.feed_events for insert to authenticated
  with check (exists (select 1 from public.profiles p where p.id = feed_events.profile_id and p.user_id = (select auth.uid())));

-- privileges ----------------------------------------------------------------------------------------------------------------
revoke all on public.profiles, public.profile_pins, public.account_events, public.profile_titles, public.watch_progress,
              public.profile_settings, public.profile_taste, public.feed_events from anon, authenticated;
grant select, delete on public.profiles to authenticated;
grant insert (user_id, name, avatar, kind, maturity, sort_order) on public.profiles to authenticated;
grant update (name, avatar, kind, maturity, sort_order) on public.profiles to authenticated;
grant select on public.account_events to authenticated;
grant select, insert, update, delete on public.profile_titles, public.watch_progress,
                                        public.profile_settings, public.profile_taste to authenticated;
grant select, insert on public.feed_events to authenticated;

revoke all on function public.touch_updated_at(), public.sync_row_guard(), public.enforce_profile_limit(), public.keep_last_profile(),
                       public.log_account_event(uuid, text, jsonb), public.audit_profiles(), public.create_profile_defaults(),
                       public.handle_new_user(), public.pin_attempt(uuid, text) from public, anon, authenticated;
revoke all on function public.sync_push(uuid, jsonb, jsonb), public.sync_pull(uuid, timestamptz),
                       public.set_profile_pin(uuid, text, text), public.clear_profile_pin(uuid, text),
                       public.verify_profile_pin(uuid, text), public.delete_my_account() from public, anon;
grant execute on function public.sync_push(uuid, jsonb, jsonb), public.sync_pull(uuid, timestamptz),
                          public.set_profile_pin(uuid, text, text), public.clear_profile_pin(uuid, text),
                          public.verify_profile_pin(uuid, text), public.delete_my_account() to authenticated;

alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on functions from anon;

-- realtime for live multi device updates (rows still pass row level security) and retention of event tables --------------------
do $$
begin
  alter publication supabase_realtime add table public.profile_titles, public.watch_progress, public.profile_settings;
exception when others then
  raise notice 'realtime publication not updated: %', sqlerrm;
end $$;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('prune-feed-events', '17 3 * * *', $job$delete from public.feed_events where ts < now() - interval '180 days'$job$);
  perform cron.schedule('prune-account-events', '23 3 * * *', $job$delete from public.account_events where ts < now() - interval '365 days'$job$);
exception when others then
  raise notice 'retention jobs not scheduled: %', sqlerrm;
end $$;
