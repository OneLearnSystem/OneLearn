BEGIN;
CREATE TABLE IF NOT EXISTS public.ol_comms(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),kind text NOT NULL CHECK(kind IN ('post','component','incident')),data jsonb NOT NULL,revision integer NOT NULL DEFAULT 1,updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ol_comms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ol_comms FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.ol_comms_read(p_owner boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$BEGIN
IF p_owner AND NOT public.ol_owner() THEN RAISE EXCEPTION 'Platform owner access required.';END IF;
RETURN coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY updated_at DESC) FROM public.ol_comms c WHERE p_owner OR (c.data->>'published'='true' AND c.data->>'archived'='false')),'[]');END$$;
CREATE OR REPLACE FUNCTION public.ol_comms_save(p_kind text,p_data jsonb,p_id uuid DEFAULT NULL,p_revision integer DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$DECLARE r public.ol_comms;v text;BEGIN
IF NOT public.ol_owner() THEN RAISE EXCEPTION 'Platform owner access required.';END IF;
IF p_kind NOT IN ('post','component','incident') OR jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR octet_length(p_data::text)>1600000 THEN RAISE EXCEPTION 'Invalid content.';END IF;
IF coalesce(length(trim(p_data->>'title')),0) NOT BETWEEN 1 AND 160 OR length(coalesce(p_data->>'body',''))>20000 THEN RAISE EXCEPTION 'Add a title up to 160 characters and body up to 20,000 characters.';END IF;
IF jsonb_typeof(p_data->'published') IS DISTINCT FROM 'boolean' OR jsonb_typeof(p_data->'archived') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Choose publication state.';END IF;
IF p_kind IN ('component','incident') AND coalesce(p_data->>'service','') NOT IN ('OneLearn','OneBlog','OneStatus','OneEducation','OneHome','OneSixth','OneNursery','OnePrimary') THEN RAISE EXCEPTION 'Choose a service.';END IF;
IF p_kind='component' AND coalesce(p_data->>'status','') NOT IN ('unknown','operational','degraded','partial','downtime','maintenance','planned') THEN RAISE EXCEPTION 'Choose a component status.';END IF;
IF p_kind='incident' THEN
 IF coalesce(p_data->>'stage','') NOT IN ('Investigating','Identified','Monitoring','Resolved','Scheduled maintenance') THEN RAISE EXCEPTION 'Choose an incident stage.';END IF;
 IF jsonb_typeof(p_data->'components') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Choose affected components.';END IF;
 FOR v IN SELECT jsonb_array_elements_text(p_data->'components') LOOP
 IF NOT EXISTS(SELECT 1 FROM public.ol_comms WHERE id::text=v AND kind='component' AND data->>'service'=p_data->>'service') THEN RAISE EXCEPTION 'Component must belong to the incident service.';END IF;END LOOP;
 IF nullif(p_data->>'end','') IS NOT NULL AND (nullif(p_data->>'start','') IS NULL OR (p_data->>'end')::timestamptz<=(p_data->>'start')::timestamptz) THEN RAISE EXCEPTION 'End must follow start.';END IF;
 IF nullif(p_data->>'start','') IS NOT NULL THEN PERFORM (p_data->>'start')::timestamptz;END IF;
END IF;
IF nullif(p_data->>'image','') IS NOT NULL AND (p_kind<>'post' OR p_data->>'image' !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$') THEN RAISE EXCEPTION 'Use a PNG, JPEG or WebP image.';END IF;
IF p_id IS NULL THEN INSERT INTO public.ol_comms(kind,data) VALUES(p_kind,p_data) RETURNING * INTO r;
ELSE UPDATE public.ol_comms SET data=p_data,revision=revision+1,updated_at=now() WHERE id=p_id AND kind=p_kind AND revision=p_revision RETURNING * INTO r;IF NOT FOUND THEN RAISE EXCEPTION 'Content changed elsewhere. Refresh before editing.';END IF;END IF;
INSERT INTO public.ol_events(actor,action) VALUES(auth.uid(),'Saved OneLearn '||p_kind||': '||(p_data->>'title'));
RETURN to_jsonb(r);END$$;
REVOKE ALL ON FUNCTION public.ol_comms_read(boolean),public.ol_comms_save(text,jsonb,uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ol_comms_read(boolean) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ol_comms_save(text,jsonb,uuid,integer) TO authenticated;
DO $$DECLARE service text;component text;BEGIN
FOREACH service IN ARRAY ARRAY['OneLearn','OneBlog','OneStatus','OneEducation','OneHome','OneSixth','OneNursery','OnePrimary'] LOOP
FOREACH component IN ARRAY ARRAY['Website','Sign-in & access','Core features'] LOOP
IF NOT EXISTS(SELECT 1 FROM public.ol_comms WHERE kind='component' AND data->>'service'=service AND data->>'title'=component) THEN
INSERT INTO public.ol_comms(kind,data) VALUES('component',jsonb_build_object('service',service,'title',component,'body','','status',CASE WHEN service IN ('OneNursery','OnePrimary') THEN 'planned' ELSE 'unknown' END,'published',true,'archived',false));
END IF;END LOOP;END LOOP;END$$;
-- Permit requests for the new product names without deleting historical OneWeb requests/data.
DO $$DECLARE src text;BEGIN
src:=pg_get_functiondef('public.ol_contact(text,text,text,text[],boolean)'::regprocedure);
src:=replace(src,'''OneWeb''','''OneNursery'',''OnePrimary''');EXECUTE src;
END$$;
NOTIFY pgrst,'reload schema';
COMMIT;

BEGIN;
-- Keep the old validator private and extend it without changing stored posts/incidents.
DO $$DECLARE src text;BEGIN
IF to_regprocedure('public.ol_comms_save_before_easy(text,jsonb,uuid,integer)') IS NULL THEN
 ALTER FUNCTION public.ol_comms_save(text,jsonb,uuid,integer) RENAME TO ol_comms_save_before_easy;
END IF;
src:=pg_get_functiondef('public.ol_comms_save_before_easy(text,jsonb,uuid,integer)'::regprocedure);
src:=replace(src,'''downtime'',''maintenance'',''planned''','''downtime'',''maintenance'',''updating'',''planned''');
src:=replace(src,'''Resolved'',''Scheduled maintenance''','''Resolved'',''Scheduled maintenance'',''Update in progress''');
src:=replace(src,' AND data->>''service''=p_data->>''service''','');
EXECUTE src;
END$$;
REVOKE ALL ON FUNCTION public.ol_comms_save_before_easy(text,jsonb,uuid,integer) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.ol_comms_save(p_kind text,p_data jsonb,p_id uuid DEFAULT NULL,p_revision integer DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v text;BEGIN
IF NOT public.ol_owner() THEN RAISE EXCEPTION 'Platform owner access required.';END IF;
PERFORM pg_advisory_xact_lock(81572839);
IF p_kind='component' THEN
 p_data:=p_data-'manualStatus';
 IF p_data->>'archived'<>'true' AND EXISTS(SELECT 1 FROM public.ol_comms c WHERE c.kind='component' AND c.id IS DISTINCT FROM p_id AND c.data->>'archived'='false' AND lower(trim(c.data->>'title'))=lower(trim(p_data->>'title')) AND c.data->>'service'=p_data->>'service') THEN RAISE EXCEPTION 'That component already exists. Use Report issue or edit the existing component.';END IF;
END IF;
IF p_kind='incident' THEN
 IF jsonb_typeof(p_data->'components') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data->'components') NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Select at least one existing component.';END IF;
 IF coalesce(p_data->>'impact','') NOT IN ('degraded','partial','downtime','maintenance','updating') THEN RAISE EXCEPTION 'Choose the status this report should apply.';END IF;
 FOR v IN SELECT jsonb_array_elements_text(p_data->'components') LOOP
 IF NOT EXISTS(SELECT 1 FROM public.ol_comms WHERE id::text=v AND kind='component' AND ((data->>'archived'='false' AND data->>'published'='true') OR (p_id IS NOT NULL AND (p_data->>'stage'='Resolved' OR p_data->>'archived'='true')))) THEN RAISE EXCEPTION 'Choose an existing published component. No component is created by an incident.';END IF;END LOOP;
END IF;
RETURN public.ol_comms_save_before_easy(p_kind,p_data,p_id,p_revision);
END$$;

CREATE OR REPLACE FUNCTION public.ol_comms_read(p_owner boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.ol_comms; status text; result jsonb:='[]'::jsonb; d jsonb;
BEGIN
IF p_owner AND NOT public.ol_owner() THEN RAISE EXCEPTION 'Platform owner access required.';END IF;
FOR c IN SELECT * FROM public.ol_comms WHERE p_owner OR (data->>'published'='true' AND data->>'archived'='false') ORDER BY updated_at DESC LOOP
 d:=c.data;
 IF c.kind='component' THEN
  SELECT x.s INTO status FROM (
   SELECT coalesce(c.data->>'status','unknown') AS s
   UNION ALL
   SELECT coalesce(i.data->>'impact',CASE WHEN i.data->>'stage'='Scheduled maintenance' THEN 'maintenance' WHEN i.data->>'stage'='Update in progress' THEN 'updating' ELSE 'degraded' END)
   FROM public.ol_comms i WHERE i.kind='incident' AND i.data->>'published'='true' AND i.data->>'archived'='false' AND i.data->>'stage'<>'Resolved'
   AND ((i.data->'components') ? c.id::text OR (i.data->'components'='[]'::jsonb AND i.data->>'service'=c.data->>'service'))
  ) x ORDER BY CASE x.s WHEN 'downtime' THEN 7 WHEN 'partial' THEN 6 WHEN 'degraded' THEN 5 WHEN 'maintenance' THEN 4 WHEN 'updating' THEN 3 WHEN 'unknown' THEN 2 WHEN 'planned' THEN 1 ELSE 0 END DESC LIMIT 1;
  d:=jsonb_set(d,'{status}',to_jsonb(status));
  IF p_owner THEN d:=d||jsonb_build_object('manualStatus',c.data->>'status');END IF;
 END IF;
 result:=result||jsonb_build_array(to_jsonb(c)||jsonb_build_object('data',d));
END LOOP;
RETURN result;
END$$;
REVOKE ALL ON FUNCTION public.ol_comms_save(text,jsonb,uuid,integer),public.ol_comms_read(boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ol_comms_save(text,jsonb,uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ol_comms_read(boolean) TO anon,authenticated;
-- Availability in the catalogue does not imply measured uptime; do not reset manual component states.
UPDATE public.ol_comms SET data=jsonb_set(data,'{status}','"unknown"'::jsonb),revision=revision+1,updated_at=now() WHERE kind='component' AND data->>'service' IN ('OnePrimary','OneNursery') AND data->>'status'='planned';
DO $$DECLARE src text;BEGIN
src:=pg_get_functiondef('public.ol_contact(text,text,text,text[],boolean)'::regprocedure);
src:=replace(src,'NOT BETWEEN 1 AND 4','NOT BETWEEN 1 AND 5');EXECUTE src;
END$$;
NOTIFY pgrst,'reload schema';
COMMIT;
