-- Devices (the account's sessions), per profile preferences and account switches. Every statement can be repeated.
-- Design: notes/32-settings-rebuild-plan-2026-10-11.md and 33-settings-gap-list-2026-10-11.md in the project notes.

-- Preferences kept per profile, next to the existing autoplay and language columns ---------------------------------------------
alter table public.profile_settings add column if not exists data_usage text not null default 'auto';
alter table public.profile_settings add column if not exists notifications jsonb not null default '{}'::jsonb;
alter table public.profile_settings add column if not exists blocked_titles jsonb not null default '[]'::jsonb;
alter table public.profile_settings add column if not exists game_handle text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profile_settings_data_usage_check') then
    alter table public.profile_settings add constraint profile_settings_data_usage_check check (data_usage in ('auto', 'low', 'medium', 'high'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profile_settings_game_handle_check') then
    alter table public.profile_settings add constraint profile_settings_game_handle_check check (game_handle is null or game_handle ~ '^[A-Za-z0-9]{3,16}$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profile_settings_blocked_titles_check') then
    alter table public.profile_settings add constraint profile_settings_blocked_titles_check check (jsonb_typeof(blocked_titles) = 'array' and jsonb_array_length(blocked_titles) <= 200);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profile_settings_notifications_check') then
    alter table public.profile_settings add constraint profile_settings_notifications_check check (jsonb_typeof(notifications) = 'object');
  end if;
end $$;
create unique index if not exists profile_settings_game_handle_key on public.profile_settings (lower(game_handle)) where game_handle is not null;

-- Switches of the whole account --------------------------------------------------------------------------------------------------
alter table public.account_details add column if not exists test_participation boolean not null default true;
alter table public.account_details add column if not exists profile_transfer boolean not null default true;

create or replace function public.set_account_switch(p_name text, p_value boolean) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := (select auth.uid());
begin
  if v_user is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_name not in ('test_participation', 'profile_transfer') then
    raise exception 'unknown switch' using errcode = '22023';
  end if;
  insert into public.account_details (user_id) values (v_user) on conflict (user_id) do nothing;
  if p_name = 'test_participation' then
    update public.account_details set test_participation = p_value, updated_at = now() where user_id = v_user;
  else
    update public.account_details set profile_transfer = p_value, updated_at = now() where user_id = v_user;
  end if;
  perform public.log_account_event(v_user, 'switch_' || p_name, jsonb_build_object('value', p_value));
end $$;

-- Devices: the sessions of the signed in account. No address is returned, only the browser line and the times. -----------------
create or replace function public.list_my_sessions()
returns table (id uuid, created_at timestamptz, last_seen timestamptz, user_agent text, is_current boolean)
language sql stable security definer set search_path = auth, public as $$
  select s.id, s.created_at, coalesce(s.refreshed_at, s.updated_at, s.created_at), s.user_agent,
         s.id = nullif(auth.jwt() ->> 'session_id', '')::uuid
    from auth.sessions s
   where s.user_id = (select auth.uid())
   order by coalesce(s.refreshed_at, s.updated_at, s.created_at) desc nulls last
   limit 50
$$;

create or replace function public.revoke_my_session(p_id uuid) returns void
language plpgsql security definer set search_path = auth, public as $$
declare
  v_user uuid := (select auth.uid());
begin
  if v_user is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  perform public.require_recent_sign_in();
  delete from auth.sessions where id = p_id and user_id = v_user;
  perform public.log_account_event(v_user, 'session_revoked', jsonb_build_object('session_id', p_id));
end $$;

revoke all on function public.set_account_switch(text, boolean), public.list_my_sessions(), public.revoke_my_session(uuid) from public, anon;
grant execute on function public.set_account_switch(text, boolean), public.list_my_sessions(), public.revoke_my_session(uuid) to authenticated;

-- the data export includes the new columns through the existing tables; nothing else to change
