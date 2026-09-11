create extension if not exists pgcrypto;

-- ChikChik production schema: safe to run on the existing project.
alter table if exists public.orders drop constraint if exists orders_status_check;
alter table if exists public.orders add constraint orders_status_check check (status in ('pending','confirmed','preparing','packaging','ready','out_for_delivery','delivered','cancelled'));

create table if not exists public.menu_items(
  id uuid primary key default gen_random_uuid(), name text not null, description text, category text not null,
  price integer not null check(price >= 0), image_url text, available boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.orders(
  id uuid primary key default gen_random_uuid(), order_code text unique not null, name text not null, phone text not null,
  division text not null default 'Dhaka', district text not null check(district='Dhaka'), upazila text not null default '', union_name text,
  area text not null default '', address text not null, items jsonb not null, subtotal integer not null default 0, delivery_charge integer not null default 0,
  total integer not null, status text not null default 'pending', created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.orders add column if not exists division text not null default 'Dhaka';
alter table public.orders add column if not exists upazila text not null default '';
alter table public.orders add column if not exists union_name text;
alter table public.orders add column if not exists subtotal integer not null default 0;
alter table public.orders add column if not exists delivery_charge integer not null default 0;
alter table public.orders add column if not exists updated_at timestamptz not null default now();

create table if not exists public.admin_profiles(id uuid primary key references auth.users(id) on delete cascade,email text unique not null,created_at timestamptz not null default now());
create table if not exists public.offers(
  id uuid primary key default gen_random_uuid(), title text not null, highlight text not null, details text not null, terms text,
  valid_until date, active boolean not null default false, menu_item_ids uuid[] not null default '{}', created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.social_profiles(
  id uuid primary key default gen_random_uuid(), platform text unique not null check(platform in ('facebook','instagram')),
  handle text not null, display_name text not null, profile_image_url text, cover_image_url text, followers text, following text,
  bio text, profile_url text not null, updated_at timestamptz not null default now()
);
create table if not exists public.social_posts(
  id uuid primary key default gen_random_uuid(), platform text not null check(platform in ('facebook','instagram')), image_url text not null,
  caption text, post_url text, published_at date, sort_order integer not null default 0, active boolean not null default true
);
create table if not exists public.reviews(
  id uuid primary key default gen_random_uuid(), source text not null default 'Google Maps', author text not null, rating integer not null check(rating between 1 and 5),
  review_text text not null, review_url text, published_at date, featured boolean not null default false, last_synced_at timestamptz not null default now()
);
create table if not exists public.site_settings(key text primary key,value jsonb not null,updated_at timestamptz not null default now());

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$ begin new.updated_at=now(); return new; end $$;
drop trigger if exists orders_touch_updated_at on public.orders;
create trigger orders_touch_updated_at before update on public.orders for each row execute function public.touch_updated_at();
drop trigger if exists offers_touch_updated_at on public.offers;
create trigger offers_touch_updated_at before update on public.offers for each row execute function public.touch_updated_at();

alter table public.menu_items enable row level security; alter table public.orders enable row level security; alter table public.admin_profiles enable row level security;
alter table public.offers enable row level security; alter table public.social_profiles enable row level security; alter table public.social_posts enable row level security; alter table public.reviews enable row level security; alter table public.site_settings enable row level security;

drop policy if exists "public can view available menu" on public.menu_items;
drop policy if exists "public can create orders" on public.orders;
drop policy if exists "customers can view by code" on public.orders;
drop policy if exists "admins manage menu" on public.menu_items;
drop policy if exists "admins manage orders" on public.orders;
drop policy if exists "admins manage offers" on public.offers;
drop policy if exists "public read content" on public.social_profiles;
drop policy if exists "public read posts" on public.social_posts;
drop policy if exists "public read reviews" on public.reviews;
drop policy if exists "public read settings" on public.site_settings;
drop policy if exists "admins manage reviews" on public.reviews;
drop policy if exists "admins manage social profiles" on public.social_profiles;
drop policy if exists "admins manage social posts" on public.social_posts;
drop policy if exists "admins manage settings" on public.site_settings;

create policy "public can view available menu" on public.menu_items for select using (available=true);
create policy "public can create orders" on public.orders for insert with check (district='Dhaka' and division='Dhaka');
create policy "admins read orders" on public.orders for select using (exists(select 1 from public.admin_profiles p where p.id=auth.uid()));
create policy "admins update orders" on public.orders for update using (exists(select 1 from public.admin_profiles p where p.id=auth.uid()));
create policy "admins manage menu" on public.menu_items for all using (exists(select 1 from public.admin_profiles p where p.id=auth.uid()));
create policy "public read active offers" on public.offers for select using (active=true);
create policy "admins manage offers" on public.offers for all using (exists(select 1 from public.admin_profiles p where p.id=auth.uid()));
create policy "public read content" on public.social_profiles for select using (true);
create policy "public read posts" on public.social_posts for select using (active=true);
create policy "public read reviews" on public.reviews for select using (true);
create policy "public read settings" on public.site_settings for select using (true);
create policy "admins manage reviews" on public.reviews for all using (exists(select 1 from public.admin_profiles p where p.id=auth.uid())) with check (exists(select 1 from public.admin_profiles p where p.id=auth.uid()));
create policy "admins manage social profiles" on public.social_profiles for all using (exists(select 1 from public.admin_profiles p where p.id=auth.uid())) with check (exists(select 1 from public.admin_profiles p where p.id=auth.uid()));
create policy "admins manage social posts" on public.social_posts for all using (exists(select 1 from public.admin_profiles p where p.id=auth.uid())) with check (exists(select 1 from public.admin_profiles p where p.id=auth.uid()));
create policy "admins manage settings" on public.site_settings for all using (exists(select 1 from public.admin_profiles p where p.id=auth.uid())) with check (exists(select 1 from public.admin_profiles p where p.id=auth.uid()));

create or replace function public.get_order_by_code(p_code text)
returns table(order_code text,name text,items jsonb,subtotal integer,delivery_charge integer,total integer,status text,created_at timestamptz,updated_at timestamptz)
language sql security definer set search_path=public as $$
  select o.order_code,o.name,o.items,o.subtotal,o.delivery_charge,o.total,o.status,o.created_at,o.updated_at
  from public.orders o where upper(o.order_code)=upper(trim(p_code)) limit 1;
$$;
grant execute on function public.get_order_by_code(text) to anon,authenticated;

-- Publicly verified information collected from the linked Instagram, Facebook and Google Maps listings.
insert into public.site_settings(key,value) values
('brand','{"name":"ChikChik","tagline":"First Chicken Finger Restaurant in Bangladesh","description":"Never frozen. Always fresh.","address":"42, Garib-E-Newaz Avenue, Sector 13, Uttara, Dhaka 1230","hours":"Open 11:00 AM – 11:00 PM","phone":""}'::jsonb),
('delivery','{"division":"Dhaka","district":"Dhaka","charge":60,"note":"Delivery is currently available within Dhaka district only."}'::jsonb)
on conflict(key) do update set value=excluded.value,updated_at=now();

insert into public.social_profiles(platform,handle,display_name,profile_image_url,cover_image_url,followers,following,bio,profile_url) values
('instagram','@eatchikchik','ChikChik','logo.jpg','facebook-cover.jpg','2,547','1','First Chicken Finger Restaurant in 🇧🇩 · Never Frozen. Always Fresh. · 42, Garib-E-Nawaz Avenue, Sector 13, Uttara','https://www.instagram.com/eatchikchik/'),
('facebook','ChikChik','ChikChik | Dhaka','logo.jpg','facebook-cover.jpg','103K likes · 55.5K talking about this','1','First Chicken Finger Restaurant in 🇧🇩 · Open 11–11 PM 😋','https://www.facebook.com/ChikChik-61591125944196/')
on conflict(platform) do update set handle=excluded.handle,display_name=excluded.display_name,profile_image_url=excluded.profile_image_url,cover_image_url=excluded.cover_image_url,followers=excluded.followers,following=excluded.following,bio=excluded.bio,profile_url=excluded.profile_url,updated_at=now();

insert into public.menu_items(name,description,category,price,image_url,available) values
('Hotchik Combo','1 Hotchik sandwich with crispy chicken fingers, lettuce, pickles, cheese, Chik Sauce, fries and a 250ml soft drink.','Combos',448,'finger.jpg',true),
('Four Finger Combo','4 chicken fingers, fries, Chik Sauce, butter toast, coleslaw and a 250ml soft drink.','Combos',498,'four-feast.jpg',true),
('Chikster Combo','6 chicken fingers, fries, 2 Chik Sauces, butter toast, coleslaw and a 500ml soft drink.','Combos',698,'food-hero.jpg',true),
('25 Finger Jumbo','25 chicken fingers and 8 Chik Sauces.','Jumbo Meals',1899,'four-feast.jpg',true),
('15 Finger Jumbo','15 chicken fingers and 5 Chik Sauces.','Jumbo Meals',1099,'finger.jpg',true),
('50 Finger Jumbo','50 chicken fingers and 16 Chik Sauces.','Jumbo Meals',3599,'food-hero.jpg',true),
('Mango Soda Pop','A refreshing soda with a mix of mango flavor.','Beverage',159,'food-hero.jpg',true),
('Lemon Soda Pop','A refreshing soda with a mix of lemon flavor.','Beverage',159,'food-hero.jpg',true),
('One-Sided Butter Toast','One-sided buttered toast, lightly grilled.','Single Items',35,'dip.jpg',true),
('Chicken Finger','Fresh, never-frozen thick juicy chicken finger, hand-breaded and cooked to a crispy golden finish.','Single Items',79,'finger.jpg',true),
('Large Fries','Classic golden fries, crispy outside and fluffy inside.','Single Items',129,'food-hero.jpg',true),
('Regular Fries','Classic golden fries, crispy outside and fluffy inside.','Single Items',99,'food-hero.jpg',true),
('HotChik Sandwich','Two crispy chicken fingers in a sesame bun with lettuce, pickles, cheese and Chik Sauce.','Single Items',348,'finger.jpg',true),
('Coleslaw','Fresh creamy coleslaw with crisp cabbage and carrots.','Single Items',65,'dip.jpg',true),
('Chik Sauce (50 ML)','Creamy, tangy house-special dipping sauce.','Single Items',40,'dip.jpg',true)
on conflict do nothing;

insert into public.reviews(author,rating,review_text,review_url,featured,published_at) values
('Enara Azad',5,'New chicken finger spot in town! Tried the fingers and the HotChik sandwich and both were really good! The Chik Sauce was a standout and went perfectly with the fries and fingers. Nice place to sit and chill too.','https://www.google.com/maps/place/ChikChik/',true,current_date),
('Dxrkhxven_',5,'The food was great — like Bangladeshi Raising Cane’s. Service was great and the food was amazing.','https://www.google.com/maps/place/ChikChik/',true,current_date),
('A K Azad',5,'The foods and the behaviour are so good and I think this restaurant will have five stars.','https://www.google.com/maps/place/ChikChik/',true,current_date),
('Rehnuma Bhuiyan',5,'Food and environment are top notch. Insha Allah will be there soon for more chicken fingers!','https://www.google.com/maps/place/ChikChik/',true,current_date),
('sadia sobhan',5,'The prices are affordable, and the service was quick and efficient.','https://www.google.com/maps/place/ChikChik/',true,current_date)
; 

-- Realtime for customer tracking and admin queue.
alter publication supabase_realtime add table public.orders;
