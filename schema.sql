create extension if not exists pgcrypto;
create table if not exists public.menu_items(id uuid primary key default gen_random_uuid(),name text not null,description text,category text not null,price integer not null,image_url text,available boolean default true,created_at timestamptz default now());
create table if not exists public.orders(id uuid primary key default gen_random_uuid(),order_code text unique not null,name text not null,phone text not null,district text not null check (district='Dhaka'),area text not null,address text not null,items jsonb not null,total integer not null,status text not null default 'pending' check(status in ('pending','confirmed','preparing','ready','out_for_delivery','delivered','cancelled')),created_at timestamptz default now());
create table if not exists public.admin_profiles(id uuid primary key references auth.users(id) on delete cascade,email text unique not null,created_at timestamptz default now());
alter table public.menu_items enable row level security; alter table public.orders enable row level security; alter table public.admin_profiles enable row level security;
create policy "public can view available menu" on public.menu_items for select using (available=true);
create policy "public can create orders" on public.orders for insert with check (district='Dhaka');
create policy "customers can view by code" on public.orders for select using (true);
create policy "admins manage menu" on public.menu_items for all using (exists(select 1 from public.admin_profiles p where p.id=auth.uid()));
create policy "admins manage orders" on public.orders for update using (exists(select 1 from public.admin_profiles p where p.id=auth.uid()));
insert into public.menu_items(name,description,category,price,image_url) values
('Chikster Combo','6 chicken fingers, fries, toast, coleslaw & Chik sauce','Combos',679,null),('HotChik Combo','Hot chicken sandwich, fries & a cold drink','Combos',439,null),('4 Finger Combo','4 juicy chicken fingers, fries, toast & signature sauce','Combos',489,null),('3 Finger Combo','3 crispy fingers with fries and dipping sauce','Combos',389,null),('Mango Soda Pop','Fresh, fizzy and made for the crunch','Beverages',149,null),('Chik Sauce','Our signature dipping sauce','Sides',79,null)
on conflict do nothing;
