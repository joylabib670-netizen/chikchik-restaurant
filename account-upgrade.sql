-- ChikChik account, rewards, product detail, review, storage and content upgrade.
create extension if not exists pgcrypto;

alter table public.menu_items add column if not exists ingredients text;
alter table public.menu_items add column if not exists specifications text;
alter table public.menu_items add column if not exists gallery_urls text[] not null default '{}';
alter table public.menu_items add column if not exists video_url text;

alter table public.orders add column if not exists email text;
alter table public.orders add column if not exists user_id uuid references auth.users(id) on delete set null;
create index if not exists orders_user_id_idx on public.orders(user_id);
create index if not exists orders_email_idx on public.orders(lower(email));

create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  phone text unique not null,
  full_name text not null,
  username text unique not null,
  division text not null default 'Dhaka',
  district text not null default 'Dhaka' check(district='Dhaka'),
  upazila text not null,
  union_name text,
  street_address text not null,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.rewards(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  order_id uuid not null unique references public.orders(id) on delete cascade,
  reward_points integer not null check(reward_points>0),
  reason text not null default 'Reward for confirmed order',
  created_at timestamptz not null default now()
);

create table if not exists public.product_reviews(
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.menu_items(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  rating integer not null check(rating between 1 and 5),
  review_text text not null check(length(trim(review_text)) between 3 and 1200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(product_id,user_id)
);

create table if not exists public.content_posts(
  id uuid primary key default gen_random_uuid(),
  author_role text not null check(author_role in ('admin','user')),
  user_id uuid references auth.users(id) on delete set null,
  media_type text not null check(media_type in ('image','short_video','long_video')),
  media_url text not null,
  thumbnail_url text,
  caption text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists content_posts_created_idx on public.content_posts(created_at desc);

create table if not exists public.content_stories(
  id uuid primary key default gen_random_uuid(),
  author_role text not null check(author_role in ('admin','user')),
  user_id uuid references auth.users(id) on delete set null,
  media_type text not null check(media_type in ('image','short_video')),
  media_url text not null,
  caption text,
  active_until timestamptz not null,
  created_at timestamptz not null default now(),
  constraint story_max_24h check(active_until <= created_at + interval '24 hours')
);
create index if not exists content_stories_active_idx on public.content_stories(active_until desc);

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$ begin new.updated_at=now(); return new; end $$;
drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists product_reviews_touch_updated_at on public.product_reviews;
create trigger product_reviews_touch_updated_at before update on public.product_reviews for each row execute function public.touch_updated_at();

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.admin_profiles where id=auth.uid());
$$;
grant execute on function public.is_admin() to anon, authenticated;

create or replace function public.is_phone_available(p_phone text) returns boolean language sql security definer set search_path=public as $$
  select not exists(select 1 from public.profiles where phone=trim(p_phone));
$$;
grant execute on function public.is_phone_available(text) to anon, authenticated;

create or replace function public.claim_guest_orders() returns trigger language plpgsql security definer set search_path=public as $$
begin
  update public.orders set user_id=new.id where user_id is null and ((email is not null and lower(email)=lower(new.email)) or phone=new.phone);
  return new;
end $$;
drop trigger if exists profiles_claim_guest_orders on public.profiles;
create trigger profiles_claim_guest_orders after insert or update of email,phone on public.profiles for each row execute function public.claim_guest_orders();

create or replace function public.grant_order_reward() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status='confirmed' and (tg_op='INSERT' or old.status is distinct from 'confirmed') and new.user_id is not null then
    insert into public.rewards(user_id,order_id,reward_points,reason)
    values(new.user_id,new.id,greatest(1,floor(new.total/100.0)::integer),'Reward for confirmed ChikChik order')
    on conflict(order_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists orders_grant_reward on public.orders;
create trigger orders_grant_reward after insert or update of status,user_id on public.orders for each row execute function public.grant_order_reward();

-- Include email on new anonymous orders without requiring an account.
drop policy if exists "public can create orders" on public.orders;
create policy "public can create orders" on public.orders for insert with check (district='Dhaka' and division='Dhaka' and email is not null and length(trim(email))>3);

alter table public.profiles enable row level security;
alter table public.rewards enable row level security;
alter table public.product_reviews enable row level security;
alter table public.content_posts enable row level security;
alter table public.content_stories enable row level security;

drop policy if exists "users read own profile" on public.profiles;
drop policy if exists "users insert own profile" on public.profiles;
drop policy if exists "users update own profile" on public.profiles;
drop policy if exists "admins manage profiles" on public.profiles;
create policy "users read own profile" on public.profiles for select using (id=auth.uid() or public.is_admin());
create policy "users insert own profile" on public.profiles for insert with check (id=auth.uid());
create policy "users update own profile" on public.profiles for update using (id=auth.uid()) with check (id=auth.uid());
create policy "admins manage profiles" on public.profiles for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "users read own rewards" on public.rewards;
drop policy if exists "admins manage rewards" on public.rewards;
create policy "users read own rewards" on public.rewards for select using (user_id=auth.uid() or public.is_admin());
create policy "admins manage rewards" on public.rewards for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "public read product reviews" on public.product_reviews;
drop policy if exists "users create product reviews" on public.product_reviews;
drop policy if exists "users update own product reviews" on public.product_reviews;
drop policy if exists "admins manage product reviews" on public.product_reviews;
create policy "public read product reviews" on public.product_reviews for select using (true);
create policy "users create product reviews" on public.product_reviews for insert to authenticated with check (user_id=auth.uid());
create policy "users update own product reviews" on public.product_reviews for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());
create policy "admins manage product reviews" on public.product_reviews for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "public read active posts" on public.content_posts;
drop policy if exists "users create posts" on public.content_posts;
drop policy if exists "users update own posts" on public.content_posts;
drop policy if exists "admins manage posts" on public.content_posts;
create policy "public read active posts" on public.content_posts for select using (active=true or user_id=auth.uid() or public.is_admin());
create policy "users create posts" on public.content_posts for insert to authenticated with check (author_role='user' and user_id=auth.uid());
create policy "users update own posts" on public.content_posts for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());
create policy "admins manage posts" on public.content_posts for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "public read active stories" on public.content_stories;
drop policy if exists "users create stories" on public.content_stories;
drop policy if exists "users update own stories" on public.content_stories;
drop policy if exists "admins manage stories" on public.content_stories;
create policy "public read active stories" on public.content_stories for select using (active_until>now() or user_id=auth.uid() or public.is_admin());
create policy "users create stories" on public.content_stories for insert to authenticated with check (author_role='user' and user_id=auth.uid() and active_until<=now()+interval '24 hours');
create policy "users update own stories" on public.content_stories for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid() and active_until<=now()+interval '24 hours');
create policy "admins manage stories" on public.content_stories for all using (public.is_admin()) with check (public.is_admin());

-- Public media bucket; database policies remain the source of truth for rows.
insert into storage.buckets(id,name,public) values('chikchik-media','chikchik-media',true) on conflict(id) do update set public=true;
drop policy if exists "public read chikchik media" on storage.objects;
drop policy if exists "authenticated upload chikchik media" on storage.objects;
drop policy if exists "admins delete chikchik media" on storage.objects;
create policy "public read chikchik media" on storage.objects for select using (bucket_id='chikchik-media');
create policy "authenticated upload chikchik media" on storage.objects for insert to authenticated with check (bucket_id='chikchik-media');
create policy "admins delete chikchik media" on storage.objects for delete to authenticated using (bucket_id='chikchik-media' and public.is_admin());

-- Admin-only order/customer access remains protected; customers see their own history only.
drop policy if exists "admins read orders" on public.orders;
create policy "admins read orders" on public.orders for select using (public.is_admin() or user_id=auth.uid());
drop policy if exists "admins update orders" on public.orders;
create policy "admins update orders" on public.orders for update using (public.is_admin()) with check (public.is_admin());

alter publication supabase_realtime add table public.profiles;
alter publication supabase_realtime add table public.rewards;
alter publication supabase_realtime add table public.content_posts;
alter publication supabase_realtime add table public.content_stories;
