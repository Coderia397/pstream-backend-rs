-- Device signature: each browser that signs in is recognised by an id it keeps for itself plus what it says about itself (browser,
-- system, kind of device, language, time zone, screen size) and the country it connects from. The address of the connection is
-- never stored. Every statement can be repeated.
--
-- Rules for a VPN or travel: a device is the same device when it presents the same id, wherever it connects from. A different
-- country only adds to the countries seen for that device and writes a quiet log entry (device_new_country). Only an id that
-- has not been seen before is a new device (log entry new_device), and the app can tell the owner about it.

create table if not exists public.account_devices (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  device_key     text not null check (char_length(device_key) between 16 and 64),
  browser        text check (char_length(browser) <= 60),
  browser_major  integer,
  os             text check (char_length(os) <= 60),
  device_type    text not null default 'other' check (device_type in ('desktop', 'mobile', 'tablet', 'tv', 'other')),
  language       text check (char_length(language) <= 20),
  timezone       text check (char_length(timezone) <= 60),
  screen         text check (char_length(screen) <= 20),
  user_agent     text check (char_length(user_agent) <= 400),
  last_country   text check (last_country ~ '^[A-Z]{2}$'),
  countries      text[] not null default '{}',
  session_id     uuid,
  first_seen     timestamptz not null default now(),
  last_seen      timestamptz not null default now(),
  unique (user_id, device_key)
);
create index if not exists account_devices_user_idx on public.account_devices (user_id, last_seen desc);
comment on table public.account_devices is 'Browsers and devices that signed in to an account. Written only by register_device; the connection address is not kept.';
alter table public.account_devices enable row level security;
drop policy if exists account_devices_owner_select on public.account_devices;
create policy account_devices_owner_select on public.account_devices for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.account_devices from anon, authenticated;
grant select on public.account_devices to authenticated;

-- Called by the app after every sign in and when it starts signed in. p_info holds: browser, browser_major, os, device_type,
-- language, timezone, screen, user_agent, country (two capital letters, from the edge, may be missing).
create or replace function public.register_device(p_device_key text, p_info jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user     uuid := (select auth.uid());
  v_session  uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_country  text := upper(nullif(left(coalesce(p_info ->> 'country', ''), 8), ''));
  v_type     text := coalesce(nullif(p_info ->> 'device_type', ''), 'other');
  v_row      public.account_devices%rowtype;
  v_new      boolean := false;
  v_new_country boolean := false;
begin
  if v_user is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_device_key is null or char_length(p_device_key) not between 16 and 64 then
    raise exception 'invalid device key' using errcode = '22023';
  end if;
  if v_country is not null and v_country !~ '^[A-Z]{2}$' then v_country := null; end if;
  if v_type not in ('desktop', 'mobile', 'tablet', 'tv', 'other') then v_type := 'other'; end if;

  select * into v_row from public.account_devices where user_id = v_user and device_key = p_device_key;
  if not found then
    v_new := true;
    insert into public.account_devices (user_id, device_key, browser, browser_major, os, device_type, language, timezone, screen, user_agent, last_country, countries, session_id)
    values (v_user, p_device_key, left(p_info ->> 'browser', 60), nullif(p_info ->> 'browser_major', '')::integer, left(p_info ->> 'os', 60), v_type,
            left(p_info ->> 'language', 20), left(p_info ->> 'timezone', 60), left(p_info ->> 'screen', 20), left(p_info ->> 'user_agent', 400),
            v_country, case when v_country is null then '{}'::text[] else array[v_country] end, v_session)
    returning * into v_row;
    perform public.log_account_event(v_user, 'new_device', jsonb_build_object('device', v_row.id, 'browser', v_row.browser, 'os', v_row.os, 'country', v_country));
  else
    v_new_country := v_country is not null and not (v_country = any (v_row.countries));
    update public.account_devices
       set browser = coalesce(left(p_info ->> 'browser', 60), browser), browser_major = coalesce(nullif(p_info ->> 'browser_major', '')::integer, browser_major),
           os = coalesce(left(p_info ->> 'os', 60), os), device_type = case when v_type = 'other' then device_type else v_type end,
           language = coalesce(left(p_info ->> 'language', 20), language), timezone = coalesce(left(p_info ->> 'timezone', 60), timezone),
           screen = coalesce(left(p_info ->> 'screen', 20), screen), user_agent = coalesce(left(p_info ->> 'user_agent', 400), user_agent),
           last_country = coalesce(v_country, last_country),
           countries = case when v_new_country then array_append(countries, v_country) else countries end,
           session_id = coalesce(v_session, session_id), last_seen = now()
     where id = v_row.id returning * into v_row;
    if v_new_country then
      perform public.log_account_event(v_user, 'device_new_country', jsonb_build_object('device', v_row.id, 'country', v_country));
    end if;
  end if;
  return jsonb_build_object('device_id', v_row.id, 'is_new', v_new, 'new_country', v_new_country, 'countries', v_row.countries);
end $$;

-- The device list: every session of the account with what is known about the browser that made it. A session with no device
-- row (it signed in before this existed) is still listed, with the browser text Supabase recorded.
drop function if exists public.list_my_sessions();
create or replace function public.list_my_sessions()
returns table (id uuid, created_at timestamptz, last_seen timestamptz, user_agent text, is_current boolean,
               device_id uuid, browser text, browser_major integer, os text, device_type text, language text, timezone text, screen text,
               country text, countries text[], device_first_seen timestamptz)
language sql stable security definer set search_path = auth, public as $$
  select s.id, s.created_at, coalesce(s.refreshed_at, s.updated_at, s.created_at), coalesce(d.user_agent, s.user_agent),
         s.id = nullif(auth.jwt() ->> 'session_id', '')::uuid,
         d.id, d.browser, d.browser_major, d.os, d.device_type, d.language, d.timezone, d.screen, d.last_country, d.countries, d.first_seen
    from auth.sessions s
    left join public.account_devices d on d.user_id = s.user_id and d.session_id = s.id
   where s.user_id = (select auth.uid())
   order by coalesce(s.refreshed_at, s.updated_at, s.created_at) desc nulls last
   limit 50
$$;

revoke all on function public.register_device(text, jsonb), public.list_my_sessions() from public, anon;
grant execute on function public.register_device(text, jsonb), public.list_my_sessions() to authenticated;
