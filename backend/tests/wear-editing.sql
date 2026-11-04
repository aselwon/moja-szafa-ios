BEGIN;
CREATE FUNCTION pg_temp.assert_wear(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END $$;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000091'), ('00000000-0000-0000-0000-000000000092');
INSERT INTO app.profiles(id,user_id) SELECT id,id FROM auth.users WHERE id IN ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000092');
INSERT INTO app.garments(id,user_id,name,category) VALUES
('00000000-0000-0000-0000-000000000093','00000000-0000-0000-0000-000000000091','Shirt','top'),
('00000000-0000-0000-0000-000000000094','00000000-0000-0000-0000-000000000091','Shoes','shoes'),
('00000000-0000-0000-0000-000000000095','00000000-0000-0000-0000-000000000092','Foreign','top');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000091',true);
DO $$
DECLARE
    a uuid := gen_random_uuid();
    b uuid := gen_random_uuid();
    outfit_id uuid := gen_random_uuid();
    request jsonb;
    result jsonb;
    invalid jsonb;
    outfit jsonb;
BEGIN
    outfit := jsonb_build_object('operationID',gen_random_uuid(),'id',outfit_id,'baseVersion',0,'name','Original','favorite',false,
        'garmentIDs',jsonb_build_array('00000000-0000-0000-0000-000000000093','00000000-0000-0000-0000-000000000094'));
    PERFORM pg_temp.assert_wear(app.api_v1_save_outfit(outfit) ? 'data','create outfit');
    request := jsonb_build_object('operationID',gen_random_uuid(),'wear',jsonb_build_object('id',a,'version',0,'deleted',false,
        'wornOn','2026-01-01','timezone','Europe/Warsaw','garmentIDs',outfit->'garmentIDs'));
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(request) ? 'data','first event');
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(jsonb_set(jsonb_set(request,'{operationID}',to_jsonb(gen_random_uuid())),
        '{wear,id}',to_jsonb(b))) ? 'data','second event same day');
    outfit := outfit || jsonb_build_object('operationID',gen_random_uuid(),'baseVersion',1,'garmentIDs',jsonb_build_array('00000000-0000-0000-0000-000000000094'));
    PERFORM pg_temp.assert_wear(app.api_v1_save_outfit(outfit) ? 'data','edit outfit');
    PERFORM pg_temp.assert_wear((SELECT count(*) = 4 FROM app.wear_event_items),'outfit editing preserves historical membership');
    PERFORM pg_temp.assert_wear((SELECT count(DISTINCT w.worn_on) = 1 FROM app.wear_events w JOIN app.wear_event_items i ON i.wear_event_id=w.id
        WHERE i.garment_id='00000000-0000-0000-0000-000000000093'),'shared garment counts once');
    request := jsonb_set(request || jsonb_build_object('operationID',gen_random_uuid()),'{wear,version}','1');
    request := jsonb_set(jsonb_set(request,'{wear,wornOn}','"2026-01-02"'),'{wear,garmentIDs}',outfit->'garmentIDs');
    result := app.api_v1_save_wear(request);
    PERFORM pg_temp.assert_wear(result->'data'->>'version' = '2','edit advances version');
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(request) = result,'edit replay is exact');
    PERFORM pg_temp.assert_wear((SELECT count(*) = 2 FROM app.wear_events),'edit does not duplicate event');
    PERFORM pg_temp.assert_wear((SELECT count(*) = 3 FROM app.wear_event_items),'membership replaced atomically');
    PERFORM pg_temp.assert_wear((SELECT count(DISTINCT w.worn_on) = 1 FROM app.wear_events w JOIN app.wear_event_items i ON i.wear_event_id=w.id
        WHERE i.garment_id='00000000-0000-0000-0000-000000000093'),'other event retains shirt usage');
    PERFORM pg_temp.assert_wear((SELECT count(DISTINCT w.worn_on) = 2 FROM app.wear_events w JOIN app.wear_event_items i ON i.wear_event_id=w.id
        WHERE i.garment_id='00000000-0000-0000-0000-000000000094'),'shoe spans two days');
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(jsonb_set(request,'{wear,wornOn}','"2026-01-03"'))->'error'->>'code' = 'idempotency_conflict','changed replay rejected');
    invalid := request || jsonb_build_object('operationID',gen_random_uuid());
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(invalid)->'error'->>'code' = 'version_conflict','stale edit rejected');
    invalid := jsonb_set(invalid,'{wear,version}','2');
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(jsonb_set(invalid,'{wear,wornOn}','"2999-01-01"'))->'error'->>'code' = 'validation_failed','future edit rejected');
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(jsonb_set(invalid,'{wear,wornOn}','"2026-02-30"'))->'error'->>'code' = 'validation_failed','invalid day rejected');
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(jsonb_set(invalid,'{wear,garmentIDs}','["00000000-0000-0000-0000-000000000095"]'))->'error'->>'code' = 'validation_failed','foreign membership rejected');
    PERFORM pg_temp.assert_wear((SELECT version=2 AND worn_on='2026-01-02' AND timezone='Europe/Warsaw' FROM app.wear_events WHERE id=a),'rejections preserve event');
    PERFORM pg_temp.assert_wear((SELECT count(*) = 1 FROM app.wear_event_items WHERE wear_event_id=a),'rejections preserve items');
    PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000092',true);
    invalid := jsonb_set(invalid,'{wear,garmentIDs}','["00000000-0000-0000-0000-000000000095"]');
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(invalid)->'error'->>'code' = 'version_conflict','foreign event cannot be edited');
END $$;
RESET ROLE;
-- Fail after the event update and membership DELETE to prove the RPC's exception
-- boundary rolls back the entire write and its replay reservation.
CREATE FUNCTION pg_temp.reject_wear_item() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'injected item failure' USING ERRCODE = '23514'; END $$;
CREATE TRIGGER injected_item_failure BEFORE INSERT ON app.wear_event_items
FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_wear_item();
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000091',true);
DO $$ DECLARE request jsonb; before_state jsonb; BEGIN
    before_state := app.api_v1_sync_snapshot('{}')->'data'->'wears';
    SELECT jsonb_build_object('operationID',gen_random_uuid(),'wear',jsonb_build_object('id',id,'version',version,'deleted',false,
        'wornOn','2026-01-03','timezone','Europe/Warsaw','garmentIDs',jsonb_build_array('00000000-0000-0000-0000-000000000093')))
    INTO request FROM app.wear_events LIMIT 1;
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(request)->'error'->>'code' = 'validation_failed','injected item failure surfaced');
    PERFORM pg_temp.assert_wear(app.api_v1_sync_snapshot('{}')->'data'->'wears' = before_state,'event and membership rollback together');
END $$;
RESET ROLE;
DROP TRIGGER injected_item_failure ON app.wear_event_items;
UPDATE app.wear_events SET deleted_at=now();
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000091',true);
DO $$ DECLARE request jsonb; BEGIN
    SELECT jsonb_build_object('operationID',gen_random_uuid(),'wear',jsonb_build_object('id',id,'version',version,'deleted',false,
        'wornOn','2026-01-01','timezone','Europe/Warsaw','garmentIDs',jsonb_build_array('00000000-0000-0000-0000-000000000093')))
    INTO request FROM app.wear_events LIMIT 1;
    PERFORM pg_temp.assert_wear(app.api_v1_save_wear(request)->'error'->>'code' = 'version_conflict','tombstone cannot be revived');
END $$;
ROLLBACK;
