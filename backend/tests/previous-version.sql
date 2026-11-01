-- Real v1 data must survive v2, including a historical snapshot and exact money.
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000001');
INSERT INTO app.profiles (id) SELECT id FROM auth.users;
INSERT INTO app.garments (id,user_id,name,category,price_grosz) VALUES
('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','Upgrade fixture','top',80000);
INSERT INTO app.wear_events (id,user_id,worn_on,timezone,client_request_id) VALUES
('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','2020-01-01','Europe/Warsaw','30000000-0000-0000-0000-000000000001');
INSERT INTO app.wear_event_items (user_id,wear_event_id,garment_id) VALUES
('00000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');
