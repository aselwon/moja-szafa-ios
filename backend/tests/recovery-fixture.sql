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
