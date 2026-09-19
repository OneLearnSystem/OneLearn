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
