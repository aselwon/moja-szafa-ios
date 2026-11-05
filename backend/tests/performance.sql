-- Preliminary database-only benchmark, not the end-to-end API/launch/AI gate.
-- Run with psql -X -q -v ON_ERROR_STOP=1 in a migrated disposable database.
BEGIN;
SET LOCAL statement_timeout = '120s';
SET LOCAL lock_timeout = '5s';
DO $$ BEGIN
 IF current_database() NOT LIKE 'szafa_benchmark_%' THEN
  RAISE EXCEPTION 'Use a disposable szafa_benchmark_* database; never run on deployment databases';
 END IF;
 IF EXISTS (SELECT 1 FROM app.profiles) THEN
  RAISE EXCEPTION 'Benchmark requires an empty disposable database';
 END IF;
END $$;
INSERT INTO auth.users VALUES ('59000000-0000-0000-0000-000000000001');
INSERT INTO app.profiles(id,user_id) VALUES
 ('59000000-0000-0000-0000-000000000001','59000000-0000-0000-0000-000000000001');
INSERT INTO app.garments(id,user_id,name,category,price_grosz,purchased_on)
SELECT ('59000001-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 '59000000-0000-0000-0000-000000000001','Synthetic item '||lpad(n::text,4,'0'),
 (ARRAY['top','bottom','shoes','outerwear','accessory'])[1+(n-1)%5],1000+n,'2021-01-01'
FROM generate_series(1,1000) n;
-- Exactly five calendar years, including leap day: 1,826 events, five items/day.
INSERT INTO app.wear_events(id,user_id,worn_on,timezone,client_request_id)
SELECT ('59000002-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 '59000000-0000-0000-0000-000000000001',date '2021-01-01'+n-1,'Europe/Warsaw',
 ('59000003-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid
FROM generate_series(1,date '2026-01-01'-date '2021-01-01') n;
INSERT INTO app.wear_event_items(user_id,wear_event_id,garment_id)
SELECT e.user_id,e.id,('59000001-0000-0000-0000-'||
 lpad((1+((e.worn_on-date '2021-01-01')*5+k)%1000)::text,12,'0'))::uuid
FROM app.wear_events e CROSS JOIN generate_series(0,4) k;
ANALYZE app.garments;
ANALYZE app.wear_events;
ANALYZE app.wear_event_items;
CREATE TEMP TABLE benchmark_samples(operation text, iteration integer, elapsed_ms numeric, response_bytes integer);
GRANT INSERT,SELECT ON benchmark_samples TO authenticated;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '59000000-0000-0000-0000-000000000001';
DO $$ DECLARE
 n integer; op text; started timestamptz; response jsonb; duration numeric; bytes integer;
BEGIN
 IF (SELECT count(*) FROM app.garments)<>1000 OR
    (SELECT count(*) FROM app.wear_events)<>1826 OR
    (SELECT count(*) FROM app.wear_event_items)<>9130 THEN
  RAISE EXCEPTION 'Representative workload counts differ from specification';
 END IF;
 FOREACH op IN ARRAY ARRAY['wardrobe_first_page','wardrobe_last_page','garment_detail','sync_snapshot'] LOOP
  -- Five excluded warmups, then 100 samples. Includes function and JSON serialization.
  FOR n IN -4..100 LOOP
   started:=clock_timestamp();
   CASE op
    WHEN 'wardrobe_first_page' THEN response:=app.api_v1_browse_wardrobe('{"query":{"search":"","sort":"name","archived":false},"offset":0,"limit":40}');
    WHEN 'wardrobe_last_page' THEN response:=app.api_v1_browse_wardrobe('{"query":{"search":"","sort":"name","archived":false},"offset":960,"limit":40}');
    WHEN 'garment_detail' THEN response:=app.api_v1_garment_detail('{"id":"59000001-0000-0000-0000-000000000001"}');
    WHEN 'sync_snapshot' THEN response:=app.api_v1_sync_snapshot('{}');
   END CASE;
   bytes:=octet_length(response::text);
   duration:=extract(epoch FROM clock_timestamp()-started)*1000;
   IF response IS NULL OR NOT response ? 'data' OR response ? 'error' THEN
    RAISE EXCEPTION 'Benchmark operation % failed',op;
   END IF;
   IF op IN ('wardrobe_first_page','wardrobe_last_page') AND
      jsonb_array_length(response#>'{data,items}') IS DISTINCT FROM 40 THEN
    RAISE EXCEPTION 'Benchmark returned an incomplete wardrobe page';
   END IF;
   IF op='sync_snapshot' AND
      (jsonb_array_length(response#>'{data,garments}') IS DISTINCT FROM 1000 OR
       jsonb_array_length(response#>'{data,wears}') IS DISTINCT FROM 1826) THEN
    RAISE EXCEPTION 'Benchmark snapshot omitted workload data';
   END IF;
   IF n>0 THEN INSERT INTO benchmark_samples VALUES(op,n,duration,bytes); END IF;
  END LOOP;
 END LOOP;
END $$;
COPY (SELECT * FROM benchmark_samples ORDER BY operation,iteration) TO STDOUT WITH CSV HEADER;
-- All synthetic identities, data and temporary measurements are rolled back.
ROLLBACK;
