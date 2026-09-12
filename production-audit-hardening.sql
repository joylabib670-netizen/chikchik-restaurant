-- ChikChik production audit hardening (existing Supabase project only).
drop policy if exists "public menu" on public.menu_items;
drop policy if exists "public active menu" on public.menu_items;
create policy "public active menu" on public.menu_items for select to public
  using (available = true and catalog_status = 'active');

-- Never allow a browser to order a hidden or pending-verification product by UUID.
create or replace function public.create_order(
  p_name text, p_email text, p_phone text, p_division text, p_district text,
  p_upazila text, p_union_name text, p_area text, p_address text, p_items jsonb
)
returns table(order_code text, items jsonb, subtotal integer, delivery_charge integer,
  total integer, status text, created_at timestamptz, updated_at timestamptz)
language plpgsql security definer
set search_path = pg_catalog, public, auth, extensions
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
    select m.id,m.name,m.price into v_product from public.menu_items m
      where m.id=v_id and m.available=true and m.catalog_status='active';
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

-- Internal SECURITY DEFINER routines use an explicit trusted search path.
alter function public.claim_guest_orders() set search_path = pg_catalog, public, auth;
alter function public.claim_guest_orders_for_user() set search_path = pg_catalog, public, auth;
alter function public.get_product_reviews(uuid) set search_path = pg_catalog, public, auth;
alter function public.handle_new_user() set search_path = pg_catalog, public, auth;
alter function public.handle_new_user_profile() set search_path = pg_catalog, public, auth;
alter function public.is_phone_available(text) set search_path = pg_catalog, public, auth;
alter function public.profiles_normalize_phone() set search_path = pg_catalog, public, auth;
alter function public.grant_order_reward() set search_path = pg_catalog, public, auth;
alter function public.touch_updated_at() set search_path = pg_catalog, public, auth;
