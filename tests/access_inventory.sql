begin;
-- Fixtures exist only within this rolled-back test transaction.
insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values
('10000000-0000-4000-8000-000000000001','buyer@test.invalid',now(),'{"name":"Buyer","role":"admin"}'),
('10000000-0000-4000-8000-000000000002','seller@test.invalid',now(),'{"name":"Seller","role":"seller"}'),
('10000000-0000-4000-8000-000000000003','admin@test.invalid',now(),'{"name":"Admin"}'),
('10000000-0000-4000-8000-000000000004','stranger@test.invalid',now(),'{"name":"Stranger"}');
update public.bj_profiles set role='admin' where id='10000000-0000-4000-8000-000000000003';
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
select public.bj_command('apply_seller','{"business_name":"Test Artisan","phone":"+919000000000","location":"Bagalkote"}');
do $$begin
 if (select role from public.bj_profiles where id='10000000-0000-4000-8000-000000000001')<>'customer' then raise exception 'TEST FAILED: metadata elevated admin'; end if;
 begin perform public.bj_command('save_product','{}'); raise exception 'TEST FAILED: unapproved seller published'; exception when raise_exception then if sqlerrm like 'TEST FAILED%' then raise; end if; end;
 begin perform public.bj_command('moderate_seller','{"id":"10000000-0000-4000-8000-000000000002","status":"approved"}'); raise exception 'TEST FAILED: seller self-approved'; exception when raise_exception then if sqlerrm like 'TEST FAILED%' then raise; end if; end;
end $$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',true);
select public.bj_command('moderate_seller','{"id":"10000000-0000-4000-8000-000000000002","status":"approved"}');
insert into public.bj_products(id,seller_id,title,category,price,stock,image_path) values('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','Test jute bag','Jute Bags',100,2,'fixture.jpg');
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
select public.bj_command('place_order','{"product_id":"20000000-0000-4000-8000-000000000001","quantity":2,"buyer_name":"Buyer","buyer_phone":"+919000000001","address":"123 Test Street, Bagalkote 587101"}');
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
select public.bj_command('quote_order',jsonb_build_object('id',(select id from public.bj_orders where buyer_id='10000000-0000-4000-8000-000000000001'),'shipping',20,'payment_instructions','Test recipient / UPI test@example'));
do $$begin if bj_private.available('20000000-0000-4000-8000-000000000001')<>0 then raise exception 'TEST FAILED: reservation'; end if; end $$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000004',true);
do $$begin
 begin perform public.bj_command('place_order','{"product_id":"20000000-0000-4000-8000-000000000001","quantity":1,"buyer_name":"Stranger","buyer_phone":"+919000000002","address":"123 Test Street"}'); raise exception 'TEST FAILED: overselling'; exception when raise_exception then if sqlerrm like 'TEST FAILED%' then raise; end if; end;
end $$;
set local role authenticated;
do $$begin
 if exists(select 1 from public.bj_orders) then raise exception 'TEST FAILED: stranger sees orders'; end if;
 begin update public.bj_profiles set role='admin' where id=auth.uid(); raise exception 'TEST FAILED: direct role update'; exception when insufficient_privilege then null; end;
 begin insert into public.bj_products(seller_id,title,category,price,stock,image_path) values(auth.uid(),'Fake bag','Jute Bags',1,1,'x'); raise exception 'TEST FAILED: direct listing'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
select public.bj_command('submit_payment',jsonb_build_object('id',(select id from public.bj_orders where buyer_id='10000000-0000-4000-8000-000000000001'),'amount',220,'reference','TESTREF123456'));
do $$begin
 if (select stock from public.bj_products where id='20000000-0000-4000-8000-000000000001')<>2 then raise exception 'TEST FAILED: unverified payment reduced stock'; end if;
 begin perform public.bj_command('approve_payment',jsonb_build_object('id',(select id from public.bj_orders where buyer_id=auth.uid()))); raise exception 'TEST FAILED: buyer verified payment'; exception when raise_exception then if sqlerrm like 'TEST FAILED%' then raise; end if; end;
end $$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
select public.bj_command('approve_payment',jsonb_build_object('id',(select id from public.bj_orders where seller_id=auth.uid())));
do $$begin
 if (select stock from public.bj_products where id='20000000-0000-4000-8000-000000000001')<>0 then raise exception 'TEST FAILED: verified inventory'; end if;
 begin perform public.bj_command('approve_payment',jsonb_build_object('id',(select id from public.bj_orders where seller_id=auth.uid()))); raise exception 'TEST FAILED: duplicate approval'; exception when raise_exception then if sqlerrm like 'TEST FAILED%' then raise; end if; end;
end $$;
select public.bj_command('dispatch',jsonb_build_object('id',(select id from public.bj_orders where seller_id=auth.uid()),'tracking','Courier TEST123'));
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
select public.bj_command('delivered',jsonb_build_object('id',(select id from public.bj_orders where buyer_id=auth.uid())));
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',true);
select public.bj_command('moderate_seller','{"id":"10000000-0000-4000-8000-000000000002","status":"suspended"}');
set local role anon;
do $$begin if exists(select 1 from public.bj_catalog where id='20000000-0000-4000-8000-000000000001') then raise exception 'TEST FAILED: suspended seller in catalogue'; end if; end $$;
reset role;
select 'PASS: roles, private orders, stock reservations, overselling, payment verification, dispatch, suspension' as test_result;
rollback;
