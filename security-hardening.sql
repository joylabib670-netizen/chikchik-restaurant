-- ChikChik production security remediation.
-- Existing project only: no new Supabase project is used.
create extension if not exists pgcrypto;

-- Rotate all legacy short tracking codes before enforcing 128-bit codes.
update public.orders
set order_code = 'CHK-' || upper(encode(gen_random_bytes(16), 'hex'));
alter table public.orders drop constraint if exists orders_order_code_format_check;
alter table public.orders add constraint orders_order_code_format_check
  check (order_code ~ '^[Cc][Hh][Kk]-[0-9A-Fa-f]{32}$');

-- Remove every legacy order policy. Orders are written only through create_order().
drop policy if exists "public can create orders" on public.orders;
drop policy if exists "public order insert" on public.orders;
drop policy if exists "public order tracking" on public.orders;
drop policy if exists "customers can view by code" on public.orders;
drop policy if exists "admins read orders" on public.orders;
drop policy if exists "admins update orders" on public.orders;
drop policy if exists "admin order update" on public.orders;
drop policy if exists "customers read own orders" on public.orders;
drop policy if exists "admins read all orders" on public.orders;
create policy "customers read own orders" on public.orders for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "admins read all orders" on public.orders for select to authenticated
  using (public.is_admin());
create policy "admins update orders" on public.orders for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admins delete orders" on public.orders for delete to authenticated
  using (public.is_admin());
revoke insert on public.orders from anon, authenticated;
revoke delete on public.orders from anon;
grant select, update, delete on public.orders to authenticated;

-- Server-side order creation. Client prices, totals, status, codes and user_id are ignored.
drop function if exists public.create_order(text,text,text,text,text,text,text,text,text,jsonb);
create or replace function public.create_order(
  p_name text, p_email text, p_phone text, p_division text, p_district text,
  p_upazila text, p_union_name text, p_area text, p_address text, p_items jsonb
)
returns table(order_code text, items jsonb, subtotal integer, delivery_charge integer,
  total integer, status text, created_at timestamptz, updated_at timestamptz)
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_item jsonb; v_id uuid; v_qty integer; v_product record;
  v_items jsonb := '[]'::jsonb; v_subtotal integer := 0; v_delivery integer := 60;
  v_code text; v_user_id uuid := auth.uid(); v_email text := lower(trim(coalesce(p_email,'')));
  v_phone text := public.normalize_bd_phone(p_phone); v_order public.orders;
begin
  if length(trim(coalesce(p_name,''))) not between 2 and 120 then raise exception 'A valid name is required'; end if;
  if v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'A valid email address is required'; end if;
  if length(v_phone) < 8 or length(v_phone) > 15 then raise exception 'A valid phone number is required'; end if;
  if trim(coalesce(p_division,'')) <> 'Dhaka' or trim(coalesce(p_district,'')) <> 'Dhaka' then raise exception 'Delivery is limited to Dhaka district'; end if;
  if length(trim(coalesce(p_upazila,''))) < 2 then raise exception 'A Dhaka upazila or city corporation is required'; end if;
  if length(trim(coalesce(p_area,''))) < 2 or length(trim(coalesce(p_address,''))) < 5 then raise exception 'A complete delivery address is required'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 20 then raise exception 'The order must contain between 1 and 20 items'; end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    begin
      v_id := (v_item->>'id')::uuid;
      v_qty := (v_item->>'qty')::integer;
    exception when invalid_text_representation then raise exception 'An order item is invalid'; end;
    if v_qty is null or v_qty < 1 or v_qty > 20 then raise exception 'Each item quantity must be between 1 and 20'; end if;
    select m.id,m.name,m.price into v_product from public.menu_items m where m.id=v_id and m.available=true;
    if not found then raise exception 'One or more selected dishes are unavailable'; end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object('id',v_product.id,'name',v_product.name,'price',v_product.price,'qty',v_qty));
    v_subtotal := v_subtotal + (v_product.price * v_qty);
  end loop;
  select coalesce((s.value->>'charge')::integer,60) into v_delivery from public.site_settings s where s.key='delivery';
  v_delivery := greatest(0,coalesce(v_delivery,60));
  v_code := 'CHK-' || upper(encode(gen_random_bytes(16),'hex'));
  insert into public.orders(order_code,name,email,phone,user_id,division,district,upazila,union_name,area,address,items,subtotal,delivery_charge,total,status)
  values(v_code,trim(p_name),v_email,v_phone,v_user_id,'Dhaka','Dhaka',trim(p_upazila),nullif(trim(coalesce(p_union_name,'')),''),trim(p_area),trim(p_address),v_items,v_subtotal,v_delivery,v_subtotal+v_delivery,'pending')
  returning * into v_order;
  return query select v_order.order_code,v_order.items,v_order.subtotal,v_order.delivery_charge,v_order.total,v_order.status,v_order.created_at,v_order.updated_at;
end;
$$;

-- Tracking requires the high-entropy code and guest's exact email or normalized phone.
drop function if exists public.get_order_by_code(text);
drop function if exists public.get_order_by_code(text,text);
create or replace function public.get_order_by_code(p_code text,p_verifier text default null)
returns table(order_code text, items jsonb, subtotal integer, delivery_charge integer,
  total integer, status text, created_at timestamptz, updated_at timestamptz)
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_order public.orders; v_verifier text := trim(coalesce(p_verifier,''));
  v_code text := upper(trim(coalesce(p_code,''))); v_attempts integer;
  v_key text := encode(digest(lower(trim(coalesce(p_code,''))),'sha256'),'hex');
begin
  if v_code !~ '^CHK-[0-9A-F]{32}$' then return; end if;
  insert into public.tracking_attempts(key_hash,window_started,attempts,last_attempt_at)
  values(v_key,now(),1,now())
  on conflict (key_hash) do update set
    attempts=case when public.tracking_attempts.window_started < now()-interval '10 minutes' then 1 else public.tracking_attempts.attempts+1 end,
    window_started=case when public.tracking_attempts.window_started < now()-interval '10 minutes' then now() else public.tracking_attempts.window_started end,
    last_attempt_at=now()
  returning attempts into v_attempts;
  if v_attempts > 10 then raise exception 'Too many tracking attempts. Please try again later'; end if;
  select o.* into v_order from public.orders o
  where upper(o.order_code)=v_code and (public.is_admin() or ((select auth.uid()) is not null and o.user_id=(select auth.uid())) or (length(v_verifier)>0 and (lower(coalesce(o.email,''))=lower(v_verifier) or public.normalize_bd_phone(o.phone)=public.normalize_bd_phone(v_verifier)))) limit 1;
  if not found then return; end if;
  return query select v_order.order_code,v_order.items,v_order.subtotal,v_order.delivery_charge,v_order.total,v_order.status,v_order.created_at,v_order.updated_at;
end;
$$;

-- A per-token retry cap complements the 128-bit token and verifier requirement.
create table if not exists public.tracking_attempts(key_hash text primary key,window_started timestamptz not null default now(),attempts integer not null default 0,last_attempt_at timestamptz not null default now());
alter table public.tracking_attempts enable row level security;
revoke all on public.tracking_attempts from anon, authenticated;

-- Harden admin helper and remove direct membership-table access.
create or replace function public.is_admin() returns boolean language sql stable security definer
set search_path = pg_catalog, public, auth as $$ select exists(select 1 from public.admin_profiles where id=(select auth.uid())); $$;
revoke all on public.admin_profiles from anon, authenticated;

-- Admin policies are authenticated-only; public policies remain read-only where intended.
drop policy if exists "admins manage menu" on public.menu_items;
create policy "admins manage menu" on public.menu_items for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage offers" on public.offers;
create policy "admins manage offers" on public.offers for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage reviews" on public.reviews;
create policy "admins manage reviews" on public.reviews for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage social profiles" on public.social_profiles;
create policy "admins manage social profiles" on public.social_profiles for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage social posts" on public.social_posts;
create policy "admins manage social posts" on public.social_posts for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage settings" on public.site_settings;
create policy "admins manage settings" on public.site_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage profiles" on public.profiles;
create policy "admins manage profiles" on public.profiles for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage rewards" on public.rewards;
create policy "admins manage rewards" on public.rewards for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage product reviews" on public.product_reviews;
create policy "admins manage product reviews" on public.product_reviews for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage posts" on public.content_posts;
create policy "admins manage posts" on public.content_posts for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage stories" on public.content_stories;
create policy "admins manage stories" on public.content_stories for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Normal-user write paths are authenticated and ownership-scoped.
drop policy if exists "users create product reviews" on public.product_reviews;
create policy "users create product reviews" on public.product_reviews for insert to authenticated with check (user_id=(select auth.uid()));
drop policy if exists "users update own product reviews" on public.product_reviews;
create policy "users update own product reviews" on public.product_reviews for update to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
drop policy if exists "users insert own profile" on public.profiles;
create policy "users insert own profile" on public.profiles for insert to authenticated with check (id=(select auth.uid()));
drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile" on public.profiles for update to authenticated using (id=(select auth.uid())) with check (id=(select auth.uid()));
drop policy if exists "users create posts" on public.content_posts;
create policy "users create posts" on public.content_posts for insert to authenticated with check (author_role='user' and user_id=(select auth.uid()));
drop policy if exists "users update own posts" on public.content_posts;
create policy "users update own posts" on public.content_posts for update to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
drop policy if exists "users create stories" on public.content_stories;
create policy "users create stories" on public.content_stories for insert to authenticated with check (author_role='user' and user_id=(select auth.uid()) and active_until <= now()+interval '24 hours');
drop policy if exists "users update own stories" on public.content_stories;
create policy "users update own stories" on public.content_stories for update to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()) and active_until <= now()+interval '24 hours');

-- Remove public execution from trigger/internal routines; then grant only intended API endpoints.
do $$ declare r record; begin
  for r in select p.proname,pg_get_function_identity_arguments(p.oid) args from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('claim_guest_orders','claim_guest_orders_for_user','grant_order_reward','handle_new_user','handle_new_user_profile','profiles_normalize_phone','touch_updated_at','normalize_bd_phone') loop
    execute format('revoke all on function public.%I(%s) from public, anon, authenticated',r.proname,r.args);
  end loop;
end $$;
revoke all on function public.is_admin() from public, anon;
revoke all on function public.is_phone_available(text) from public;
revoke all on function public.get_product_reviews(uuid) from public;
revoke all on function public.get_order_by_code(text,text) from public;
revoke all on function public.create_order(text,text,text,text,text,text,text,text,text,jsonb) from public;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_phone_available(text) to anon,authenticated;
grant execute on function public.get_product_reviews(uuid) to anon,authenticated;
grant execute on function public.get_order_by_code(text,text) to anon,authenticated;
grant execute on function public.create_order(text,text,text,text,text,text,text,text,text,jsonb) to anon,authenticated;
grant execute on function public.claim_guest_orders_for_user() to authenticated;

-- Foreign-key indexes flagged by the performance advisor.
create index if not exists content_posts_user_id_idx on public.content_posts(user_id);
create index if not exists content_stories_user_id_idx on public.content_stories(user_id);
create index if not exists product_reviews_user_id_idx on public.product_reviews(user_id);
