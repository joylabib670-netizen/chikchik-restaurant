-- ChikChik account/content hardening and merchandising upgrade.
-- Run in the existing Supabase project only.

create or replace function public.normalize_bd_phone(p_phone text)
returns text language plpgsql immutable as $$
declare v text := regexp_replace(coalesce(p_phone,''),'[^0-9+]','','g');
begin
  v := replace(v,'+','');
  if v like '8801%' then v := substring(v from 3); end if;
  if v like '008801%' then v := substring(v from 5); end if;
  if v like '01%' then return v; end if;
  return v;
end $$;
grant execute on function public.normalize_bd_phone(text) to anon,authenticated;

alter table public.profiles add column if not exists phone_normalized text;
update public.profiles set phone_normalized=public.normalize_bd_phone(phone) where phone_normalized is null or phone_normalized='';
create unique index if not exists profiles_phone_normalized_uidx on public.profiles(phone_normalized);

create or replace function public.profiles_normalize_phone() returns trigger language plpgsql security definer set search_path=public as $$
begin
  new.phone := regexp_replace(trim(new.phone),'\\s+','','g');
  new.phone_normalized := public.normalize_bd_phone(new.phone);
  return new;
end $$;
drop trigger if exists profiles_normalize_phone on public.profiles;
create trigger profiles_normalize_phone before insert or update of phone on public.profiles for each row execute function public.profiles_normalize_phone();

create or replace function public.is_phone_available(p_phone text) returns boolean language sql security definer set search_path=public as $$
  select not exists(select 1 from public.profiles where phone_normalized=public.normalize_bd_phone(p_phone));
$$;

create or replace function public.claim_guest_orders() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from auth.users u where u.id=new.id and u.confirmed_at is not null) then
    update public.orders set user_id=new.id
    where user_id is null and ((email is not null and lower(email)=lower(new.email)) or public.normalize_bd_phone(phone)=new.phone_normalized);
  end if;
  return new;
end $$;

create or replace function public.claim_guest_orders_for_user()
returns integer language plpgsql security definer set search_path=public as $$
declare n integer;
begin
  if auth.uid() is null or not exists(select 1 from auth.users u where u.id=auth.uid() and u.confirmed_at is not null) then return 0; end if;
  update public.orders o set user_id=p.id
  from public.profiles p
  where p.id=auth.uid() and o.user_id is null
    and ((o.email is not null and lower(o.email)=lower(p.email)) or public.normalize_bd_phone(o.phone)=p.phone_normalized);
  get diagnostics n=row_count;
  return n;
end $$;
grant execute on function public.claim_guest_orders_for_user() to authenticated;

-- Product merchandising fields used by the collection and offer editor.
alter table public.menu_items add column if not exists popularity_score integer not null default 0;
alter table public.offers add column if not exists discount_percent numeric(5,2);
alter table public.offers add column if not exists offer_image_url text;

-- Create profiles from signup metadata even when email confirmation is enabled.
create or replace function public.handle_new_user_profile() returns trigger language plpgsql security definer set search_path=public as $$
declare m jsonb := coalesce(new.raw_user_meta_data,'{}'::jsonb); v_phone text := coalesce(m->>'phone','');
begin
  if length(v_phone)>0 and length(coalesce(m->>'full_name',''))>0 and length(coalesce(m->>'username',''))>0 and length(coalesce(m->>'upazila',''))>0 and length(coalesce(m->>'street_address',''))>0 then
    insert into public.profiles(id,email,phone,full_name,username,division,district,upazila,union_name,street_address)
    values(new.id,lower(new.email),v_phone,m->>'full_name',m->>'username','Dhaka','Dhaka',m->>'upazila',nullif(m->>'union_name',''),m->>'street_address')
    on conflict(id) do update set email=excluded.email,phone=excluded.phone,full_name=excluded.full_name,username=excluded.username,upazila=excluded.upazila,union_name=excluded.union_name,street_address=excluded.street_address;
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile after insert on auth.users for each row execute function public.handle_new_user_profile();

-- Authenticated users may upload only under their own media folders; admins may use admin/.
drop policy if exists "authenticated upload chikchik media" on storage.objects;
create policy "authenticated upload chikchik media" on storage.objects for insert to authenticated
with check (
  bucket_id='chikchik-media' and
  (name like 'user-posts/' || auth.uid()::text || '/%' or name like 'user-stories/' || auth.uid()::text || '/%' or (name like 'admin/%' and public.is_admin()))
);

-- Realtime product/customer content updates.
alter publication supabase_realtime add table public.menu_items;
alter publication supabase_realtime add table public.offers;
alter publication supabase_realtime add table public.product_reviews;
