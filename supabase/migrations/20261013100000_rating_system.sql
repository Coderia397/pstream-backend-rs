-- Which age rating labels a person reads: the British ones (U, PG, 12, 15, 18) or the American ones (G, PG, PG-13, R, NC-17, TV-...).
-- The account can choose ('uk' or 'us'); the default 'auto' follows the country of the device this session signed in from (the device
-- signature, see account_devices.last_country). The country to system table is data, not code: add a row to change a country.
-- Every statement can be repeated.

create table if not exists public.rating_system_by_country (
  country text primary key check (country ~ '^[A-Z]{2}$'),
  system  text not null check (system in ('uk', 'us'))
);
comment on table public.rating_system_by_country is 'Rating labels by country for accounts on auto. A country not listed gets the british labels.';
insert into public.rating_system_by_country (country, system) values
  ('US', 'us'), ('CA', 'us'), ('MX', 'us'), ('PR', 'us'), ('GU', 'us'), ('VI', 'us'), ('AS', 'us'), ('MP', 'us'),
  ('GB', 'uk'), ('IE', 'uk')
on conflict (country) do nothing;
alter table public.rating_system_by_country enable row level security;
drop policy if exists rating_system_by_country_read on public.rating_system_by_country;
create policy rating_system_by_country_read on public.rating_system_by_country for select to anon, authenticated using (true);
revoke all on public.rating_system_by_country from anon, authenticated;
grant select on public.rating_system_by_country to anon, authenticated;

alter table public.account_details add column if not exists rating_system text not null default 'auto';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'account_details_rating_system_check') then
    alter table public.account_details add constraint account_details_rating_system_check check (rating_system in ('auto', 'uk', 'us'));
  end if;
end $$;

create or replace function public.set_rating_system(p_system text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_system is null or p_system not in ('auto', 'uk', 'us') then
    raise exception 'unknown rating system' using errcode = '22023';
  end if;
  update public.account_details set rating_system = p_system, updated_at = now() where user_id = v_user;
end $$;
revoke all on function public.set_rating_system(text) from public, anon;
grant execute on function public.set_rating_system(text) to authenticated;

-- The system in force for this session: the account's own choice, else the country of the device of this session (else of the device
-- seen last), else british. Returns 'uk' or 'us'.
create or replace function public.my_rating_system()
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_user    uuid := auth.uid();
  v_session uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_choice  text;
  v_country text;
begin
  if v_user is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select rating_system into v_choice from public.account_details where user_id = v_user;
  if v_choice in ('uk', 'us') then
    return v_choice;
  end if;
  select last_country into v_country from public.account_devices
   where user_id = v_user and last_country is not null
   order by (session_id is not distinct from v_session) desc, last_seen desc
   limit 1;
  return coalesce((select system from public.rating_system_by_country where country = v_country), 'uk');
end $$;
revoke all on function public.my_rating_system() from public, anon;
grant execute on function public.my_rating_system() to authenticated;
