-- Synthetic identities only. Owner 1 is deleted after backup; owner 2 survives
-- but deletes one garment; owner 3 and its garment must remain untouched.
INSERT INTO auth.users(id) VALUES
('10000000-0000-0000-0000-000000000001'),
('10000000-0000-0000-0000-000000000002'),
('10000000-0000-0000-0000-000000000003');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users;
INSERT INTO app.garments(id,user_id,name,category,price_grosz)
SELECT ('20000000-0000-0000-0000-00000000000' || n)::uuid,
       ('10000000-0000-0000-0000-00000000000' || n)::uuid,
       'Synthetic recovery fixture','top',80000
FROM generate_series(1,3) n;
INSERT INTO api_private.image_uploads(id,user_id,garment_id,state)
SELECT ('30000000-0000-0000-0000-00000000000' || n)::uuid,
       ('10000000-0000-0000-0000-00000000000' || n)::uuid,
       ('20000000-0000-0000-0000-00000000000' || n)::uuid,'ready'
FROM generate_series(1,3) n;
INSERT INTO app.garment_images(user_id,garment_id,variant,object_key,status,content_type)
SELECT user_id,garment_id,v,id::text || '/' || v || '.jpg','ready','image/jpeg'
FROM api_private.image_uploads CROSS JOIN (VALUES ('original'),('thumbnail')) variants(v);

-- Restorable caches deliberately contain garment metadata. Recovery must keep
-- replay/accounting identities while removing affected owners' payloads.
INSERT INTO api_private.mutations(user_id,operation_id,request,response)
SELECT user_id,('50000000-0000-0000-0000-' || right(id::text,12))::uuid,
    jsonb_build_object('operation_id',('50000000-0000-0000-0000-' || right(id::text,12))::uuid,
      'garment_id',id,'base_version',NULL,'garment',jsonb_build_object(
        'name',name,'category',category,'price_grosz',price_grosz,'availability',availability)),
    jsonb_build_object('data',jsonb_build_object('name',name,'price_grosz',price_grosz))
FROM app.garments;
INSERT INTO api_private.data_exports(id,user_id,snapshot)
SELECT ('60000000-0000-0000-0000-' || right(id::text,12))::uuid,user_id,
    jsonb_build_object('garments',jsonb_build_array(jsonb_build_object('name',name)))
FROM app.garments;
INSERT INTO app.ai_jobs(id,user_id,client_request_id,kind,status,lease_token,lease_expires_at)
SELECT ('70000000-0000-0000-0000-' || right(id::text,12))::uuid,user_id,
    ('80000000-0000-0000-0000-' || right(id::text,12))::uuid,'outfit_generation',
    CASE WHEN user_id='10000000-0000-0000-0000-000000000002' THEN 'running' ELSE 'succeeded' END,
    CASE WHEN user_id='10000000-0000-0000-0000-000000000002' THEN gen_random_uuid() END,
    CASE WHEN user_id='10000000-0000-0000-0000-000000000002' THEN now()+interval '1 hour' END
FROM app.garments;
INSERT INTO api_private.job_payloads(job_id,input,result)
SELECT j.id,jsonb_build_object('garment_name',g.name),
    jsonb_build_object('result',jsonb_build_object('garment_name',g.name))
FROM app.ai_jobs j JOIN app.garments g USING(user_id);
