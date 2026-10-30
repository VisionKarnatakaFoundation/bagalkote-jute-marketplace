-- Bagalkote marketplace: all mutations go through checked, transactional RPCs.
create schema if not exists bj_private;
revoke all on schema bj_private from public;
grant usage on schema bj_private to authenticated, anon;
create table public.bj_profiles(id uuid primary key references auth.users(id), name text not null, role text not null default 'customer' check(role in ('customer','seller','admin')), created_at timestamptz not null default now());
create table public.bj_sellers(id uuid primary key references public.bj_profiles(id), business_name text not null check(length(business_name) between 2 and 100), phone text not null check(phone ~ '^\+[0-9]{10,15}$'), location text not null, status text not null default 'pending' check(status in ('pending','approved','suspended')), created_at timestamptz default now());
create table public.bj_products(id uuid primary key default gen_random_uuid(), seller_id uuid not null references public.bj_sellers(id), title text not null check(length(title) between 2 and 100), category text not null check(category in ('Jute Bags','Jute Mobile Pouch','Soft Jute Dresses','Designer Jute Bags (Custom Made)','Jute Purse')), description text not null default '' check(length(description)<=2000), price numeric(12,2) not null check(price>0 and price<=9999999), stock integer not null check(stock between 0 and 100000), image_path text not null, active boolean not null default true, created_at timestamptz not null default now());
create table public.bj_orders(id uuid primary key default gen_random_uuid(), buyer_id uuid not null references public.bj_profiles(id), seller_id uuid not null references public.bj_sellers(id), product_id uuid not null references public.bj_products(id), title text not null, unit_price numeric(12,2) not null, quantity integer not null check(quantity between 1 and 10000), buyer_name text not null, buyer_phone text not null check(buyer_phone ~ '^\+[0-9]{10,15}$'), address text not null check(length(address) between 10 and 1000), seller_phone text not null, status text not null default 'requested' check(status in ('requested','awaiting_payment','payment_submitted','paid','dispatched','delivered','cancelled')), shipping numeric(12,2) not null default 0 check(shipping>=0 and shipping<=999999), payment_instructions text not null default '', payment_reference text, payment_amount numeric(12,2), payment_submitted_at timestamptz, payment_verified_at timestamptz, expires_at timestamptz, tracking text, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create unique index bj_payment_reference_unique on public.bj_orders(seller_id,lower(payment_reference)) where payment_reference is not null;
create index on public.bj_orders(buyer_id); create index on public.bj_orders(seller_id); create index on public.bj_orders(product_id,status);create index on public.bj_products(seller_id);
create table public.bj_events(id bigint generated always as identity primary key, order_id uuid references public.bj_orders(id), actor_id uuid references public.bj_profiles(id), action text not null, detail jsonb not null default '{}', created_at timestamptz not null default now());
create index on public.bj_events(order_id);create index on public.bj_events(actor_id);
create function bj_private.new_profile() returns trigger language plpgsql security definer set search_path='' as $$ begin
 insert into public.bj_profiles(id,name,role) values(new.id,left(coalesce(nullif(new.raw_user_meta_data->>'name',''),'Member'),100),case when new.raw_user_meta_data->>'role'='seller' then 'seller' else 'customer' end); return new; end $$;
create trigger bj_new_profile after insert on auth.users for each row execute function bj_private.new_profile();
create function bj_private.is_admin() returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and exists(select 1 from public.bj_profiles where id=auth.uid() and role='admin') $$;
create function bj_private.is_seller() returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and exists(select 1 from public.bj_sellers where id=auth.uid() and status='approved') $$;
create function bj_private.available(pid uuid) returns integer language sql stable security definer set search_path='' as $$ select greatest(0,p.stock-coalesce((select sum(o.quantity) from public.bj_orders o where o.product_id=p.id and (o.status='payment_submitted' or (o.status='awaiting_payment' and o.expires_at>now()))),0))::integer from public.bj_products p where p.id=pid $$;
alter table public.bj_profiles enable row level security;alter table public.bj_sellers enable row level security;alter table public.bj_products enable row level security;alter table public.bj_orders enable row level security;alter table public.bj_events enable row level security;
create policy profile_read on public.bj_profiles for select to authenticated using(id=(select auth.uid()) or (select bj_private.is_admin()));
create policy seller_read on public.bj_sellers for select to anon,authenticated using(status='approved' or id=(select auth.uid()) or (select bj_private.is_admin()));
create policy product_read on public.bj_products for select to anon,authenticated using((active and exists(select 1 from public.bj_sellers s where s.id=seller_id and s.status='approved')) or seller_id=(select auth.uid()) or (select bj_private.is_admin()));
create policy order_read on public.bj_orders for select to authenticated using(buyer_id=(select auth.uid()) or seller_id=(select auth.uid()) or (select bj_private.is_admin()));
create policy event_read on public.bj_events for select to authenticated using((select bj_private.is_admin()) or exists(select 1 from public.bj_orders o where o.id=order_id and (o.buyer_id=(select auth.uid()) or o.seller_id=(select auth.uid()))));
revoke all on public.bj_profiles,public.bj_sellers,public.bj_products,public.bj_orders,public.bj_events from anon,authenticated;
grant select on public.bj_sellers,public.bj_products to anon,authenticated;
grant select on public.bj_profiles,public.bj_orders,public.bj_events to authenticated;
create view public.bj_catalog with(security_invoker=true) as select p.*,s.business_name,s.phone,s.location,bj_private.available(p.id) available from public.bj_products p join public.bj_sellers s on s.id=p.seller_id where p.active and s.status='approved';
grant select on public.bj_catalog to anon,authenticated;
-- Single command entry point; no caller-controlled SQL or arbitrary table updates.
create function bj_private.command(action text, payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); p public.bj_products; o public.bj_orders; rid uuid; qty integer; total numeric; target uuid; next_status text; begin
 if uid is null or not exists(select 1 from auth.users where id=uid and email_confirmed_at is not null) then raise exception 'Please sign in with a verified email address'; end if;
 if action='apply_seller' then
  if exists(select 1 from public.bj_sellers where id=uid) then raise exception 'Your seller application already exists'; end if;
  insert into public.bj_sellers(id,business_name,phone,location) values(uid,payload->>'business_name',payload->>'phone',left(payload->>'location',100));
  update public.bj_profiles set role='seller' where id=uid and role='customer';
 elsif action='moderate_seller' then
  if not bj_private.is_admin() then raise exception 'Admin access required'; end if;
  next_status:=payload->>'status'; if next_status not in ('approved','suspended') or next_status is null then raise exception 'Invalid status'; end if;
  update public.bj_sellers set status=next_status where id=(payload->>'id')::uuid;
  if not found then raise exception 'Seller not found'; end if;
  insert into public.bj_events(actor_id,action,detail) values(uid,action,payload);
 elsif action='save_product' then
  if not bj_private.is_seller() then raise exception 'Seller approval required'; end if;
  if not exists(select 1 from storage.objects where bucket_id='jute-products' and name=payload->>'image_path' and (storage.foldername(name))[1]=uid::text) then raise exception 'Upload your product photo first'; end if;
  if nullif(payload->>'id','') is null then
   insert into public.bj_products(seller_id,title,category,description,price,stock,image_path) values(uid,payload->>'title',payload->>'category',payload->>'description',(payload->>'price')::numeric,(payload->>'stock')::integer,payload->>'image_path') returning id into rid;
  else
   select * into p from public.bj_products where id=(payload->>'id')::uuid for update;
   if p.id is null or p.seller_id<>uid then raise exception 'Product not found'; end if;
   if (payload->>'stock')::integer < p.stock-bj_private.available(p.id) then raise exception 'Stock cannot be lower than reserved orders'; end if;
   update public.bj_products set title=payload->>'title',category=payload->>'category',description=payload->>'description',price=(payload->>'price')::numeric,stock=(payload->>'stock')::integer,image_path=payload->>'image_path' where id=p.id returning id into rid;
  end if;
 elsif action='hide_product' then
  select * into p from public.bj_products where id=(payload->>'id')::uuid for update;
  if p.id is null or not (p.seller_id=uid or bj_private.is_admin()) then raise exception 'Access denied'; end if;
  update public.bj_products set active=false where id=p.id;
  insert into public.bj_events(actor_id,action,detail) values(uid,action,payload);
 elsif action='place_order' then
  select * into p from public.bj_products where id=(payload->>'product_id')::uuid for update;
  if p.id is null or not p.active or p.seller_id=uid or not exists(select 1 from public.bj_sellers where id=p.seller_id and status='approved') then raise exception 'Product is unavailable'; end if;
  qty:=(payload->>'quantity')::integer;
  if qty is null or qty<1 or qty>bj_private.available(p.id) then raise exception 'Requested quantity is unavailable'; end if;
  if exists(select 1 from public.bj_orders where buyer_id=uid and product_id=p.id and status in ('requested','awaiting_payment','payment_submitted') and (expires_at is null or expires_at>now())) then raise exception 'You already have an open order for this product'; end if;
  insert into public.bj_orders(buyer_id,seller_id,product_id,title,unit_price,quantity,buyer_name,buyer_phone,address,seller_phone) select uid,p.seller_id,p.id,p.title,p.price,qty,left(payload->>'buyer_name',100),payload->>'buyer_phone',payload->>'address',s.phone from public.bj_sellers s where s.id=p.seller_id returning id into rid;
  insert into public.bj_events(order_id,actor_id,action) values(rid,uid,action);
 else
  -- Always lock product first, then order, to serialize inventory changes.
  select product_id into target from public.bj_orders where id=(payload->>'id')::uuid;
  select * into p from public.bj_products where id=target for update;
  select * into o from public.bj_orders where id=(payload->>'id')::uuid for update;
  if o.id is null or not (uid=o.buyer_id or uid=o.seller_id or bj_private.is_admin()) then raise exception 'Order not found'; end if;
  rid:=o.id;
  if action='quote_order' then
   if uid<>o.seller_id or not bj_private.is_seller() or not p.active or not (o.status='requested' or (o.status='awaiting_payment' and o.expires_at<=now())) then raise exception 'Cannot confirm this order'; end if;
   if o.quantity>bj_private.available(p.id) then raise exception 'Insufficient available stock'; end if;
   if length(trim(coalesce(payload->>'payment_instructions','')))<5 then raise exception 'Enter payment recipient and UPI or bank details'; end if;
   update public.bj_orders set status='awaiting_payment',shipping=(payload->>'shipping')::numeric,payment_instructions=left(payload->>'payment_instructions',1500),expires_at=now()+interval '48 hours',updated_at=now() where id=o.id;
  elsif action='submit_payment' then
   if uid<>o.buyer_id or o.status<>'awaiting_payment' or o.expires_at<=now() then raise exception 'Payment window closed; contact the seller before paying'; end if;
   if not exists(select 1 from public.bj_sellers where id=o.seller_id and status='approved') then raise exception 'Seller suspended; contact VKF before making payment'; end if;
   total:=o.unit_price*o.quantity+o.shipping;
   if (payload->>'amount')::numeric is distinct from total then raise exception 'Amount must equal the order total'; end if;
   if coalesce(payload->>'reference','') !~ '^[A-Za-z0-9/-]{6,100}$' then raise exception 'Enter a valid payment reference (6–100 characters)'; end if;
   update public.bj_orders set status='payment_submitted',payment_reference=upper(payload->>'reference'),payment_amount=total,payment_submitted_at=now(),updated_at=now() where id=o.id;
  elsif action='approve_payment' then
   if uid<>o.seller_id or o.status<>'payment_submitted' then raise exception 'Only the seller can verify a submitted payment'; end if;
   if p.stock<o.quantity then raise exception 'Stock mismatch; contact admin'; end if;
   update public.bj_products set stock=stock-o.quantity where id=p.id;
   update public.bj_orders set status='paid',payment_verified_at=now(),updated_at=now() where id=o.id;
  elsif action='reject_payment' then
   if uid<>o.seller_id or o.status<>'payment_submitted' then raise exception 'Cannot reject this payment'; end if;
   -- Keep the rejected reference in the immutable history.
   insert into public.bj_events(order_id,actor_id,action,detail) values(o.id,uid,'rejected_reference',jsonb_build_object('reference',o.payment_reference,'amount',o.payment_amount,'reason',left(payload->>'reason',500)));
   update public.bj_orders set status='awaiting_payment',payment_reference=null,payment_amount=null,payment_submitted_at=null,expires_at=now()+interval '48 hours',updated_at=now() where id=o.id;
  elsif action='dispatch' then
   if uid<>o.seller_id or o.status<>'paid' or length(trim(coalesce(payload->>'tracking','')))<3 then raise exception 'Verify payment and enter courier/tracking details first'; end if;
   update public.bj_orders set status='dispatched',tracking=left(payload->>'tracking',500),updated_at=now() where id=o.id;
  elsif action='delivered' then
   if uid<>o.buyer_id or o.status<>'dispatched' then raise exception 'Only the customer can confirm receipt'; end if;
   update public.bj_orders set status='delivered',updated_at=now() where id=o.id;
  elsif action='cancel_order' then
   if o.status not in ('requested','awaiting_payment') then raise exception 'Payment submitted or already paid: contact seller and admin for resolution'; end if;
   update public.bj_orders set status='cancelled',updated_at=now() where id=o.id;
  else raise exception 'Unknown action'; end if;
  insert into public.bj_events(order_id,actor_id,action) values(o.id,uid,action);
 end if;
 return jsonb_build_object('id',rid,'success',true);
end $$;
create function public.bj_command(action text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select bj_private.command(action,payload)$$;
revoke all on all functions in schema bj_private from public,anon,authenticated;
grant execute on function bj_private.is_admin(),bj_private.is_seller(),bj_private.available(uuid) to anon,authenticated;
grant execute on function bj_private.command(text,jsonb) to authenticated;
revoke all on function public.bj_command(text,jsonb) from public,anon;
grant execute on function public.bj_command(text,jsonb) to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('jute-products','jute-products',true,1048576,array['image/jpeg','image/png','image/webp']);
create policy jute_photo_insert on storage.objects for insert to authenticated with check(bucket_id='jute-products' and (storage.foldername(name))[1]=(select auth.uid())::text and (select bj_private.is_seller()));
-- Photos are immutable uploads; no broad overwrite/delete permission.
