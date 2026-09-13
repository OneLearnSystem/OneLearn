BEGIN;
-- Run only in a NEW Supabase project. The installer supplies private app templates.
DO $$ BEGIN IF to_regclass('public.oe_workspace') IS NOT NULL THEN RAISE EXCEPTION 'Use a NEW Supabase project, not the existing Westview MIS database.';END IF;END$$;
CREATE TABLE IF NOT EXISTS public.ol_owners(email text PRIMARY KEY);
INSERT INTO public.ol_owners VALUES('masonsandersbussiness@gmail.com') ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS public.ol_schools(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),slug text NOT NULL UNIQUE CHECK(slug ~ '^[a-z0-9][a-z0-9-]{2,47}$'),name text NOT NULL,settings jsonb NOT NULL DEFAULT '{}',active boolean NOT NULL DEFAULT true,created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.ol_members(school_id uuid REFERENCES public.ol_schools(id),user_id uuid REFERENCES auth.users(id),role text CHECK(role IN ('admin','teacher')),PRIMARY KEY(school_id,user_id));
CREATE TABLE IF NOT EXISTS public.ol_requests(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),email text NOT NULL,school text NOT NULL,message text NOT NULL,products text[] NOT NULL,official boolean NOT NULL DEFAULT false,created_at timestamptz DEFAULT now(),status text NOT NULL DEFAULT 'new');
CREATE TABLE IF NOT EXISTS public.ol_invites(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),school_id uuid NOT NULL REFERENCES public.ol_schools(id),email text NOT NULL,role text NOT NULL CHECK(role IN ('admin','teacher')),code_hash text UNIQUE NOT NULL,expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days',used_at timestamptz,created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.ol_templates(id integer PRIMARY KEY,body text NOT NULL);
CREATE TABLE IF NOT EXISTS public.ol_sites(school_id uuid PRIMARY KEY REFERENCES public.ol_schools(id),draft jsonb NOT NULL DEFAULT '{}',published jsonb,revision integer NOT NULL DEFAULT 0,published_at timestamptz);
CREATE TABLE IF NOT EXISTS public.ol_events(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,actor uuid,school_id uuid,action text,created_at timestamptz DEFAULT now());
DO $$DECLARE t text;BEGIN FOREACH t IN ARRAY ARRAY['ol_owners','ol_schools','ol_members','ol_requests','ol_invites','ol_templates','ol_sites','ol_events'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);END LOOP;END$$;
CREATE OR REPLACE FUNCTION public.ol_owner() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT EXISTS(SELECT 1 FROM auth.users u JOIN public.ol_owners o ON o.email=lower(u.email) WHERE u.id=auth.uid() AND u.email_confirmed_at IS NOT NULL) $$;
CREATE OR REPLACE FUNCTION public.ol_role(p_school uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT m.role FROM public.ol_members m JOIN auth.users u ON u.id=m.user_id JOIN public.ol_schools s ON s.id=m.school_id WHERE m.school_id=p_school AND m.user_id=auth.uid() AND u.email_confirmed_at IS NOT NULL AND s.active $$;
CREATE OR REPLACE FUNCTION public.ol_school(p_slug text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT jsonb_build_object('id',id,'slug',slug,'name',name,'settings',settings) FROM public.ol_schools WHERE slug=p_slug AND active $$;
CREATE OR REPLACE FUNCTION public.ol_me() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT jsonb_build_object('owner',public.ol_owner(),'schools',coalesce((SELECT jsonb_agg(jsonb_build_object('id',s.id,'slug',s.slug,'name',s.name,'role',m.role)) FROM public.ol_members m JOIN public.ol_schools s ON s.id=m.school_id WHERE m.user_id=auth.uid() AND s.active),'[]'::jsonb)) $$;
CREATE OR REPLACE FUNCTION public.ol_contact(p_email text,p_school text,p_message text,p_products text[],p_official boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
IF p_email IS NULL OR p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' OR length(p_email)>254 OR coalesce(length(trim(p_school)),0) NOT BETWEEN 2 AND 160 OR coalesce(length(trim(p_message)),0) NOT BETWEEN 10 AND 3000 OR p_products IS NULL OR cardinality(p_products) NOT BETWEEN 1 AND 4 OR NOT p_products <@ ARRAY['OneEducation','OneHome','OneWeb','OneSixth'] THEN RAISE EXCEPTION 'Check your email, school, products and message (10–3000 characters).';END IF;
PERFORM pg_advisory_xact_lock(hashtextextended(lower(trim(p_email)),11));
IF EXISTS(SELECT 1 FROM public.ol_requests WHERE email=lower(trim(p_email)) AND created_at>now()-interval '1 day') THEN RAISE EXCEPTION 'A request for this email was already received today.';END IF;
INSERT INTO public.ol_requests(email,school,message,products,official) VALUES(lower(trim(p_email)),trim(p_school),trim(p_message),p_products,coalesce(p_official,false));
END$$;
CREATE OR REPLACE FUNCTION public.ol_dashboard() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN IF NOT public.ol_owner() THEN RAISE EXCEPTION 'Owner access required.';END IF; RETURN jsonb_build_object('requests',coalesce((SELECT jsonb_agg(r ORDER BY created_at DESC) FROM public.ol_requests r),'[]'::jsonb),'schools',coalesce((SELECT jsonb_agg(s ORDER BY created_at DESC) FROM public.ol_schools s),'[]'::jsonb),'invites',coalesce((SELECT jsonb_agg(to_jsonb(i)-'code_hash' ORDER BY created_at DESC) FROM public.ol_invites i),'[]'::jsonb));END$$;
CREATE OR REPLACE FUNCTION public.ol_issue(p_school uuid,p_email text,p_role text DEFAULT 'admin') RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ DECLARE c text:=replace(gen_random_uuid()::text,'-',''); BEGIN
IF NOT public.ol_owner() AND public.ol_role(p_school) IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required.';END IF;
IF p_role IS NULL OR p_role NOT IN ('admin','teacher') OR p_email IS NULL OR p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' OR length(p_email)>254 THEN RAISE EXCEPTION 'Enter a valid email and role.';END IF;
UPDATE public.ol_invites SET expires_at=now() WHERE school_id=p_school AND email=lower(trim(p_email)) AND used_at IS NULL;
INSERT INTO public.ol_invites(school_id,email,role,code_hash) VALUES(p_school,lower(trim(p_email)),p_role,encode(sha256(convert_to(c,'UTF8')),'hex'));
INSERT INTO public.ol_events(actor,school_id,action) VALUES(auth.uid(),p_school,'Invitation issued to '||lower(trim(p_email)));
RETURN c;END$$;
CREATE OR REPLACE FUNCTION public.ol_redeem(p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ DECLARE i public.ol_invites; e text; ns text; BEGIN
SELECT lower(email) INTO e FROM auth.users WHERE id=auth.uid() AND email_confirmed_at IS NOT NULL;IF e IS NULL THEN RAISE EXCEPTION 'Verify your email and sign in before redeeming your invitation.';END IF;
SELECT * INTO i FROM public.ol_invites WHERE code_hash=encode(sha256(convert_to(lower(trim(p_code)),'UTF8')),'hex') AND email=e AND used_at IS NULL AND expires_at>now() FOR UPDATE;
IF i.id IS NULL OR NOT EXISTS(SELECT 1 FROM public.ol_schools WHERE id=i.school_id AND active) THEN RAISE EXCEPTION 'Invitation is invalid, expired or belongs to another email.';END IF;
INSERT INTO public.ol_members VALUES(i.school_id,auth.uid(),i.role) ON CONFLICT(school_id,user_id) DO UPDATE SET role=excluded.role;
ns:='school_'||replace(i.school_id::text,'-','');EXECUTE format('INSERT INTO %I.oe_staff_access VALUES($1,$2) ON CONFLICT(email) DO UPDATE SET role=excluded.role',ns) USING e,i.role;
UPDATE public.ol_invites SET used_at=now() WHERE id=i.id;
INSERT INTO public.ol_events(actor,school_id,action) VALUES(auth.uid(),i.school_id,'Invitation redeemed');RETURN public.ol_me();END$$;
CREATE OR REPLACE FUNCTION public.ol_provision(p_slug text,p_name text,p_email text,p_request uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ DECLARE sid uuid;ns text;src text;c text;BEGIN
IF NOT public.ol_owner() THEN RAISE EXCEPTION 'Owner access required.';END IF;
IF coalesce(length(trim(p_name)),0) NOT BETWEEN 2 AND 160 THEN RAISE EXCEPTION 'Enter a school name.';END IF;
INSERT INTO public.ol_schools(slug,name) VALUES(lower(trim(p_slug)),trim(p_name)) RETURNING id INTO sid;
ns:='school_'||replace(sid::text,'-','');EXECUTE format('CREATE SCHEMA %I',ns);
SELECT body INTO src FROM public.ol_templates WHERE id=1;IF src IS NULL THEN RAISE EXCEPTION 'App templates have not been installed.';END IF;
EXECUTE replace(src,'__SCHOOL__',ns);
EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC,anon,authenticated',ns);
EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC,anon,authenticated',ns);
EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC,anon,authenticated',ns);
EXECUTE format('UPDATE %I.oe_workspace SET data=jsonb_set(data,''{school,name}'',to_jsonb($1::text)) WHERE id=1',ns) USING trim(p_name);
EXECUTE format('UPDATE %I.ss_settings SET school_name=$1 WHERE id=1',ns) USING trim(p_name)||' Sixth Form';
INSERT INTO public.ol_sites(school_id) VALUES(sid);
c:=public.ol_issue(sid,p_email,'admin');
UPDATE public.ol_requests SET status='approved' WHERE id=p_request;
INSERT INTO public.ol_events(actor,school_id,action) VALUES(auth.uid(),sid,'School provisioned');
RETURN jsonb_build_object('id',sid,'slug',p_slug,'code',c,'email',p_email);END$$;
CREATE OR REPLACE FUNCTION public.ol_call(p_slug text,p_method text,p_args jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s public.ol_schools;ns text;f record; a text; typ text;parts text[]:='{}';i integer;result jsonb;student_call boolean;
BEGIN
SELECT * INTO s FROM public.ol_schools WHERE slug=p_slug AND active;IF s.id IS NULL THEN RAISE EXCEPTION 'School is unavailable.';END IF;
IF jsonb_typeof(p_args) IS DISTINCT FROM 'object' OR octet_length(p_args::text)>16000000 THEN RAISE EXCEPTION 'Invalid request.';END IF;
student_call:=p_method=ANY(ARRAY['oe_student_portal','oe_hub_student_action','oh_student','oh_open','oh_save','ss_student','ss_choose']);
IF NOT student_call AND public.ol_role(s.id) IS NULL THEN RAISE EXCEPTION 'You do not have access to this school.';END IF;
IF NOT p_method=ANY(ARRAY['oe_role','oe_get_state','oe_save_state','oe_student_portal','oe_staff_list','oe_audit_log','oe_hub_staff','oe_hub_settings_save','oe_hub_item_save','oe_hub_review','oe_hub_staff_ticket','oe_hub_student_action','oh_staff','oh_create','oh_archive','oh_student','oh_open','oh_save','ss_staff','ss_import','ss_edit_student','ss_rotate','ss_notice','ss_register','ss_settings_save','ss_student','ss_choose']) THEN RAISE EXCEPTION 'This operation is not available. Manage staff through School setup.';END IF;
ns:='school_'||replace(s.id::text,'-','');SELECT p.* INTO f FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=ns AND p.proname=p_method;
IF f.oid IS NULL THEN RAISE EXCEPTION 'App operation not installed.';END IF;
IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_args) k WHERE NOT k=ANY(coalesce(f.proargnames,'{}'))) THEN RAISE EXCEPTION 'Unexpected argument.';END IF;
FOR i IN 1..f.pronargs LOOP
a:=f.proargnames[i];typ:=pg_catalog.format_type(f.proargtypes[i-1],NULL);
IF NOT p_args ? a THEN IF i<=f.pronargs-f.pronargdefaults THEN RAISE EXCEPTION 'Missing argument: %',a;END IF;CONTINUE;END IF;
IF typ='jsonb' THEN parts:=array_append(parts,format('%I => ($1->%L)',a,a));
ELSIF typ='text[]' THEN parts:=array_append(parts,format('%I => CASE WHEN $1->%L=''null''::jsonb THEN NULL ELSE ARRAY(SELECT jsonb_array_elements_text($1->%L)) END',a,a,a));
ELSIF typ=ANY(ARRAY['text','integer','bigint','boolean','uuid','date','timestamp with time zone']) THEN parts:=array_append(parts,format('%I => ($1->>%L)::%s',a,a,typ));
ELSE RAISE EXCEPTION 'Unsupported argument type.';END IF;
END LOOP;
EXECUTE format('SELECT to_jsonb(%I.%I(%s))',ns,p_method,array_to_string(parts,',')) INTO result USING p_args;RETURN result;
END$$;
CREATE OR REPLACE FUNCTION public.ol_settings(p_slug text,p_settings jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ DECLARE s public.ol_schools;ns text;BEGIN
SELECT * INTO s FROM public.ol_schools WHERE slug=p_slug AND active;
IF public.ol_role(s.id) IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'School administrator access required.';END IF;
IF jsonb_typeof(p_settings) IS DISTINCT FROM 'object' OR octet_length(p_settings::text)>3000000 OR coalesce(length(trim(p_settings->>'name')),0) NOT BETWEEN 2 AND 160 OR coalesce(p_settings->>'colour','#17695c') !~ '^#[0-9A-Fa-f]{6}$' THEN RAISE EXCEPTION 'Check the school name, colour and logo size.';END IF;
UPDATE public.ol_schools SET name=p_settings->>'name',settings=p_settings WHERE id=s.id;
ns:='school_'||replace(s.id::text,'-','');EXECUTE format('UPDATE %I.oe_workspace SET data=jsonb_set(data,''{school,name}'',to_jsonb($1::text)),revision=revision+1 WHERE id=1',ns) USING p_settings->>'name';
EXECUTE format('UPDATE %I.ss_settings SET school_name=$1 WHERE id=1',ns) USING coalesce(nullif(p_settings->>'sixthName',''),p_settings->>'name');
END$$;
CREATE OR REPLACE FUNCTION public.ol_site(p_slug text,p_action text,p_data jsonb DEFAULT NULL,p_revision integer DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ DECLARE s public.ol_schools;v public.ol_sites;BEGIN
SELECT * INTO s FROM public.ol_schools WHERE slug=p_slug AND active;IF s.id IS NULL THEN RETURN NULL;END IF;
IF p_action='public' THEN SELECT * INTO v FROM public.ol_sites WHERE school_id=s.id;RETURN v.published;END IF;
IF public.ol_role(s.id) IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'School administrator access required.';END IF;
SELECT * INTO v FROM public.ol_sites WHERE school_id=s.id FOR UPDATE;
IF p_action IN ('save','publish','unpublish') THEN
IF p_revision IS DISTINCT FROM v.revision THEN RAISE EXCEPTION 'Another editor saved changes. Reload the builder first.';END IF;
IF p_action IN ('save','publish') AND (jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR octet_length(p_data::text)>12000000 OR jsonb_typeof(p_data->'pages') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data->'pages') NOT BETWEEN 1 AND 30) THEN RAISE EXCEPTION 'Add 1–30 pages. Keep the website below 12 MB.';END IF;
UPDATE public.ol_sites SET draft=CASE WHEN p_action='unpublish' THEN draft ELSE p_data END,published=CASE WHEN p_action='publish' THEN p_data WHEN p_action='unpublish' THEN NULL ELSE published END,published_at=CASE WHEN p_action='publish' THEN now() ELSE published_at END,revision=revision+1 WHERE school_id=s.id RETURNING * INTO v;
INSERT INTO public.ol_events(actor,school_id,action) VALUES(auth.uid(),s.id,'Website '||p_action);
ELSIF p_action<>'get' THEN RAISE EXCEPTION 'Unknown website action.';END IF;
RETURN to_jsonb(v);END$$;
CREATE OR REPLACE FUNCTION public.ol_school_active(p_id uuid,p_active boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN IF NOT public.ol_owner() THEN RAISE EXCEPTION 'Owner access required.';END IF;UPDATE public.ol_schools SET active=p_active WHERE id=p_id;INSERT INTO public.ol_events(actor,school_id,action) VALUES(auth.uid(),p_id,'School active: '||p_active);END$$;
CREATE OR REPLACE FUNCTION public.ol_remove_member(p_school uuid,p_user uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ DECLARE e text;ns text;BEGIN IF public.ol_role(p_school) IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'School administrator access required.';END IF;IF p_user=auth.uid() THEN RAISE EXCEPTION 'You cannot remove your own access.';END IF;SELECT email INTO e FROM auth.users WHERE id=p_user;DELETE FROM public.ol_members WHERE school_id=p_school AND user_id=p_user;ns:='school_'||replace(p_school::text,'-','');EXECUTE format('DELETE FROM %I.oe_staff_access WHERE email=lower($1)',ns) USING e;UPDATE public.ol_invites SET expires_at=now() WHERE school_id=p_school AND email=lower(e) AND used_at IS NULL;END$$;
CREATE OR REPLACE FUNCTION public.ol_staff(p_school uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN IF public.ol_role(p_school) IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'School administrator access required.';END IF;RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',u.id,'email',u.email,'role',m.role)) FROM public.ol_members m JOIN auth.users u ON u.id=m.user_id WHERE m.school_id=p_school),'[]'::jsonb);END$$;
-- All internal helpers and templates remain private; only these checked entry points are public.
REVOKE ALL ON FUNCTION public.ol_owner(),public.ol_role(uuid),public.ol_school(text),public.ol_me(),public.ol_contact(text,text,text,text[],boolean),public.ol_dashboard(),public.ol_issue(uuid,text,text),public.ol_redeem(text),public.ol_provision(text,text,text,uuid),public.ol_call(text,text,jsonb),public.ol_settings(text,jsonb),public.ol_site(text,text,jsonb,integer),public.ol_school_active(uuid,boolean),public.ol_remove_member(uuid,uuid),public.ol_staff(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ol_school(text),public.ol_contact(text,text,text,text[],boolean),public.ol_call(text,text,jsonb),public.ol_site(text,text,jsonb,integer) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ol_me(),public.ol_dashboard(),public.ol_issue(uuid,text,text),public.ol_redeem(text),public.ol_provision(text,text,text,uuid),public.ol_settings(text,jsonb),public.ol_school_active(uuid,boolean),public.ol_remove_member(uuid,uuid),public.ol_staff(uuid) TO authenticated;

INSERT INTO public.ol_templates(id,body) VALUES(1,$template$-- OneEducation MIS: run this whole file in the NEW Supabase project's SQL Editor.
-- Project: naxoplmtweovwaiwvexe. It does not use or modify your website project.

CREATE TABLE IF NOT EXISTS __SCHOOL__.oe_staff_access (
 email text PRIMARY KEY CHECK (email=lower(email)),
 role text NOT NULL CHECK (role IN ('admin','teacher'))
);

CREATE TABLE IF NOT EXISTS __SCHOOL__.oe_workspace (
 id integer PRIMARY KEY DEFAULT 1 CHECK(id=1),
 data jsonb,
 revision bigint NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO __SCHOOL__.oe_workspace(id) VALUES(1) ON CONFLICT(id) DO NOTHING;
CREATE TABLE IF NOT EXISTS __SCHOOL__.oe_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 actor uuid,
 email text,
 action text NOT NULL,
 revision bigint,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE __SCHOOL__.oe_staff_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.oe_workspace ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.oe_audit ENABLE ROW LEVEL SECURITY;
-- No browser role has direct access. Only the checked functions below expose data.
REVOKE ALL ON __SCHOOL__.oe_staff_access,__SCHOOL__.oe_workspace,__SCHOOL__.oe_audit FROM anon,authenticated;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT a.role FROM __SCHOOL__.oe_staff_access a
 JOIN auth.users u ON u.id=auth.uid() AND lower(u.email)=a.email
 WHERE u.email_confirmed_at IS NOT NULL
 LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_get_state() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r text; d jsonb; rev bigint;
BEGIN
 r:=__SCHOOL__.oe_role(); IF r IS NULL THEN RAISE EXCEPTION 'This verified account is not on the OneEducation staff list.'; END IF;
 SELECT data,revision INTO d,rev FROM __SCHOOL__.oe_workspace WHERE id=1;
 IF r='teacher' AND d IS NOT NULL THEN
  d:=jsonb_set(d,'{students}',COALESCE((SELECT jsonb_agg(p-'loginCode') FROM jsonb_array_elements(d->'students') p),'[]'::jsonb));
 END IF;
 RETURN jsonb_build_object('data',d,'revision',rev,'role',r);
END; $$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_save_state(p_data jsonb,p_revision bigint,p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r text; old jsonb; rev bigint; nextdata jsonb; k text; item jsonb; pupil jsonb; duplicates integer;
BEGIN
 r:=__SCHOOL__.oe_role(); IF r IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
 SELECT data,revision INTO old,rev FROM __SCHOOL__.oe_workspace WHERE id=1 FOR UPDATE;
 IF rev IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'REVISION_CONFLICT: another person saved changes. Refresh before trying again.'; END IF;
 IF jsonb_typeof(p_data)<>'object' OR octet_length(p_data::text)>15000000 THEN RAISE EXCEPTION 'Invalid or oversized school workspace.'; END IF;
 IF r='teacher' THEN
  IF old IS NULL THEN RAISE EXCEPTION 'An administrator must initialise the school.'; END IF;
  nextdata:=old;
  FOREACH k IN ARRAY ARRAY['attendance','points','incidents','removals','announcements','covers'] LOOP
   nextdata:=jsonb_set(nextdata,ARRAY[k],COALESCE(p_data->k,'[]'::jsonb));
  END LOOP;
 ELSE nextdata:=p_data;
 END IF;
 FOREACH k IN ARRAY ARRAY['students','tutors','classes','teachers','rooms','houses','attendance','points','incidents','removals','announcements','covers','closures','cycles','exams'] LOOP
  IF jsonb_typeof(nextdata->k) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid workspace array: %',k; END IF;
 END LOOP;
 IF COALESCE(nextdata#>>'{school,status}','') NOT IN ('open','closing','closed') THEN RAISE EXCEPTION 'Choose open, closing or closed.'; END IF;
 -- Unique credentials and pupil identifiers, never readable by anonymous users.
 SELECT count(*)-count(DISTINCT p->>'id') INTO duplicates FROM jsonb_array_elements(nextdata->'students') p;
 IF duplicates>0 THEN RAISE EXCEPTION 'Duplicate pupil identifier.'; END IF;
 SELECT count(*)-count(DISTINCT p->>'loginCode') INTO duplicates FROM jsonb_array_elements(nextdata->'students') p;
 IF duplicates>0 THEN RAISE EXCEPTION 'Duplicate student login code.'; END IF;
 SELECT count(*)-count(DISTINCT p->>'candidateNumber') INTO duplicates FROM jsonb_array_elements(nextdata->'students') p;
 IF duplicates>0 THEN RAISE EXCEPTION 'Duplicate candidate number.'; END IF;
 FOR pupil IN SELECT value FROM jsonb_array_elements(nextdata->'students') LOOP
  IF COALESCE(pupil->>'loginCode','') !~ '^[A-F0-9]{8}(-[A-F0-9]{8}){3}$' OR COALESCE(pupil->>'candidateNumber','') !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'Invalid student codes.'; END IF;
  IF (pupil->>'year')::int NOT BETWEEN 7 AND 11 THEN RAISE EXCEPTION 'Invalid year group.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(nextdata->'tutors') t WHERE t->>'id'=pupil->>'tutorId' AND t->>'year'=pupil->>'year') THEN RAISE EXCEPTION 'Pupil tutor group must match their year.'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(pupil->'classIds') cid WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(nextdata->'classes') c WHERE c->>'id'=cid AND c->>'year'=pupil->>'year')) THEN RAISE EXCEPTION 'Pupil class must belong to their year.'; END IF;
 END LOOP;
 -- The closure rule is enforced in the database, even if somebody bypasses the UI.
 FOR item IN SELECT value FROM jsonb_array_elements(nextdata->'attendance') LOOP
  IF NOT COALESCE(old->'attendance','[]'::jsonb) @> jsonb_build_array(item) THEN
   IF nextdata#>>'{school,status}'<>'open' OR EXISTS (SELECT 1 FROM jsonb_array_elements(nextdata->'closures') c WHERE item->>'date' BETWEEN c->>'start' AND c->>'end' AND c->>'status'<>'open') THEN RAISE EXCEPTION 'Attendance is locked while school is closed or closing.'; END IF;
   IF COALESCE(item->>'mark','') NOT IN ('present','absent','late','ill','authorised','medical','removed') OR (item->>'period')::int NOT BETWEEN 0 AND 5 THEN RAISE EXCEPTION 'Invalid attendance mark.'; END IF;
   IF extract(isodow FROM (item->>'date')::date)>5 THEN RAISE EXCEPTION 'No attendance registers at weekends.'; END IF;
   IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(nextdata->'students') p WHERE p->>'id'=item->>'studentId' AND ((p->'classIds') ? (item->>'classId') OR (p->>'tutorId'=item->>'classId' AND item->>'period'='0'))) THEN RAISE EXCEPTION 'Pupil does not belong to this register.'; END IF;
  END IF;
 END LOOP;
 UPDATE __SCHOOL__.oe_workspace SET data=nextdata,revision=revision+1,updated_at=now() WHERE id=1;
 INSERT INTO __SCHOOL__.oe_audit(actor,email,action,revision) VALUES(auth.uid(),auth.jwt()->>'email',left(COALESCE(p_action,'Saved changes'),300),rev+1);
 RETURN __SCHOOL__.oe_get_state();
END; $$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_student_portal(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d jsonb; p jsonb; code text; courses jsonb; notices jsonb;
BEGIN
 code:=upper(regexp_replace(COALESCE(p_code,''),'[-[:space:]]','','g'));
 IF length(code)<>32 OR code !~ '^[A-F0-9]{32}$' THEN RAISE EXCEPTION 'That login code was not recognised.'; END IF;
 SELECT data INTO d FROM __SCHOOL__.oe_workspace WHERE id=1;
 SELECT value INTO p FROM jsonb_array_elements(COALESCE(d->'students','[]'::jsonb))
 WHERE replace(value->>'loginCode','-','')=code AND COALESCE((value->>'archived')::boolean,false)=false LIMIT 1;
 IF p IS NULL THEN RAISE EXCEPTION 'That login code was not recognised.'; END IF;
 SELECT COALESCE(jsonb_agg(c),'[]'::jsonb) INTO courses FROM jsonb_array_elements(d->'classes') c WHERE (p->'classIds') ? (c->>'id');
 SELECT COALESCE(jsonb_agg(n),'[]'::jsonb) INTO notices FROM jsonb_array_elements(d->'announcements') n WHERE n->>'scope'='school' OR (n->>'scope'='tutor' AND n->>'groupId'=p->>'tutorId') OR (n->>'scope'='class' AND (p->'classIds') ? (n->>'groupId'));
 -- Return one pupil only; no staff credentials, school roster or unrelated records.
 RETURN jsonb_build_object(
  'student',p-'loginCode','school',d->'school','classes',courses,'rooms',d->'rooms',
  'teachers',COALESCE((SELECT jsonb_agg(t) FROM jsonb_array_elements(d->'teachers') t WHERE EXISTS(SELECT 1 FROM jsonb_array_elements(courses) c WHERE c->>'teacherId'=t->>'id') OR EXISTS(SELECT 1 FROM jsonb_array_elements(d->'covers') cv WHERE cv->>'teacherId'=t->>'id' AND (p->'classIds') ? (cv->>'classId'))),'[]'::jsonb),
  'tutors',COALESCE((SELECT jsonb_agg(t) FROM jsonb_array_elements(d->'tutors') t WHERE t->>'id'=p->>'tutorId'),'[]'::jsonb),
  'exams',COALESCE((SELECT jsonb_agg(e) FROM jsonb_array_elements(d->'exams') e WHERE (p->'classIds') ? (e->>'classId')),'[]'::jsonb),
  'covers',COALESCE((SELECT jsonb_agg(c) FROM jsonb_array_elements(d->'covers') c WHERE (p->'classIds') ? (c->>'classId')),'[]'::jsonb),
  'removals',COALESCE((SELECT jsonb_agg(r-'reason') FROM jsonb_array_elements(d->'removals') r WHERE r->>'studentId'=p->>'id'),'[]'::jsonb),
  'closures',d->'closures','announcements',notices
 );
END; $$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_staff_list() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF __SCHOOL__.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required.'; END IF;
RETURN COALESCE((SELECT jsonb_agg(a ORDER BY a.email) FROM __SCHOOL__.oe_staff_access a),'[]'::jsonb); END; $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oe_set_staff(p_email text,p_role text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF __SCHOOL__.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required.'; END IF;
 IF lower(trim(p_email))='masonsandersbussiness@gmail.com' THEN RAISE EXCEPTION 'The owner account remains an administrator.'; END IF;
 IF p_role NOT IN ('teacher','admin','remove') OR p_email NOT LIKE '%@%.%' THEN RAISE EXCEPTION 'Enter a valid email and role.'; END IF;
 IF p_role='remove' THEN DELETE FROM __SCHOOL__.oe_staff_access WHERE email=lower(trim(p_email));
 ELSE INSERT INTO __SCHOOL__.oe_staff_access(email,role) VALUES(lower(trim(p_email)),p_role) ON CONFLICT(email) DO UPDATE SET role=excluded.role; END IF;
 INSERT INTO __SCHOOL__.oe_audit(actor,email,action) VALUES(auth.uid(),auth.jwt()->>'email','Staff access: '||lower(trim(p_email))||' / '||p_role);
END; $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oe_audit_log() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF __SCHOOL__.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required.'; END IF;
RETURN COALESCE((SELECT jsonb_agg(x) FROM (SELECT * FROM __SCHOOL__.oe_audit ORDER BY id DESC LIMIT 150)x),'[]'::jsonb); END; $$;

REVOKE ALL ON FUNCTION __SCHOOL__.oe_role(),__SCHOOL__.oe_get_state(),__SCHOOL__.oe_save_state(jsonb,bigint,text),__SCHOOL__.oe_student_portal(text),__SCHOOL__.oe_staff_list(),__SCHOOL__.oe_set_staff(text,text),__SCHOOL__.oe_audit_log() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION __SCHOOL__.oe_role(),__SCHOOL__.oe_get_state(),__SCHOOL__.oe_save_state(jsonb,bigint,text),__SCHOOL__.oe_staff_list(),__SCHOOL__.oe_set_staff(text,text),__SCHOOL__.oe_audit_log() TO authenticated;
GRANT EXECUTE ON FUNCTION __SCHOOL__.oe_student_portal(text) TO anon,authenticated;


-- Existing schools: run this file once after the original setup.
-- New schools: run ONEEDUCATION-SETUP.sql, then this file.
-- Non-destructive, repeatable upgrade. Existing MIS data stays in oe_workspace.

CREATE TABLE IF NOT EXISTS __SCHOOL__.oe_hub_items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kind text NOT NULL CHECK(kind IN ('staff','homework','report','evening','activity','revision')),
 data jsonb NOT NULL, revision integer NOT NULL DEFAULT 1, created_by uuid, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS __SCHOOL__.oe_hub_actions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kind text NOT NULL CHECK(kind IN ('submission','ticket','booking','enrolment','plan')),
 student_id text, item_id uuid REFERENCES __SCHOOL__.oe_hub_items(id), data jsonb NOT NULL,
 revision integer NOT NULL DEFAULT 1, created_by uuid, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS oe_hub_student_item ON __SCHOOL__.oe_hub_actions(kind,student_id,item_id) WHERE item_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS __SCHOOL__.oe_portal_settings (
 id integer PRIMARY KEY CHECK(id=1),data jsonb NOT NULL DEFAULT '{"global":{},"students":{}}',revision integer NOT NULL DEFAULT 1
);
INSERT INTO __SCHOOL__.oe_portal_settings(id) VALUES(1) ON CONFLICT DO NOTHING;
ALTER TABLE __SCHOOL__.oe_hub_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.oe_hub_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.oe_portal_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON __SCHOOL__.oe_hub_items,__SCHOOL__.oe_hub_actions,__SCHOOL__.oe_portal_settings FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_hub_student(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p jsonb; code text;
BEGIN
 code:=upper(regexp_replace(coalesce(p_code,''),'[-[:space:]]','','g'));
 IF code !~ '^[A-F0-9]{32}$' THEN RAISE EXCEPTION 'Student code not recognised.'; END IF;
 SELECT s INTO p FROM __SCHOOL__.oe_workspace w CROSS JOIN LATERAL jsonb_array_elements(w.data->'students') s
 WHERE w.id=1 AND replace(s->>'loginCode','-','')=code AND NOT coalesce((s->>'archived')::boolean,false);
 IF p IS NULL THEN RAISE EXCEPTION 'Student code not recognised.'; END IF;
 RETURN p;
END; $$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_portal_permissions(p_student text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT '{"timetable":true,"classes":true,"exams":true,"notices":true,"homework":true,"reports":true,"evenings":true,"helpdesk":true,"activities":true,"revision":true}'::jsonb
 ||coalesce(data->'global','{}'::jsonb)||coalesce(data->'students'->p_student,'{}'::jsonb)
 FROM __SCHOOL__.oe_portal_settings WHERE id=1;
$$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oe_hub_target(d jsonb,p jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE coalesce(d->>'targetType','school') WHEN 'school' THEN true WHEN 'year' THEN d->>'targetId'=p->>'year'
 WHEN 'tutor' THEN d->>'targetId'=p->>'tutorId' WHEN 'class' THEN (p->'classIds') ? (d->>'targetId') ELSE false END;
$$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oe_hub_validate_file(d jsonb) RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE f jsonb; bytes bytea;
BEGIN
 f:=d->'attachment'; IF f IS NULL OR f='null'::jsonb THEN RETURN; END IF;
 IF jsonb_typeof(f)<>'object' OR length(coalesce(f->>'name','')) NOT BETWEEN 1 AND 180 THEN RAISE EXCEPTION 'Invalid attachment name.'; END IF;
 IF coalesce(f->>'name','') !~* '\.(pdf|png|jpg|jpeg|txt|docx|xlsx|pptx|csv)$' THEN RAISE EXCEPTION 'Use a PDF, image, text, CSV or Office attachment.'; END IF;
 bytes:=decode(f->>'base64','base64');
 IF bytes IS NULL OR octet_length(bytes)>2097152 THEN RAISE EXCEPTION 'Attachments must be 2 MB or smaller.'; END IF;
END; $$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_hub_staff() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r text;
BEGIN
 r:=__SCHOOL__.oe_role(); IF r IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
 RETURN jsonb_build_object('items',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY updated_at DESC) FROM __SCHOOL__.oe_hub_items i),'[]'::jsonb),
 'actions',coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY updated_at DESC) FROM __SCHOOL__.oe_hub_actions a),'[]'::jsonb),
 'settings',CASE WHEN r='admin' THEN (SELECT to_jsonb(s) FROM __SCHOOL__.oe_portal_settings s WHERE id=1) ELSE NULL END,'role',r);
END; $$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_hub_settings_save(p_data jsonb,p_revision integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE rev integer; rules jsonb; kv record; student_rule record;
BEGIN
 IF __SCHOOL__.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Only administrators can change portal visibility.'; END IF;
 SELECT revision INTO rev FROM __SCHOOL__.oe_portal_settings WHERE id=1 FOR UPDATE;
 IF rev<>p_revision THEN RAISE EXCEPTION 'Settings changed elsewhere. Reload before saving.'; END IF;
 IF jsonb_typeof(p_data->'global') IS DISTINCT FROM 'object' OR jsonb_typeof(p_data->'students') IS DISTINCT FROM 'object' OR octet_length(p_data::text)>500000 THEN RAISE EXCEPTION 'Invalid portal settings.'; END IF;
 FOR rules IN SELECT p_data->'global' UNION ALL SELECT value FROM jsonb_each(p_data->'students') LOOP
  IF jsonb_typeof(rules)<>'object' THEN RAISE EXCEPTION 'Invalid student override.'; END IF;
  FOR kv IN SELECT * FROM jsonb_each(rules) LOOP
   IF kv.key NOT IN ('timetable','classes','exams','notices','homework','reports','evenings','helpdesk','activities','revision') OR jsonb_typeof(kv.value)<>'boolean' THEN RAISE EXCEPTION 'Unknown portal section or invalid visibility value.'; END IF;
  END LOOP;
 END LOOP;
 FOR student_rule IN SELECT key FROM jsonb_each(p_data->'students') LOOP
  IF NOT EXISTS(SELECT 1 FROM __SCHOOL__.oe_workspace w CROSS JOIN LATERAL jsonb_array_elements(w.data->'students') s WHERE w.id=1 AND s->>'id'=student_rule.key) THEN RAISE EXCEPTION 'An override refers to an unknown student.'; END IF;
 END LOOP;
 UPDATE __SCHOOL__.oe_portal_settings SET data=p_data,revision=revision+1 WHERE id=1;
 INSERT INTO __SCHOOL__.oe_audit(actor,email,action,revision) SELECT auth.uid(),auth.jwt()->>'email','Changed student portal visibility',revision FROM __SCHOOL__.oe_workspace WHERE id=1;
 RETURN (SELECT to_jsonb(s) FROM __SCHOOL__.oe_portal_settings s WHERE id=1);
END; $$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_hub_item_save(p_kind text,p_data jsonb,p_id uuid DEFAULT NULL,p_revision integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE row __SCHOOL__.oe_hub_items; w jsonb; pupil jsonb; st timestamp; en timestamp;
BEGIN
 IF __SCHOOL__.oe_role() IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
 SELECT data INTO w FROM __SCHOOL__.oe_workspace WHERE id=1;
 IF w IS NULL THEN RAISE EXCEPTION 'Save the main school workspace first.'; END IF;
 IF p_kind NOT IN ('staff','homework','report','evening','activity','revision') OR jsonb_typeof(p_data)<>'object' OR octet_length(p_data::text)>3000000 THEN RAISE EXCEPTION 'Invalid hub record.'; END IF;
 IF length(trim(coalesce(p_data->>'title',''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Enter a title up to 160 characters.'; END IF;
 IF length(coalesce(p_data->>'body',''))>12000 THEN RAISE EXCEPTION 'Message is too long.'; END IF;
 IF coalesce(p_data->>'url','')<>'' AND p_data->>'url' !~ '^https?://[^[:space:]]+$' THEN RAISE EXCEPTION 'Resource links must start with https:// or http://.'; END IF;
 PERFORM __SCHOOL__.oe_hub_validate_file(p_data);
 IF jsonb_typeof(p_data->'published') IS DISTINCT FROM 'boolean' OR jsonb_typeof(p_data->'archived') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Choose publication status.'; END IF;
 IF p_kind IN ('homework','activity','revision') THEN
  IF coalesce(p_data->>'targetType','') NOT IN ('school','year','tutor','class') THEN RAISE EXCEPTION 'Choose a target audience.'; END IF;
  IF p_data->>'targetType'='year' AND coalesce(p_data->>'targetId','') NOT IN ('7','8','9','10','11') THEN RAISE EXCEPTION 'Choose Year 7–11.'; END IF;
  IF p_data->>'targetType'='class' AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(w->'classes') c WHERE c->>'id'=p_data->>'targetId') THEN RAISE EXCEPTION 'Choose an existing class.'; END IF;
  IF p_data->>'targetType'='tutor' AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(w->'tutors') t WHERE t->>'id'=p_data->>'targetId') THEN RAISE EXCEPTION 'Choose an existing tutor group.'; END IF;
 END IF;
 IF p_kind='homework' AND (p_data->>'due')::date IS NULL THEN RAISE EXCEPTION 'Choose a due date.'; END IF;
 IF p_kind='report' THEN
  SELECT s INTO pupil FROM jsonb_array_elements(w->'students') s WHERE s->>'id'=p_data->>'studentId' AND NOT coalesce((s->>'archived')::boolean,false);
  IF pupil IS NULL OR length(trim(coalesce(p_data->>'term','')))=0 OR length(trim(coalesce(p_data->>'subject','')))=0 THEN RAISE EXCEPTION 'Choose a student, subject and reporting term.'; END IF;
 END IF;
 IF p_kind='evening' THEN
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(w->'teachers') t WHERE t->>'id'=p_data->>'teacherId') THEN RAISE EXCEPTION 'Choose a teacher.'; END IF;
  st:=(p_data->>'date')::date+(p_data->>'start')::time; en:=(p_data->>'date')::date+(p_data->>'end')::time;
  IF st IS NULL OR en IS NULL OR en<=st OR en-st>interval '60 minutes' THEN RAISE EXCEPTION 'Use a valid appointment of up to 60 minutes.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('evening:'||(p_data->>'teacherId')));
  IF EXISTS(SELECT 1 FROM __SCHOOL__.oe_hub_items i WHERE i.kind='evening' AND i.id IS DISTINCT FROM p_id AND NOT (i.data->>'archived')::boolean AND i.data->>'teacherId'=p_data->>'teacherId'
   AND (i.data->>'date')::date+(i.data->>'start')::time<en AND (i.data->>'date')::date+(i.data->>'end')::time>st) THEN RAISE EXCEPTION 'This teacher already has an overlapping appointment slot.'; END IF;
 END IF;
 IF p_kind='activity' AND (coalesce((p_data->>'capacity')::int,0) NOT BETWEEN 1 AND 500 OR (p_data->>'date')::date IS NULL) THEN RAISE EXCEPTION 'Choose a date and capacity between 1 and 500.'; END IF;
 IF p_id IS NOT NULL THEN
  SELECT * INTO row FROM __SCHOOL__.oe_hub_items WHERE id=p_id FOR UPDATE;
  IF row.id IS NULL OR row.revision<>p_revision OR row.kind<>p_kind THEN RAISE EXCEPTION 'Record changed or is unavailable. Reload first.'; END IF;
  IF p_kind IN ('evening','activity') AND EXISTS(SELECT 1 FROM __SCHOOL__.oe_hub_actions a WHERE a.item_id=p_id AND a.data->>'status'<>'cancelled') THEN
   IF p_data->>'archived'='true' OR p_data->>'date' IS DISTINCT FROM row.data->>'date' OR p_data->>'start' IS DISTINCT FROM row.data->>'start' OR p_data->>'end' IS DISTINCT FROM row.data->>'end' OR p_data->>'teacherId' IS DISTINCT FROM row.data->>'teacherId' THEN RAISE EXCEPTION 'Cancel active bookings or sign-ups before changing the date, teacher or archiving.'; END IF;
   IF p_kind='activity' AND (p_data->>'capacity')::int<(SELECT count(*) FROM __SCHOOL__.oe_hub_actions WHERE item_id=p_id AND data->>'status'<>'cancelled') THEN RAISE EXCEPTION 'Capacity cannot be below current sign-ups.'; END IF;
  END IF;
  UPDATE __SCHOOL__.oe_hub_items SET data=p_data,revision=revision+1,updated_at=now() WHERE id=p_id RETURNING * INTO row;
 ELSE
  INSERT INTO __SCHOOL__.oe_hub_items(kind,data,created_by) VALUES(p_kind,p_data,auth.uid()) RETURNING * INTO row;
 END IF;
 INSERT INTO __SCHOOL__.oe_audit(actor,email,action,revision) SELECT auth.uid(),auth.jwt()->>'email','Saved hub '||p_kind||': '||(p_data->>'title'),revision FROM __SCHOOL__.oe_workspace WHERE id=1;
 RETURN to_jsonb(row);
END; $$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_hub_portal_data(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p jsonb; perms jsonb; w jsonb; items jsonb; actions jsonb;
BEGIN
 p:=__SCHOOL__.oe_hub_student(p_code); perms:=__SCHOOL__.oe_portal_permissions(p->>'id');
 SELECT data INTO w FROM __SCHOOL__.oe_workspace WHERE id=1;
 SELECT coalesce(jsonb_agg(to_jsonb(i)-'created_by' ORDER BY updated_at DESC),'[]'::jsonb) INTO items FROM __SCHOOL__.oe_hub_items i
 WHERE (i.data->>'published')::boolean AND NOT (i.data->>'archived')::boolean AND CASE i.kind
  WHEN 'homework' THEN (perms->>'homework')::boolean AND __SCHOOL__.oe_hub_target(i.data,p)
  WHEN 'revision' THEN (perms->>'revision')::boolean AND __SCHOOL__.oe_hub_target(i.data,p)
  WHEN 'activity' THEN (perms->>'activities')::boolean AND __SCHOOL__.oe_hub_target(i.data,p)
  WHEN 'report' THEN (perms->>'reports')::boolean AND i.data->>'studentId'=p->>'id'
  WHEN 'evening' THEN (perms->>'evenings')::boolean AND EXISTS(SELECT 1 FROM jsonb_array_elements(w->'classes') c WHERE (p->'classIds') ? (c->>'id') AND c->>'teacherId'=i.data->>'teacherId')
  ELSE false END;
 SELECT coalesce(jsonb_agg(to_jsonb(a)-'created_by' ORDER BY updated_at DESC),'[]'::jsonb) INTO actions FROM __SCHOOL__.oe_hub_actions a
 WHERE a.student_id=p->>'id' AND CASE a.kind WHEN 'ticket' THEN (perms->>'helpdesk')::boolean ELSE EXISTS(SELECT 1 FROM jsonb_array_elements(items) i WHERE i->>'id'=a.item_id::text) END;
 -- Capacity availability contains no other pupil's identity or booking details.
 SELECT coalesce(jsonb_agg(i||jsonb_build_object('available',greatest(0,CASE WHEN i->>'kind'='evening' THEN 1 ELSE coalesce((i#>>'{data,capacity}')::int,0) END-(SELECT count(*)::int FROM __SCHOOL__.oe_hub_actions a WHERE a.item_id::text=i->>'id' AND a.data->>'status'<>'cancelled')))),'[]'::jsonb)
 INTO items FROM jsonb_array_elements(items) i;
 RETURN jsonb_build_object('items',items,'actions',actions,'permissions',perms);
END; $$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_hub_student_action(p_code text,p_kind text,p_data jsonb,p_item uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p jsonb; perms jsonb; item __SCHOOL__.oe_hub_items; row __SCHOOL__.oe_hub_actions; old __SCHOOL__.oe_hub_actions; allowed boolean; n integer; st timestamp; en timestamp; status_value text; fresh jsonb;
BEGIN
 p:=__SCHOOL__.oe_hub_student(p_code);perms:=__SCHOOL__.oe_portal_permissions(p->>'id');
 IF p_kind NOT IN ('submission','ticket','booking','enrolment','plan') OR jsonb_typeof(p_data)<>'object' OR octet_length(p_data::text)>3000000 THEN RAISE EXCEPTION 'Invalid request.'; END IF;
 allowed:=(perms->>CASE p_kind WHEN 'submission' THEN 'homework' WHEN 'ticket' THEN 'helpdesk' WHEN 'booking' THEN 'evenings' WHEN 'plan' THEN 'revision' ELSE 'activities' END)::boolean;
 IF NOT allowed THEN RAISE EXCEPTION 'Your school has hidden this portal section.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtext(p->>'id'));
 IF p_kind='ticket' AND p_item IS NOT NULL THEN RAISE EXCEPTION 'Tickets cannot be linked to another item.'; END IF;
 IF p_kind<>'ticket' THEN
  SELECT * INTO item FROM __SCHOOL__.oe_hub_items WHERE id=p_item FOR UPDATE;
  IF item.id IS NULL OR item.kind<>(CASE p_kind WHEN 'submission' THEN 'homework' WHEN 'booking' THEN 'evening' WHEN 'plan' THEN 'revision' ELSE 'activity' END) OR NOT (item.data->>'published')::boolean OR (item.data->>'archived')::boolean THEN RAISE EXCEPTION 'This item is unavailable.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(__SCHOOL__.oe_hub_portal_data(p_code)->'items') i WHERE i->>'id'=p_item::text) THEN RAISE EXCEPTION 'This item is not available to your student.'; END IF;
  SELECT * INTO old FROM __SCHOOL__.oe_hub_actions WHERE student_id=p->>'id' AND item_id=p_item AND kind=p_kind FOR UPDATE;
 END IF;
 IF p_kind='submission' THEN
  IF length(trim(coalesce(p_data->>'body','')))=0 AND (p_data->'attachment' IS NULL OR p_data->'attachment'='null'::jsonb) THEN RAISE EXCEPTION 'Enter your answer or attach a file.'; END IF;
  PERFORM __SCHOOL__.oe_hub_validate_file(p_data);
  fresh:=jsonb_build_object('body',left(coalesce(p_data->>'body',''),20000),'attachment',p_data->'attachment','status','submitted','submittedAt',now(),'late',(now() AT TIME ZONE 'Europe/London')::date>(item.data->>'due')::date);
 ELSIF p_kind='plan' THEN
  IF (p_data->>'targetDate')::date IS NULL THEN RAISE EXCEPTION 'Choose a revision date.'; END IF;
  fresh:=jsonb_build_object('status',CASE WHEN p_data->>'status'='complete' THEN 'complete' ELSE 'planned' END,'targetDate',p_data->>'targetDate','body',left(coalesce(p_data->>'body',''),4000),'submittedAt',now());
 ELSIF p_kind='ticket' THEN
  IF length(trim(coalesce(p_data->>'title','')))=0 OR length(trim(coalesce(p_data->>'body','')))=0 OR p_data->>'category' NOT IN ('IT','Lost property','Room request','General') THEN RAISE EXCEPTION 'Add a title, category and message.'; END IF;
  fresh:=jsonb_build_object('title',left(p_data->>'title',160),'body',left(p_data->>'body',10000),'category',p_data->>'category','location',left(coalesce(p_data->>'location',''),160),'status','open','submittedAt',now());
 ELSIF p_kind='booking' THEN
  st:=(item.data->>'date')::date+(item.data->>'start')::time;en:=(item.data->>'date')::date+(item.data->>'end')::time;
  IF st<now() AT TIME ZONE 'Europe/London' THEN RAISE EXCEPTION 'This appointment has already started.'; END IF;
  status_value:=CASE WHEN p_data->>'status'='cancelled' THEN 'cancelled' ELSE 'booked' END;
  IF status_value='booked' THEN
   IF EXISTS(SELECT 1 FROM __SCHOOL__.oe_hub_actions WHERE item_id=p_item AND kind='booking' AND student_id<>p->>'id' AND data->>'status'<>'cancelled') THEN RAISE EXCEPTION 'This slot has just been booked. Choose another.'; END IF;
   IF EXISTS(SELECT 1 FROM __SCHOOL__.oe_hub_actions a JOIN __SCHOOL__.oe_hub_items i ON i.id=a.item_id WHERE a.student_id=p->>'id' AND a.kind='booking' AND a.item_id<>p_item AND a.data->>'status'<>'cancelled'
    AND (((i.data->>'date')::date+(i.data->>'start')::time<en AND (i.data->>'date')::date+(i.data->>'end')::time>st) OR (i.data->>'teacherId'=item.data->>'teacherId' AND i.data->>'date'=item.data->>'date'))) THEN RAISE EXCEPTION 'You already have an overlapping appointment or a booking with this teacher that day.'; END IF;
   IF length(trim(coalesce(p_data->>'parentName','')))=0 THEN RAISE EXCEPTION 'Enter the attending adult’s name.'; END IF;
  END IF;
  fresh:=jsonb_build_object('status',status_value,'parentName',left(coalesce(p_data->>'parentName',old.data->>'parentName'),160),'submittedAt',now());
 ELSE
  status_value:=CASE WHEN p_data->>'status'='cancelled' THEN 'cancelled' ELSE 'pending' END;
  IF status_value='pending' THEN
   IF (item.data->>'date')::date<(now() AT TIME ZONE 'Europe/London')::date THEN RAISE EXCEPTION 'This activity has already taken place.'; END IF;
   SELECT count(*) INTO n FROM __SCHOOL__.oe_hub_actions WHERE item_id=p_item AND student_id<>p->>'id' AND data->>'status'<>'cancelled';
   IF n>=(item.data->>'capacity')::int THEN RAISE EXCEPTION 'This activity is full.'; END IF;
   IF coalesce((item.data->>'requiresConsent')::boolean,false) AND (p_data->>'consent' IS DISTINCT FROM 'true' OR length(trim(coalesce(p_data->>'parentName','')))=0) THEN RAISE EXCEPTION 'Parent/guardian name and consent declaration are required.'; END IF;
   IF old.data->>'status'='approved' THEN status_value:='approved'; END IF;
  END IF;
  fresh:=jsonb_build_object('status',status_value,'parentName',left(coalesce(p_data->>'parentName',old.data->>'parentName'),160),'consent',coalesce((p_data->>'consent')::boolean,false),'submittedAt',now());
 END IF;
 IF old.id IS NULL THEN INSERT INTO __SCHOOL__.oe_hub_actions(kind,student_id,item_id,data) VALUES(p_kind,p->>'id',p_item,fresh) RETURNING * INTO row;
 ELSE UPDATE __SCHOOL__.oe_hub_actions SET data=fresh,revision=revision+1,updated_at=now() WHERE id=old.id RETURNING * INTO row; END IF;
 RETURN to_jsonb(row)-'created_by';
END; $$;

CREATE OR REPLACE FUNCTION __SCHOOL__.oe_hub_review(p_id uuid,p_revision integer,p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE row __SCHOOL__.oe_hub_actions; allowed text[];
BEGIN
 IF __SCHOOL__.oe_role() IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
 SELECT * INTO row FROM __SCHOOL__.oe_hub_actions WHERE id=p_id FOR UPDATE;
 IF row.id IS NULL OR row.revision<>p_revision THEN RAISE EXCEPTION 'Record changed. Reload before reviewing.'; END IF;
 allowed:=CASE row.kind WHEN 'submission' THEN ARRAY['submitted','reviewed'] WHEN 'plan' THEN ARRAY['planned','complete'] WHEN 'ticket' THEN ARRAY['open','in progress','resolved'] WHEN 'enrolment' THEN ARRAY['pending','approved','cancelled'] ELSE ARRAY['booked','cancelled'] END;
 IF p_data->>'status' IS NULL OR NOT (p_data->>'status'=ANY(allowed)) THEN RAISE EXCEPTION 'Choose a valid status.'; END IF;
 -- Staff may cancel a booking/enrolment here; reactivation goes through capacity checks.
 IF row.data->>'status'='cancelled' AND p_data->>'status'<>'cancelled' THEN RAISE EXCEPTION 'The family must sign up again so capacity can be checked.'; END IF;
 UPDATE __SCHOOL__.oe_hub_actions SET data=data||jsonb_build_object('status',p_data->>'status','feedback',left(coalesce(p_data->>'feedback',''),10000),'grade',left(coalesce(p_data->>'grade',''),40),'reviewedAt',now()),revision=revision+1,updated_at=now() WHERE id=p_id RETURNING * INTO row;
 INSERT INTO __SCHOOL__.oe_audit(actor,email,action,revision) SELECT auth.uid(),auth.jwt()->>'email','Reviewed hub '||row.kind,revision FROM __SCHOOL__.oe_workspace WHERE id=1;
 RETURN to_jsonb(row);
END; $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oe_hub_staff_ticket(p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE row __SCHOOL__.oe_hub_actions;
BEGIN
 IF __SCHOOL__.oe_role() IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
 IF length(trim(coalesce(p_data->>'title','')))=0 OR length(trim(coalesce(p_data->>'body','')))=0 THEN RAISE EXCEPTION 'Enter a title and message.'; END IF;
 INSERT INTO __SCHOOL__.oe_hub_actions(kind,data,created_by) VALUES('ticket',jsonb_build_object('title',left(p_data->>'title',160),'body',left(p_data->>'body',10000),'category',left(coalesce(p_data->>'category','General'),50),'location',left(coalesce(p_data->>'location',''),160),'requester',auth.jwt()->>'email','status','open','submittedAt',now()),auth.uid()) RETURNING * INTO row;
 RETURN to_jsonb(row);
END; $$;

-- Preserve the previous RPC internally, then enforce visibility on its public name.
DO $$ BEGIN
 IF to_regprocedure('__SCHOOL__.oe_student_portal_v1_internal(text)') IS NULL THEN
  ALTER FUNCTION __SCHOOL__.oe_student_portal(text) RENAME TO oe_student_portal_v1_internal;
 END IF;
END; $$;
REVOKE ALL ON FUNCTION __SCHOOL__.oe_student_portal_v1_internal(text) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION __SCHOOL__.oe_student_portal(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE d jsonb; perms jsonb; courses jsonb;
BEGIN
 d:=__SCHOOL__.oe_student_portal_v1_internal(p_code);perms:=__SCHOOL__.oe_portal_permissions(d#>>'{student,id}');
 IF NOT (perms->>'timetable')::boolean THEN
  d:=d||jsonb_build_object('covers','[]'::jsonb,'removals','[]'::jsonb);
 END IF;
 SELECT coalesce(jsonb_agg(CASE WHEN (perms->>'timetable')::boolean THEN c ELSE c-'meetings' END),'[]'::jsonb) INTO courses FROM jsonb_array_elements(d->'classes') c
 WHERE (perms->>'timetable')::boolean OR (perms->>'classes')::boolean;
 d:=d||jsonb_build_object('classes',courses);
 IF NOT (perms->>'exams')::boolean THEN d:=d||jsonb_build_object('exams','[]'::jsonb); END IF;
 IF NOT (perms->>'exams')::boolean THEN d:=jsonb_set(d,'{announcements}',coalesce((SELECT jsonb_agg(n) FROM jsonb_array_elements(d->'announcements') n WHERE NOT coalesce((n->>'sourceExam')::boolean,false)),'[]'::jsonb)); END IF;
 IF NOT (perms->>'timetable')::boolean AND NOT (perms->>'classes')::boolean AND NOT (perms->>'evenings')::boolean THEN d:=d||jsonb_build_object('teachers','[]'::jsonb); END IF;
 IF NOT (perms->>'notices')::boolean THEN d:=d||jsonb_build_object('announcements','[]'::jsonb); END IF;
 IF NOT (perms->>'timetable')::boolean AND NOT (perms->>'exams')::boolean THEN d:=d||jsonb_build_object('rooms','[]'::jsonb); END IF;
 RETURN d||jsonb_build_object('permissions',perms,'hub',__SCHOOL__.oe_hub_portal_data(p_code));
END; $$;

REVOKE ALL ON FUNCTION __SCHOOL__.oe_hub_student(text),__SCHOOL__.oe_portal_permissions(text),__SCHOOL__.oe_hub_target(jsonb,jsonb),__SCHOOL__.oe_hub_validate_file(jsonb),__SCHOOL__.oe_hub_staff(),__SCHOOL__.oe_hub_settings_save(jsonb,integer),__SCHOOL__.oe_hub_item_save(text,jsonb,uuid,integer),__SCHOOL__.oe_hub_portal_data(text),__SCHOOL__.oe_hub_student_action(text,text,jsonb,uuid),__SCHOOL__.oe_hub_review(uuid,integer,jsonb),__SCHOOL__.oe_hub_staff_ticket(jsonb),__SCHOOL__.oe_student_portal(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION __SCHOOL__.oe_hub_staff(),__SCHOOL__.oe_hub_settings_save(jsonb,integer),__SCHOOL__.oe_hub_item_save(text,jsonb,uuid,integer),__SCHOOL__.oe_hub_review(uuid,integer,jsonb),__SCHOOL__.oe_hub_staff_ticket(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION __SCHOOL__.oe_student_portal(text),__SCHOOL__.oe_hub_student_action(text,text,jsonb,uuid) TO anon,authenticated;

-- OneHome: run in the EXISTING OneEducation Supabase project. No MIS files need replacing.

DO $$ BEGIN IF to_regclass('__SCHOOL__.oe_workspace') IS NULL THEN RAISE EXCEPTION 'Use your existing OneEducation Supabase project.'; END IF; END $$;
CREATE TABLE IF NOT EXISTS __SCHOOL__.oh_topics(id text PRIMARY KEY,subject text NOT NULL,title text NOT NULL,stage text NOT NULL);
CREATE TABLE IF NOT EXISTS __SCHOOL__.oh_questions(id text PRIMARY KEY,topic text NOT NULL REFERENCES __SCHOOL__.oh_topics(id),data jsonb NOT NULL);
CREATE TABLE IF NOT EXISTS __SCHOOL__.oh_assignments(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),class_id text NOT NULL,title text NOT NULL,due_at timestamptz NOT NULL,question_ids text[] NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),created_by uuid,archived boolean NOT NULL DEFAULT false);
CREATE TABLE IF NOT EXISTS __SCHOOL__.oh_progress(assignment_id uuid NOT NULL REFERENCES __SCHOOL__.oh_assignments(id),student_id text NOT NULL,answers jsonb NOT NULL DEFAULT '{}'::jsonb,submitted_at timestamptz,score integer,updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(assignment_id,student_id));
ALTER TABLE __SCHOOL__.oh_topics ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.oh_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.oh_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.oh_progress ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON __SCHOOL__.oh_topics,__SCHOOL__.oh_questions,__SCHOOL__.oh_assignments,__SCHOOL__.oh_progress FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION __SCHOOL__.oh_pupil(p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p jsonb; rules jsonb; code text:=upper(regexp_replace(COALESCE(p_code,''),'[-[:space:]]','','g'));
BEGIN
IF code !~ '^[A-F0-9]{32}$' THEN RAISE EXCEPTION 'Student code not recognised.'; END IF;
SELECT s INTO p FROM __SCHOOL__.oe_workspace w CROSS JOIN LATERAL jsonb_array_elements(w.data->'students') s WHERE w.id=1 AND replace(s->>'loginCode','-','')=code AND NOT COALESCE((s->>'archived')::boolean,false) LIMIT 1;
IF p IS NULL THEN RAISE EXCEPTION 'Student code not recognised.'; END IF;
IF to_regprocedure('__SCHOOL__.oe_portal_permissions(text)') IS NOT NULL THEN
EXECUTE 'SELECT __SCHOOL__.oe_portal_permissions($1)' INTO rules USING p->>'id';
IF rules->>'homework'='false' THEN RAISE EXCEPTION 'Homework access is currently hidden by your school. Please ask staff.'; END IF;
END IF;
RETURN p-'loginCode';
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oh_catalog() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
SELECT COALESCE(jsonb_agg(to_jsonb(t)||jsonb_build_object('count',(SELECT count(*) FROM __SCHOOL__.oh_questions q WHERE q.topic=t.id)) ORDER BY t.subject,t.title),'[]'::jsonb) FROM __SCHOOL__.oh_topics t;
$$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oh_staff() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d jsonb;
BEGIN
IF __SCHOOL__.oe_role() IS NULL THEN RAISE EXCEPTION 'Verified OneEducation staff access required.'; END IF;
SELECT data INTO d FROM __SCHOOL__.oe_workspace WHERE id=1;
RETURN jsonb_build_object('school',d->'school','role',__SCHOOL__.oe_role(),'topics',__SCHOOL__.oh_catalog(),
'classes',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',c->>'id','name',c->>'name','year',c->'year','subject',c->>'subject')) FROM jsonb_array_elements(d->'classes') c),'[]'::jsonb),
'students',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',s->>'id','first',s->>'first','last',s->>'last','year',s->'year','classIds',s->'classIds')) FROM jsonb_array_elements(d->'students') s WHERE NOT COALESCE((s->>'archived')::boolean,false)),'[]'::jsonb),
'assignments',COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC) FROM __SCHOOL__.oh_assignments a),'[]'::jsonb),
'progress',COALESCE((SELECT jsonb_agg(to_jsonb(p)-'answers') FROM __SCHOOL__.oh_progress p),'[]'::jsonb));
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oh_create(p_class text,p_title text,p_topics text[],p_count integer,p_due timestamptz) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE ids text[]; result uuid;
BEGIN
IF __SCHOOL__.oe_role() IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
IF NOT EXISTS(SELECT 1 FROM __SCHOOL__.oe_workspace w,jsonb_array_elements(w.data->'classes') c WHERE w.id=1 AND c->>'id'=p_class) THEN RAISE EXCEPTION 'Class no longer exists. Refresh the class list.'; END IF;
IF p_title IS NULL OR length(trim(p_title)) NOT BETWEEN 1 AND 150 THEN RAISE EXCEPTION 'Enter a title (1–150 characters).'; END IF;
IF p_due IS NULL OR p_due<=now() THEN RAISE EXCEPTION 'Choose a future deadline.'; END IF;
IF p_topics IS NULL OR cardinality(p_topics) NOT BETWEEN 1 AND 12 OR p_count IS NULL OR p_count NOT BETWEEN cardinality(p_topics) AND 40 THEN RAISE EXCEPTION 'Choose 1–12 topics and between one question per topic and 40 questions.'; END IF;
IF EXISTS(SELECT 1 FROM unnest(p_topics) t WHERE t IS NULL OR NOT EXISTS(SELECT 1 FROM __SCHOOL__.oh_topics x WHERE x.id=t)) THEN RAISE EXCEPTION 'Unknown topic.'; END IF;
IF (SELECT count(DISTINCT subject) FROM __SCHOOL__.oh_topics WHERE id=ANY(p_topics))<>1 THEN RAISE EXCEPTION 'Choose topics from one subject for each homework.'; END IF;
SELECT array_agg(id ORDER BY rn,rnd) INTO ids FROM (SELECT id,row_number() OVER(PARTITION BY topic ORDER BY random()) rn,random() rnd FROM __SCHOOL__.oh_questions WHERE topic=ANY(p_topics)) q;
IF COALESCE(cardinality(ids),0)<p_count THEN RAISE EXCEPTION 'Not enough questions. Add topics or reduce the question count.'; END IF;
INSERT INTO __SCHOOL__.oh_assignments(class_id,title,due_at,question_ids,created_by) VALUES(p_class,trim(p_title),p_due,ids[1:p_count],auth.uid()) RETURNING id INTO result;
RETURN result;
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oh_archive(p_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF __SCHOOL__.oe_role() IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
UPDATE __SCHOOL__.oh_assignments SET archived=true WHERE id=p_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Homework not found.'; END IF;
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oh_student(p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p jsonb:=__SCHOOL__.oh_pupil(p_code);d jsonb;
BEGIN
SELECT data INTO d FROM __SCHOOL__.oe_workspace WHERE id=1;
RETURN jsonb_build_object('student',jsonb_build_object('id',p->>'id','first',p->>'first','last',p->>'last','year',p->'year'),'school',d->'school',
'classes',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',c->>'id','name',c->>'name','subject',c->>'subject')) FROM jsonb_array_elements(d->'classes') c WHERE (p->'classIds') ? (c->>'id')),'[]'::jsonb),
'assignments',COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.due_at) FROM __SCHOOL__.oh_assignments a WHERE NOT a.archived AND (p->'classIds') ? a.class_id),'[]'::jsonb),
'progress',COALESCE((SELECT jsonb_agg(to_jsonb(r)-'answers') FROM __SCHOOL__.oh_progress r JOIN __SCHOOL__.oh_assignments a ON a.id=r.assignment_id WHERE r.student_id=p->>'id' AND NOT a.archived AND (p->'classIds') ? a.class_id),'[]'::jsonb));
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oh_open(p_code text,p_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p jsonb:=__SCHOOL__.oh_pupil(p_code);a __SCHOOL__.oh_assignments;r __SCHOOL__.oh_progress;qs jsonb;
BEGIN
SELECT * INTO a FROM __SCHOOL__.oh_assignments WHERE id=p_id AND NOT archived AND (p->'classIds') ? class_id;
IF a.id IS NULL THEN RAISE EXCEPTION 'This homework is not available to your current class.'; END IF;
SELECT * INTO r FROM __SCHOOL__.oh_progress WHERE assignment_id=p_id AND student_id=p->>'id';
SELECT jsonb_agg((CASE WHEN r.submitted_at IS NULL THEN q.data-'correct'-'explanation' ELSE q.data END)||jsonb_build_object('id',q.id,'topicTitle',t.title) ORDER BY x.ord) INTO qs FROM unnest(a.question_ids) WITH ORDINALITY x(id,ord) JOIN __SCHOOL__.oh_questions q ON q.id=x.id JOIN __SCHOOL__.oh_topics t ON t.id=q.topic;
RETURN jsonb_build_object('assignment',to_jsonb(a),'questions',qs,'answers',COALESCE(r.answers,'{}'::jsonb),'submitted_at',r.submitted_at,'score',r.score);
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.oh_save(p_code text,p_id uuid,p_answers jsonb,p_submit boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p jsonb:=__SCHOOL__.oh_pupil(p_code);a __SCHOOL__.oh_assignments;r __SCHOOL__.oh_progress;n integer; k text;v jsonb;
BEGIN
SELECT * INTO a FROM __SCHOOL__.oh_assignments WHERE id=p_id AND NOT archived AND (p->'classIds') ? class_id FOR SHARE;
IF a.id IS NULL THEN RAISE EXCEPTION 'This homework is not available to your current class.'; END IF;
IF p_answers IS NULL OR jsonb_typeof(p_answers)<>'object' OR octet_length(p_answers::text)>15000 THEN RAISE EXCEPTION 'Invalid answers.'; END IF;
FOR k,v IN SELECT * FROM jsonb_each(p_answers) LOOP
IF NOT(k=ANY(a.question_ids)) OR jsonb_typeof(v)<>'number' OR v::text !~ '^[0-3]$' THEN RAISE EXCEPTION 'Invalid answer choice.'; END IF;
END LOOP;
INSERT INTO __SCHOOL__.oh_progress(assignment_id,student_id) VALUES(p_id,p->>'id') ON CONFLICT DO NOTHING;
SELECT * INTO r FROM __SCHOOL__.oh_progress WHERE assignment_id=p_id AND student_id=p->>'id' FOR UPDATE;
IF r.submitted_at IS NOT NULL THEN RAISE EXCEPTION 'This homework has already been submitted.'; END IF;
IF p_submit AND (SELECT count(*) FROM jsonb_object_keys(p_answers))<>cardinality(a.question_ids) THEN RAISE EXCEPTION 'Answer every question before submitting.'; END IF;
IF p_submit THEN SELECT count(*) INTO n FROM __SCHOOL__.oh_questions q WHERE q.id=ANY(a.question_ids) AND p_answers->q.id=q.data->'correct'; END IF;
UPDATE __SCHOOL__.oh_progress SET answers=p_answers,submitted_at=CASE WHEN p_submit THEN now() END,score=n,updated_at=now() WHERE assignment_id=p_id AND student_id=p->>'id';
RETURN __SCHOOL__.oh_open(p_code,p_id);
END $$;
REVOKE ALL ON FUNCTION __SCHOOL__.oh_pupil(text),__SCHOOL__.oh_catalog(),__SCHOOL__.oh_staff(),__SCHOOL__.oh_create(text,text,text[],integer,timestamptz),__SCHOOL__.oh_archive(uuid),__SCHOOL__.oh_student(text),__SCHOOL__.oh_open(text,uuid),__SCHOOL__.oh_save(text,uuid,jsonb,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION __SCHOOL__.oh_staff(),__SCHOOL__.oh_create(text,text,text[],integer,timestamptz),__SCHOOL__.oh_archive(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION __SCHOOL__.oh_student(text),__SCHOOL__.oh_open(text,uuid),__SCHOOL__.oh_save(text,uuid,jsonb,boolean) TO anon,authenticated;
-- TOPIC AND QUESTION BANK INSERTED BELOW

INSERT INTO __SCHOOL__.oh_topics(id,subject,title,stage) VALUES
('m-integers','Maths','Working with negative numbers','Foundation'),
('m-fractions','Maths','Fractions of amounts','Foundation'),
('m-percent','Maths','Percentages and discounts','Foundation'),
('m-ratio','Maths','Sharing in a ratio','Foundation'),
('m-equations','Maths','Solving linear equations','Foundation'),
('m-expand','Maths','Expanding single brackets','Foundation'),
('m-sequences','Maths','Linear sequences','Foundation'),
('m-area','Maths','Areas of triangles','Foundation'),
('m-probability','Maths','Simple probability','Foundation'),
('m-mean','Maths','Calculating the mean','Foundation'),
('m-quadratic','Maths','Factorising quadratics','Higher'),
('m-pythagoras','Maths','Pythagoras: the hypotenuse','Higher'),
('s-cells','Science','Cell biology','GCSE foundations'),
('s-transport','Science','Transport in cells','GCSE foundations'),
('s-enzymes','Science','Enzymes and digestion','GCSE foundations'),
('s-photosynthesis','Science','Photosynthesis','GCSE foundations'),
('s-inheritance','Science','Inheritance','GCSE foundations'),
('s-atoms','Science','Atoms and the periodic table','GCSE foundations'),
('s-bonding','Science','Chemical bonding','GCSE foundations'),
('s-acids','Science','Acids, alkalis and salts','GCSE foundations'),
('s-energy','Science','Energy stores and transfers','GCSE foundations'),
('s-electricity','Science','Electric circuits','GCSE foundations'),
('s-forces','Science','Forces and motion','GCSE foundations'),
('s-waves','Science','Waves','GCSE foundations'),
('r-inference','Reading','Reading between the lines','Fiction'),
('r-language','Reading','Language and imagery','Fiction'),
('r-retrieval','Reading','Finding precise information','Non-fiction'),
('r-argument','Reading','Purpose and persuasion','Non-fiction'),
('r-structure','Reading','Structure and shifts','Fiction'),
('r-vocabulary','Reading','Vocabulary in context','Fiction')
ON CONFLICT(id) DO UPDATE SET title=excluded.title,subject=excluded.subject,stage=excluded.stage;
INSERT INTO __SCHOOL__.oh_questions(id,topic,data) VALUES
('m-integers-1','m-integers','{"id":"m-integers-1","topic":"m-integers","prompt":"Calculate −2 + 9.","choices":["7","-7","11","-11"],"correct":0,"explanation":"Start at −2 and move 9 places right to reach 7.","hint":"Use a number line.","passage":""}'::jsonb),
('m-integers-2','m-integers','{"id":"m-integers-2","topic":"m-integers","prompt":"Calculate −3 + 10.","choices":["-7","13","-13","7"],"correct":3,"explanation":"Start at −3 and move 10 places right to reach 7.","hint":"Use a number line.","passage":""}'::jsonb),
('m-integers-3','m-integers','{"id":"m-integers-3","topic":"m-integers","prompt":"Calculate −4 + 11.","choices":["15","-15","7","-7"],"correct":2,"explanation":"Start at −4 and move 11 places right to reach 7.","hint":"Use a number line.","passage":""}'::jsonb),
('m-integers-4','m-integers','{"id":"m-integers-4","topic":"m-integers","prompt":"Calculate −5 + 12.","choices":["-17","7","-7","17"],"correct":1,"explanation":"Start at −5 and move 12 places right to reach 7.","hint":"Use a number line.","passage":""}'::jsonb),
('m-integers-5','m-integers','{"id":"m-integers-5","topic":"m-integers","prompt":"Calculate −6 + 13.","choices":["7","-7","19","-19"],"correct":0,"explanation":"Start at −6 and move 13 places right to reach 7.","hint":"Use a number line.","passage":""}'::jsonb),
('m-integers-6','m-integers','{"id":"m-integers-6","topic":"m-integers","prompt":"Calculate −7 + 14.","choices":["-7","21","-21","7"],"correct":3,"explanation":"Start at −7 and move 14 places right to reach 7.","hint":"Use a number line.","passage":""}'::jsonb),
('m-integers-7','m-integers','{"id":"m-integers-7","topic":"m-integers","prompt":"Calculate −8 + 15.","choices":["23","-23","7","-7"],"correct":2,"explanation":"Start at −8 and move 15 places right to reach 7.","hint":"Use a number line.","passage":""}'::jsonb),
('m-integers-8','m-integers','{"id":"m-integers-8","topic":"m-integers","prompt":"Calculate −9 + 16.","choices":["-25","7","-7","25"],"correct":1,"explanation":"Start at −9 and move 16 places right to reach 7.","hint":"Use a number line.","passage":""}'::jsonb),
('m-fractions-1','m-fractions','{"id":"m-fractions-1","topic":"m-fractions","prompt":"What is 3/5 of 10?","choices":["6","7","2","8"],"correct":0,"explanation":"Divide 10 by 5 to get 2, then multiply by 3 to get 6.","hint":"Find one fifth first.","passage":""}'::jsonb),
('m-fractions-2','m-fractions','{"id":"m-fractions-2","topic":"m-fractions","prompt":"What is 3/5 of 15?","choices":["12","3","11","9"],"correct":3,"explanation":"Divide 15 by 5 to get 3, then multiply by 3 to get 9.","hint":"Find one fifth first.","passage":""}'::jsonb),
('m-fractions-3','m-fractions','{"id":"m-fractions-3","topic":"m-fractions","prompt":"What is 3/5 of 20?","choices":["4","14","12","17"],"correct":2,"explanation":"Divide 20 by 5 to get 4, then multiply by 3 to get 12.","hint":"Find one fifth first.","passage":""}'::jsonb),
('m-fractions-4','m-fractions','{"id":"m-fractions-4","topic":"m-fractions","prompt":"What is 3/5 of 25?","choices":["17","15","22","5"],"correct":1,"explanation":"Divide 25 by 5 to get 5, then multiply by 3 to get 15.","hint":"Find one fifth first.","passage":""}'::jsonb),
('m-fractions-5','m-fractions','{"id":"m-fractions-5","topic":"m-fractions","prompt":"What is 3/5 of 30?","choices":["18","27","6","20"],"correct":0,"explanation":"Divide 30 by 5 to get 6, then multiply by 3 to get 18.","hint":"Find one fifth first.","passage":""}'::jsonb),
('m-fractions-6','m-fractions','{"id":"m-fractions-6","topic":"m-fractions","prompt":"What is 3/5 of 35?","choices":["32","7","23","21"],"correct":3,"explanation":"Divide 35 by 5 to get 7, then multiply by 3 to get 21.","hint":"Find one fifth first.","passage":""}'::jsonb),
('m-fractions-7','m-fractions','{"id":"m-fractions-7","topic":"m-fractions","prompt":"What is 3/5 of 40?","choices":["8","26","24","37"],"correct":2,"explanation":"Divide 40 by 5 to get 8, then multiply by 3 to get 24.","hint":"Find one fifth first.","passage":""}'::jsonb),
('m-fractions-8','m-fractions','{"id":"m-fractions-8","topic":"m-fractions","prompt":"What is 3/5 of 45?","choices":["29","27","42","9"],"correct":1,"explanation":"Divide 45 by 5 to get 9, then multiply by 3 to get 27.","hint":"Find one fifth first.","passage":""}'::jsonb),
('m-percent-1','m-percent','{"id":"m-percent-1","topic":"m-percent","prompt":"A jacket costs £60. It is reduced by 15%. What is its sale price?","choices":["51","9","57","69"],"correct":0,"explanation":"15% of £60 is £9. Subtract the discount: £60 − £9 = £51.","hint":"Find 10% and 5%, then subtract both.","passage":""}'::jsonb),
('m-percent-2','m-percent','{"id":"m-percent-2","topic":"m-percent","prompt":"A jacket costs £80. It is reduced by 15%. What is its sale price?","choices":["12","76","92","68"],"correct":3,"explanation":"15% of £80 is £12. Subtract the discount: £80 − £12 = £68.","hint":"Find 10% and 5%, then subtract both.","passage":""}'::jsonb),
('m-percent-3','m-percent','{"id":"m-percent-3","topic":"m-percent","prompt":"A jacket costs £100. It is reduced by 15%. What is its sale price?","choices":["95","115","85","15"],"correct":2,"explanation":"15% of £100 is £15. Subtract the discount: £100 − £15 = £85.","hint":"Find 10% and 5%, then subtract both.","passage":""}'::jsonb),
('m-percent-4','m-percent','{"id":"m-percent-4","topic":"m-percent","prompt":"A jacket costs £120. It is reduced by 15%. What is its sale price?","choices":["138","102","18","114"],"correct":1,"explanation":"15% of £120 is £18. Subtract the discount: £120 − £18 = £102.","hint":"Find 10% and 5%, then subtract both.","passage":""}'::jsonb),
('m-percent-5','m-percent','{"id":"m-percent-5","topic":"m-percent","prompt":"A jacket costs £140. It is reduced by 15%. What is its sale price?","choices":["119","21","133","161"],"correct":0,"explanation":"15% of £140 is £21. Subtract the discount: £140 − £21 = £119.","hint":"Find 10% and 5%, then subtract both.","passage":""}'::jsonb),
('m-percent-6','m-percent','{"id":"m-percent-6","topic":"m-percent","prompt":"A jacket costs £160. It is reduced by 15%. What is its sale price?","choices":["24","152","184","136"],"correct":3,"explanation":"15% of £160 is £24. Subtract the discount: £160 − £24 = £136.","hint":"Find 10% and 5%, then subtract both.","passage":""}'::jsonb),
('m-percent-7','m-percent','{"id":"m-percent-7","topic":"m-percent","prompt":"A jacket costs £180. It is reduced by 15%. What is its sale price?","choices":["171","207","153","27"],"correct":2,"explanation":"15% of £180 is £27. Subtract the discount: £180 − £27 = £153.","hint":"Find 10% and 5%, then subtract both.","passage":""}'::jsonb),
('m-percent-8','m-percent','{"id":"m-percent-8","topic":"m-percent","prompt":"A jacket costs £200. It is reduced by 15%. What is its sale price?","choices":["230","170","30","190"],"correct":1,"explanation":"15% of £200 is £30. Subtract the discount: £200 − £30 = £170.","hint":"Find 10% and 5%, then subtract both.","passage":""}'::jsonb),
('m-ratio-1','m-ratio','{"id":"m-ratio-1","topic":"m-ratio","prompt":"£21 is shared in the ratio 2 : 5. What is the larger share?","choices":["15","6","16","9"],"correct":0,"explanation":"There are 7 parts. Each is £3. The larger share is 5 × £3 = £15.","hint":"Add the ratio parts first.","passage":""}'::jsonb),
('m-ratio-2','m-ratio','{"id":"m-ratio-2","topic":"m-ratio","prompt":"£28 is shared in the ratio 2 : 5. What is the larger share?","choices":["8","23","12","20"],"correct":3,"explanation":"There are 7 parts. Each is £4. The larger share is 5 × £4 = £20.","hint":"Add the ratio parts first.","passage":""}'::jsonb),
('m-ratio-3','m-ratio','{"id":"m-ratio-3","topic":"m-ratio","prompt":"£35 is shared in the ratio 2 : 5. What is the larger share?","choices":["30","15","25","10"],"correct":2,"explanation":"There are 7 parts. Each is £5. The larger share is 5 × £5 = £25.","hint":"Add the ratio parts first.","passage":""}'::jsonb),
('m-ratio-4','m-ratio','{"id":"m-ratio-4","topic":"m-ratio","prompt":"£42 is shared in the ratio 2 : 5. What is the larger share?","choices":["18","30","12","37"],"correct":1,"explanation":"There are 7 parts. Each is £6. The larger share is 5 × £6 = £30.","hint":"Add the ratio parts first.","passage":""}'::jsonb),
('m-ratio-5','m-ratio','{"id":"m-ratio-5","topic":"m-ratio","prompt":"£49 is shared in the ratio 2 : 5. What is the larger share?","choices":["35","14","44","21"],"correct":0,"explanation":"There are 7 parts. Each is £7. The larger share is 5 × £7 = £35.","hint":"Add the ratio parts first.","passage":""}'::jsonb),
('m-ratio-6','m-ratio','{"id":"m-ratio-6","topic":"m-ratio","prompt":"£56 is shared in the ratio 2 : 5. What is the larger share?","choices":["16","51","24","40"],"correct":3,"explanation":"There are 7 parts. Each is £8. The larger share is 5 × £8 = £40.","hint":"Add the ratio parts first.","passage":""}'::jsonb),
('m-ratio-7','m-ratio','{"id":"m-ratio-7","topic":"m-ratio","prompt":"£63 is shared in the ratio 2 : 5. What is the larger share?","choices":["58","27","45","18"],"correct":2,"explanation":"There are 7 parts. Each is £9. The larger share is 5 × £9 = £45.","hint":"Add the ratio parts first.","passage":""}'::jsonb),
('m-ratio-8','m-ratio','{"id":"m-ratio-8","topic":"m-ratio","prompt":"£70 is shared in the ratio 2 : 5. What is the larger share?","choices":["30","50","20","65"],"correct":1,"explanation":"There are 7 parts. Each is £10. The larger share is 5 × £10 = £50.","hint":"Add the ratio parts first.","passage":""}'::jsonb),
('m-equations-1','m-equations','{"id":"m-equations-1","topic":"m-equations","prompt":"Solve 3x + 4 = 10.","choices":["2","3","1","6"],"correct":0,"explanation":"Subtract 4 to get 3x = 6, then divide by 3: x = 2.","hint":"Undo addition before multiplication.","passage":""}'::jsonb),
('m-equations-2','m-equations','{"id":"m-equations-2","topic":"m-equations","prompt":"Solve 3x + 4 = 13.","choices":["4","2","9","3"],"correct":3,"explanation":"Subtract 4 to get 3x = 9, then divide by 3: x = 3.","hint":"Undo addition before multiplication.","passage":""}'::jsonb),
('m-equations-3','m-equations','{"id":"m-equations-3","topic":"m-equations","prompt":"Solve 3x + 4 = 16.","choices":["3","12","4","5"],"correct":2,"explanation":"Subtract 4 to get 3x = 12, then divide by 3: x = 4.","hint":"Undo addition before multiplication.","passage":""}'::jsonb),
('m-equations-4','m-equations','{"id":"m-equations-4","topic":"m-equations","prompt":"Solve 3x + 4 = 19.","choices":["15","5","6","4"],"correct":1,"explanation":"Subtract 4 to get 3x = 15, then divide by 3: x = 5.","hint":"Undo addition before multiplication.","passage":""}'::jsonb),
('m-equations-5','m-equations','{"id":"m-equations-5","topic":"m-equations","prompt":"Solve 3x + 4 = 22.","choices":["6","7","5","18"],"correct":0,"explanation":"Subtract 4 to get 3x = 18, then divide by 3: x = 6.","hint":"Undo addition before multiplication.","passage":""}'::jsonb),
('m-equations-6','m-equations','{"id":"m-equations-6","topic":"m-equations","prompt":"Solve 3x + 4 = 25.","choices":["8","6","21","7"],"correct":3,"explanation":"Subtract 4 to get 3x = 21, then divide by 3: x = 7.","hint":"Undo addition before multiplication.","passage":""}'::jsonb),
('m-equations-7','m-equations','{"id":"m-equations-7","topic":"m-equations","prompt":"Solve 3x + 4 = 28.","choices":["7","24","8","9"],"correct":2,"explanation":"Subtract 4 to get 3x = 24, then divide by 3: x = 8.","hint":"Undo addition before multiplication.","passage":""}'::jsonb),
('m-equations-8','m-equations','{"id":"m-equations-8","topic":"m-equations","prompt":"Solve 3x + 4 = 31.","choices":["27","9","10","8"],"correct":1,"explanation":"Subtract 4 to get 3x = 27, then divide by 3: x = 9.","hint":"Undo addition before multiplication.","passage":""}'::jsonb),
('m-expand-1','m-expand','{"id":"m-expand-1","topic":"m-expand","prompt":"Expand 2(x + 3).","choices":["2x + 6","2x + 3","x + 6","5x"],"correct":0,"explanation":"Multiply both terms inside the bracket by 2: 2x + 6.","hint":"Every term inside must be multiplied.","passage":""}'::jsonb),
('m-expand-2','m-expand','{"id":"m-expand-2","topic":"m-expand","prompt":"Expand 3(x + 3).","choices":["3x + 3","x + 9","6x","3x + 9"],"correct":3,"explanation":"Multiply both terms inside the bracket by 3: 3x + 9.","hint":"Every term inside must be multiplied.","passage":""}'::jsonb),
('m-expand-3','m-expand','{"id":"m-expand-3","topic":"m-expand","prompt":"Expand 4(x + 3).","choices":["x + 12","7x","4x + 12","4x + 3"],"correct":2,"explanation":"Multiply both terms inside the bracket by 4: 4x + 12.","hint":"Every term inside must be multiplied.","passage":""}'::jsonb),
('m-expand-4','m-expand','{"id":"m-expand-4","topic":"m-expand","prompt":"Expand 5(x + 3).","choices":["8x","5x + 15","5x + 3","x + 15"],"correct":1,"explanation":"Multiply both terms inside the bracket by 5: 5x + 15.","hint":"Every term inside must be multiplied.","passage":""}'::jsonb),
('m-expand-5','m-expand','{"id":"m-expand-5","topic":"m-expand","prompt":"Expand 6(x + 3).","choices":["6x + 18","6x + 3","x + 18","9x"],"correct":0,"explanation":"Multiply both terms inside the bracket by 6: 6x + 18.","hint":"Every term inside must be multiplied.","passage":""}'::jsonb),
('m-expand-6','m-expand','{"id":"m-expand-6","topic":"m-expand","prompt":"Expand 7(x + 3).","choices":["7x + 3","x + 21","10x","7x + 21"],"correct":3,"explanation":"Multiply both terms inside the bracket by 7: 7x + 21.","hint":"Every term inside must be multiplied.","passage":""}'::jsonb),
('m-expand-7','m-expand','{"id":"m-expand-7","topic":"m-expand","prompt":"Expand 8(x + 3).","choices":["x + 24","11x","8x + 24","8x + 3"],"correct":2,"explanation":"Multiply both terms inside the bracket by 8: 8x + 24.","hint":"Every term inside must be multiplied.","passage":""}'::jsonb),
('m-expand-8','m-expand','{"id":"m-expand-8","topic":"m-expand","prompt":"Expand 9(x + 3).","choices":["12x","9x + 27","9x + 3","x + 27"],"correct":1,"explanation":"Multiply both terms inside the bracket by 9: 9x + 27.","hint":"Every term inside must be multiplied.","passage":""}'::jsonb),
('m-sequences-1','m-sequences','{"id":"m-sequences-1","topic":"m-sequences","prompt":"The sequence begins 4, 6, 8, 10. Which is its nth-term rule?","choices":["2n + 2","2n − 2","4n","2n + 3"],"correct":0,"explanation":"The common difference is 2. Multiples of 2 are each 2 less than the terms, so the rule is 2n + 2.","hint":"Find the common difference.","passage":""}'::jsonb),
('m-sequences-2','m-sequences','{"id":"m-sequences-2","topic":"m-sequences","prompt":"The sequence begins 5, 8, 11, 14. Which is its nth-term rule?","choices":["3n − 2","5n","3n + 3","3n + 2"],"correct":3,"explanation":"The common difference is 3. Multiples of 3 are each 2 less than the terms, so the rule is 3n + 2.","hint":"Find the common difference.","passage":""}'::jsonb),
('m-sequences-3','m-sequences','{"id":"m-sequences-3","topic":"m-sequences","prompt":"The sequence begins 6, 10, 14, 18. Which is its nth-term rule?","choices":["6n","4n + 3","4n + 2","4n − 2"],"correct":2,"explanation":"The common difference is 4. Multiples of 4 are each 2 less than the terms, so the rule is 4n + 2.","hint":"Find the common difference.","passage":""}'::jsonb),
('m-sequences-4','m-sequences','{"id":"m-sequences-4","topic":"m-sequences","prompt":"The sequence begins 7, 12, 17, 22. Which is its nth-term rule?","choices":["5n + 3","5n + 2","5n − 2","7n"],"correct":1,"explanation":"The common difference is 5. Multiples of 5 are each 2 less than the terms, so the rule is 5n + 2.","hint":"Find the common difference.","passage":""}'::jsonb),
('m-sequences-5','m-sequences','{"id":"m-sequences-5","topic":"m-sequences","prompt":"The sequence begins 8, 14, 20, 26. Which is its nth-term rule?","choices":["6n + 2","6n − 2","8n","6n + 3"],"correct":0,"explanation":"The common difference is 6. Multiples of 6 are each 2 less than the terms, so the rule is 6n + 2.","hint":"Find the common difference.","passage":""}'::jsonb),
('m-sequences-6','m-sequences','{"id":"m-sequences-6","topic":"m-sequences","prompt":"The sequence begins 9, 16, 23, 30. Which is its nth-term rule?","choices":["7n − 2","9n","7n + 3","7n + 2"],"correct":3,"explanation":"The common difference is 7. Multiples of 7 are each 2 less than the terms, so the rule is 7n + 2.","hint":"Find the common difference.","passage":""}'::jsonb),
('m-sequences-7','m-sequences','{"id":"m-sequences-7","topic":"m-sequences","prompt":"The sequence begins 10, 18, 26, 34. Which is its nth-term rule?","choices":["10n","8n + 3","8n + 2","8n − 2"],"correct":2,"explanation":"The common difference is 8. Multiples of 8 are each 2 less than the terms, so the rule is 8n + 2.","hint":"Find the common difference.","passage":""}'::jsonb),
('m-sequences-8','m-sequences','{"id":"m-sequences-8","topic":"m-sequences","prompt":"The sequence begins 11, 20, 29, 38. Which is its nth-term rule?","choices":["9n + 3","9n + 2","9n − 2","11n"],"correct":1,"explanation":"The common difference is 9. Multiples of 9 are each 2 less than the terms, so the rule is 9n + 2.","hint":"Find the common difference.","passage":""}'::jsonb),
('m-area-1','m-area','{"id":"m-area-1","topic":"m-area","prompt":"A triangle has base 6 cm and perpendicular height 5 cm. Find its area.","choices":["15 cm²","30 cm²","11 cm²","20 cm²"],"correct":0,"explanation":"Area = ½ × base × height = ½ × 6 × 5 = 15 cm².","hint":"A triangle is half of the matching rectangle.","passage":""}'::jsonb),
('m-area-2','m-area','{"id":"m-area-2","topic":"m-area","prompt":"A triangle has base 8 cm and perpendicular height 5 cm. Find its area.","choices":["40 cm²","13 cm²","25 cm²","20 cm²"],"correct":3,"explanation":"Area = ½ × base × height = ½ × 8 × 5 = 20 cm².","hint":"A triangle is half of the matching rectangle.","passage":""}'::jsonb),
('m-area-3','m-area','{"id":"m-area-3","topic":"m-area","prompt":"A triangle has base 10 cm and perpendicular height 5 cm. Find its area.","choices":["15 cm²","30 cm²","25 cm²","50 cm²"],"correct":2,"explanation":"Area = ½ × base × height = ½ × 10 × 5 = 25 cm².","hint":"A triangle is half of the matching rectangle.","passage":""}'::jsonb),
('m-area-4','m-area','{"id":"m-area-4","topic":"m-area","prompt":"A triangle has base 12 cm and perpendicular height 5 cm. Find its area.","choices":["35 cm²","30 cm²","60 cm²","17 cm²"],"correct":1,"explanation":"Area = ½ × base × height = ½ × 12 × 5 = 30 cm².","hint":"A triangle is half of the matching rectangle.","passage":""}'::jsonb),
('m-area-5','m-area','{"id":"m-area-5","topic":"m-area","prompt":"A triangle has base 14 cm and perpendicular height 5 cm. Find its area.","choices":["35 cm²","70 cm²","19 cm²","40 cm²"],"correct":0,"explanation":"Area = ½ × base × height = ½ × 14 × 5 = 35 cm².","hint":"A triangle is half of the matching rectangle.","passage":""}'::jsonb),
('m-area-6','m-area','{"id":"m-area-6","topic":"m-area","prompt":"A triangle has base 16 cm and perpendicular height 5 cm. Find its area.","choices":["80 cm²","21 cm²","45 cm²","40 cm²"],"correct":3,"explanation":"Area = ½ × base × height = ½ × 16 × 5 = 40 cm².","hint":"A triangle is half of the matching rectangle.","passage":""}'::jsonb),
('m-area-7','m-area','{"id":"m-area-7","topic":"m-area","prompt":"A triangle has base 18 cm and perpendicular height 5 cm. Find its area.","choices":["23 cm²","50 cm²","45 cm²","90 cm²"],"correct":2,"explanation":"Area = ½ × base × height = ½ × 18 × 5 = 45 cm².","hint":"A triangle is half of the matching rectangle.","passage":""}'::jsonb),
('m-area-8','m-area','{"id":"m-area-8","topic":"m-area","prompt":"A triangle has base 20 cm and perpendicular height 5 cm. Find its area.","choices":["55 cm²","50 cm²","100 cm²","25 cm²"],"correct":1,"explanation":"Area = ½ × base × height = ½ × 20 × 5 = 50 cm².","hint":"A triangle is half of the matching rectangle.","passage":""}'::jsonb),
('m-probability-1','m-probability','{"id":"m-probability-1","topic":"m-probability","prompt":"A bag has 2 red and 3 blue counters. A counter is chosen at random. What is P(red)?","choices":["2/5","3/5","2/3","1/5"],"correct":0,"explanation":"There are 2 favourable counters out of 5 counters altogether.","hint":"Probability = favourable outcomes ÷ all equally likely outcomes.","passage":""}'::jsonb),
('m-probability-2','m-probability','{"id":"m-probability-2","topic":"m-probability","prompt":"A bag has 3 red and 4 blue counters. A counter is chosen at random. What is P(red)?","choices":["4/7","3/4","1/7","3/7"],"correct":3,"explanation":"There are 3 favourable counters out of 7 counters altogether.","hint":"Probability = favourable outcomes ÷ all equally likely outcomes.","passage":""}'::jsonb),
('m-probability-3','m-probability','{"id":"m-probability-3","topic":"m-probability","prompt":"A bag has 4 red and 5 blue counters. A counter is chosen at random. What is P(red)?","choices":["4/5","1/9","4/9","5/9"],"correct":2,"explanation":"There are 4 favourable counters out of 9 counters altogether.","hint":"Probability = favourable outcomes ÷ all equally likely outcomes.","passage":""}'::jsonb),
('m-probability-4','m-probability','{"id":"m-probability-4","topic":"m-probability","prompt":"A bag has 5 red and 6 blue counters. A counter is chosen at random. What is P(red)?","choices":["1/11","5/11","6/11","5/6"],"correct":1,"explanation":"There are 5 favourable counters out of 11 counters altogether.","hint":"Probability = favourable outcomes ÷ all equally likely outcomes.","passage":""}'::jsonb),
('m-probability-5','m-probability','{"id":"m-probability-5","topic":"m-probability","prompt":"A bag has 6 red and 7 blue counters. A counter is chosen at random. What is P(red)?","choices":["6/13","7/13","6/7","1/13"],"correct":0,"explanation":"There are 6 favourable counters out of 13 counters altogether.","hint":"Probability = favourable outcomes ÷ all equally likely outcomes.","passage":""}'::jsonb),
('m-probability-6','m-probability','{"id":"m-probability-6","topic":"m-probability","prompt":"A bag has 7 red and 8 blue counters. A counter is chosen at random. What is P(red)?","choices":["8/15","7/8","1/15","7/15"],"correct":3,"explanation":"There are 7 favourable counters out of 15 counters altogether.","hint":"Probability = favourable outcomes ÷ all equally likely outcomes.","passage":""}'::jsonb),
('m-probability-7','m-probability','{"id":"m-probability-7","topic":"m-probability","prompt":"A bag has 8 red and 9 blue counters. A counter is chosen at random. What is P(red)?","choices":["8/9","1/17","8/17","9/17"],"correct":2,"explanation":"There are 8 favourable counters out of 17 counters altogether.","hint":"Probability = favourable outcomes ÷ all equally likely outcomes.","passage":""}'::jsonb),
('m-probability-8','m-probability','{"id":"m-probability-8","topic":"m-probability","prompt":"A bag has 9 red and 10 blue counters. A counter is chosen at random. What is P(red)?","choices":["1/19","9/19","10/19","9/10"],"correct":1,"explanation":"There are 9 favourable counters out of 19 counters altogether.","hint":"Probability = favourable outcomes ÷ all equally likely outcomes.","passage":""}'::jsonb),
('m-mean-1','m-mean','{"id":"m-mean-1","topic":"m-mean","prompt":"Find the mean of 1, 3, 5, 7.","choices":["4","3","5","16"],"correct":0,"explanation":"The sum is 16. Divide by 4 to get 4.","hint":"Add all values, then divide by how many there are.","passage":""}'::jsonb),
('m-mean-2','m-mean','{"id":"m-mean-2","topic":"m-mean","prompt":"Find the mean of 2, 4, 6, 8.","choices":["4","6","20","5"],"correct":3,"explanation":"The sum is 20. Divide by 4 to get 5.","hint":"Add all values, then divide by how many there are.","passage":""}'::jsonb),
('m-mean-3','m-mean','{"id":"m-mean-3","topic":"m-mean","prompt":"Find the mean of 3, 5, 7, 9.","choices":["7","24","6","5"],"correct":2,"explanation":"The sum is 24. Divide by 4 to get 6.","hint":"Add all values, then divide by how many there are.","passage":""}'::jsonb),
('m-mean-4','m-mean','{"id":"m-mean-4","topic":"m-mean","prompt":"Find the mean of 4, 6, 8, 10.","choices":["28","7","6","8"],"correct":1,"explanation":"The sum is 28. Divide by 4 to get 7.","hint":"Add all values, then divide by how many there are.","passage":""}'::jsonb),
('m-mean-5','m-mean','{"id":"m-mean-5","topic":"m-mean","prompt":"Find the mean of 5, 7, 9, 11.","choices":["8","7","9","32"],"correct":0,"explanation":"The sum is 32. Divide by 4 to get 8.","hint":"Add all values, then divide by how many there are.","passage":""}'::jsonb),
('m-mean-6','m-mean','{"id":"m-mean-6","topic":"m-mean","prompt":"Find the mean of 6, 8, 10, 12.","choices":["8","10","36","9"],"correct":3,"explanation":"The sum is 36. Divide by 4 to get 9.","hint":"Add all values, then divide by how many there are.","passage":""}'::jsonb),
('m-mean-7','m-mean','{"id":"m-mean-7","topic":"m-mean","prompt":"Find the mean of 7, 9, 11, 13.","choices":["11","40","10","9"],"correct":2,"explanation":"The sum is 40. Divide by 4 to get 10.","hint":"Add all values, then divide by how many there are.","passage":""}'::jsonb),
('m-mean-8','m-mean','{"id":"m-mean-8","topic":"m-mean","prompt":"Find the mean of 8, 10, 12, 14.","choices":["44","11","10","12"],"correct":1,"explanation":"The sum is 44. Divide by 4 to get 11.","hint":"Add all values, then divide by how many there are.","passage":""}'::jsonb),
('m-quadratic-1','m-quadratic','{"id":"m-quadratic-1","topic":"m-quadratic","prompt":"Factorise x² + 3x + 2.","choices":["(x + 1)(x + 2)","(x − 1)(x − 2)","(x + 2)(x + 2)","x(x + 3)"],"correct":0,"explanation":"The numbers 1 and 2 add to 3 and multiply to 2.","hint":"Find two numbers with the correct sum and product.","passage":""}'::jsonb),
('m-quadratic-2','m-quadratic','{"id":"m-quadratic-2","topic":"m-quadratic","prompt":"Factorise x² + 4x + 3.","choices":["(x − 1)(x − 3)","(x + 2)(x + 3)","x(x + 4)","(x + 1)(x + 3)"],"correct":3,"explanation":"The numbers 1 and 3 add to 4 and multiply to 3.","hint":"Find two numbers with the correct sum and product.","passage":""}'::jsonb),
('m-quadratic-3','m-quadratic','{"id":"m-quadratic-3","topic":"m-quadratic","prompt":"Factorise x² + 5x + 4.","choices":["(x + 2)(x + 4)","x(x + 5)","(x + 1)(x + 4)","(x − 1)(x − 4)"],"correct":2,"explanation":"The numbers 1 and 4 add to 5 and multiply to 4.","hint":"Find two numbers with the correct sum and product.","passage":""}'::jsonb),
('m-quadratic-4','m-quadratic','{"id":"m-quadratic-4","topic":"m-quadratic","prompt":"Factorise x² + 6x + 5.","choices":["x(x + 6)","(x + 1)(x + 5)","(x − 1)(x − 5)","(x + 2)(x + 5)"],"correct":1,"explanation":"The numbers 1 and 5 add to 6 and multiply to 5.","hint":"Find two numbers with the correct sum and product.","passage":""}'::jsonb),
('m-quadratic-5','m-quadratic','{"id":"m-quadratic-5","topic":"m-quadratic","prompt":"Factorise x² + 7x + 6.","choices":["(x + 1)(x + 6)","(x − 1)(x − 6)","(x + 2)(x + 6)","x(x + 7)"],"correct":0,"explanation":"The numbers 1 and 6 add to 7 and multiply to 6.","hint":"Find two numbers with the correct sum and product.","passage":""}'::jsonb),
('m-quadratic-6','m-quadratic','{"id":"m-quadratic-6","topic":"m-quadratic","prompt":"Factorise x² + 8x + 7.","choices":["(x − 1)(x − 7)","(x + 2)(x + 7)","x(x + 8)","(x + 1)(x + 7)"],"correct":3,"explanation":"The numbers 1 and 7 add to 8 and multiply to 7.","hint":"Find two numbers with the correct sum and product.","passage":""}'::jsonb),
('m-quadratic-7','m-quadratic','{"id":"m-quadratic-7","topic":"m-quadratic","prompt":"Factorise x² + 9x + 8.","choices":["(x + 2)(x + 8)","x(x + 9)","(x + 1)(x + 8)","(x − 1)(x − 8)"],"correct":2,"explanation":"The numbers 1 and 8 add to 9 and multiply to 8.","hint":"Find two numbers with the correct sum and product.","passage":""}'::jsonb),
('m-quadratic-8','m-quadratic','{"id":"m-quadratic-8","topic":"m-quadratic","prompt":"Factorise x² + 10x + 9.","choices":["x(x + 10)","(x + 1)(x + 9)","(x − 1)(x − 9)","(x + 2)(x + 9)"],"correct":1,"explanation":"The numbers 1 and 9 add to 10 and multiply to 9.","hint":"Find two numbers with the correct sum and product.","passage":""}'::jsonb),
('m-pythagoras-1','m-pythagoras','{"id":"m-pythagoras-1","topic":"m-pythagoras","prompt":"A right-angled triangle has shorter sides 3 cm and 4 cm. Find the hypotenuse.","choices":["5 cm","7 cm","1 cm","25 cm"],"correct":0,"explanation":"c² = 3² + 4² = 25, so c = 5 cm.","hint":"Square each shorter side, add, then square-root.","passage":""}'::jsonb),
('m-pythagoras-2','m-pythagoras','{"id":"m-pythagoras-2","topic":"m-pythagoras","prompt":"A right-angled triangle has shorter sides 6 cm and 8 cm. Find the hypotenuse.","choices":["14 cm","2 cm","50 cm","10 cm"],"correct":3,"explanation":"c² = 6² + 8² = 100, so c = 10 cm.","hint":"Square each shorter side, add, then square-root.","passage":""}'::jsonb),
('m-pythagoras-3','m-pythagoras','{"id":"m-pythagoras-3","topic":"m-pythagoras","prompt":"A right-angled triangle has shorter sides 9 cm and 12 cm. Find the hypotenuse.","choices":["3 cm","75 cm","15 cm","21 cm"],"correct":2,"explanation":"c² = 9² + 12² = 225, so c = 15 cm.","hint":"Square each shorter side, add, then square-root.","passage":""}'::jsonb),
('m-pythagoras-4','m-pythagoras','{"id":"m-pythagoras-4","topic":"m-pythagoras","prompt":"A right-angled triangle has shorter sides 12 cm and 16 cm. Find the hypotenuse.","choices":["100 cm","20 cm","28 cm","4 cm"],"correct":1,"explanation":"c² = 12² + 16² = 400, so c = 20 cm.","hint":"Square each shorter side, add, then square-root.","passage":""}'::jsonb),
('m-pythagoras-5','m-pythagoras','{"id":"m-pythagoras-5","topic":"m-pythagoras","prompt":"A right-angled triangle has shorter sides 15 cm and 20 cm. Find the hypotenuse.","choices":["25 cm","35 cm","5 cm","125 cm"],"correct":0,"explanation":"c² = 15² + 20² = 625, so c = 25 cm.","hint":"Square each shorter side, add, then square-root.","passage":""}'::jsonb),
('m-pythagoras-6','m-pythagoras','{"id":"m-pythagoras-6","topic":"m-pythagoras","prompt":"A right-angled triangle has shorter sides 18 cm and 24 cm. Find the hypotenuse.","choices":["42 cm","6 cm","150 cm","30 cm"],"correct":3,"explanation":"c² = 18² + 24² = 900, so c = 30 cm.","hint":"Square each shorter side, add, then square-root.","passage":""}'::jsonb),
('m-pythagoras-7','m-pythagoras','{"id":"m-pythagoras-7","topic":"m-pythagoras","prompt":"A right-angled triangle has shorter sides 21 cm and 28 cm. Find the hypotenuse.","choices":["7 cm","175 cm","35 cm","49 cm"],"correct":2,"explanation":"c² = 21² + 28² = 1225, so c = 35 cm.","hint":"Square each shorter side, add, then square-root.","passage":""}'::jsonb),
('m-pythagoras-8','m-pythagoras','{"id":"m-pythagoras-8","topic":"m-pythagoras","prompt":"A right-angled triangle has shorter sides 24 cm and 32 cm. Find the hypotenuse.","choices":["200 cm","40 cm","56 cm","8 cm"],"correct":1,"explanation":"c² = 24² + 32² = 1600, so c = 40 cm.","hint":"Square each shorter side, add, then square-root.","passage":""}'::jsonb),
('s-cells-1','s-cells','{"id":"s-cells-1","topic":"s-cells","prompt":"Which structure controls what enters and leaves a cell?","choices":["Cell membrane","Cell wall","Nucleus","Cytoplasm"],"correct":0,"explanation":"The cell membrane controls movement into and out of the cell.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-cells-2','s-cells','{"id":"s-cells-2","topic":"s-cells","prompt":"Where does most aerobic respiration occur in a eukaryotic cell?","choices":["Ribosomes","Vacuole","Cell wall","Mitochondria"],"correct":3,"explanation":"Mitochondria are the main site of aerobic respiration.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-cells-3','s-cells','{"id":"s-cells-3","topic":"s-cells","prompt":"Which structure contains chlorophyll?","choices":["Ribosome","Cell membrane","Chloroplast","Nucleus"],"correct":2,"explanation":"Chloroplasts contain chlorophyll, which absorbs light for photosynthesis.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-cells-4','s-cells','{"id":"s-cells-4","topic":"s-cells","prompt":"What is the function of ribosomes?","choices":["Transporting oxygen","Protein synthesis","Storing cell sap","Controlling light"],"correct":1,"explanation":"Ribosomes assemble proteins from amino acids.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-cells-5','s-cells','{"id":"s-cells-5","topic":"s-cells","prompt":"Which is found in a typical plant cell but not an animal cell?","choices":["Cellulose cell wall","Cytoplasm","Cell membrane","Mitochondria"],"correct":0,"explanation":"Plant cells have a cellulose cell wall that provides support.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-transport-1','s-transport','{"id":"s-transport-1","topic":"s-transport","prompt":"Diffusion is the net movement of particles…","choices":["From low to high concentration","Only through a cell wall","Only when energy is supplied","From high to low concentration"],"correct":3,"explanation":"Diffusion moves particles down a concentration gradient.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-transport-2','s-transport','{"id":"s-transport-2","topic":"s-transport","prompt":"Osmosis is the net movement of…","choices":["Salt through any wall","Oxygen into blood only","Water through a partially permeable membrane","Proteins into the nucleus"],"correct":2,"explanation":"Osmosis describes water movement through a partially permeable membrane from a dilute to a more concentrated solution.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-transport-3','s-transport','{"id":"s-transport-3","topic":"s-transport","prompt":"Which process requires energy from respiration?","choices":["Evaporation","Active transport","Diffusion","Osmosis"],"correct":1,"explanation":"Active transport uses energy to move substances against a concentration gradient.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-transport-4','s-transport','{"id":"s-transport-4","topic":"s-transport","prompt":"Which change usually increases the rate of diffusion?","choices":["A steeper concentration gradient","A thicker membrane","A smaller surface area","A lower temperature"],"correct":0,"explanation":"A greater difference in concentration increases the net diffusion rate.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-transport-5','s-transport','{"id":"s-transport-5","topic":"s-transport","prompt":"Root hair cells are adapted for absorption by having…","choices":["No cell membrane","Chloroplasts in every root hair","A thick wax layer","A large surface area"],"correct":3,"explanation":"Their long extension provides a large surface area for absorption.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-enzymes-1','s-enzymes','{"id":"s-enzymes-1","topic":"s-enzymes","prompt":"Enzymes are biological…","choices":["Elements","Hormones only","Catalysts","Antibiotics"],"correct":2,"explanation":"Enzymes speed up reactions without being used up.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-enzymes-2','s-enzymes','{"id":"s-enzymes-2","topic":"s-enzymes","prompt":"Amylase breaks down…","choices":["Cellulose in humans","Starch","Protein","Lipid"],"correct":1,"explanation":"Amylase catalyses the breakdown of starch into sugars.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-enzymes-3','s-enzymes','{"id":"s-enzymes-3","topic":"s-enzymes","prompt":"Proteases break proteins into…","choices":["Amino acids","Fatty acids","Starch","Glycerol only"],"correct":0,"explanation":"Proteases break proteins down into amino acids.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-enzymes-4','s-enzymes','{"id":"s-enzymes-4","topic":"s-enzymes","prompt":"Why can a very high temperature stop an enzyme working?","choices":["Its substrate becomes a metal","It gains a cell wall","It turns into glucose","The active site changes shape"],"correct":3,"explanation":"High temperatures can denature the enzyme, changing its active site.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-enzymes-5','s-enzymes','{"id":"s-enzymes-5","topic":"s-enzymes","prompt":"Bile helps digestion by…","choices":["Producing starch","Absorbing all glucose","Emulsifying fats and neutralising acid","Digesting proteins enzymatically"],"correct":2,"explanation":"Bile is alkaline and emulsifies fats, increasing their surface area.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-photosynthesis-1','s-photosynthesis','{"id":"s-photosynthesis-1","topic":"s-photosynthesis","prompt":"Which gas is a reactant in photosynthesis?","choices":["Helium","Carbon dioxide","Oxygen","Nitrogen"],"correct":1,"explanation":"Plants use carbon dioxide and water to make glucose and oxygen.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-photosynthesis-2','s-photosynthesis','{"id":"s-photosynthesis-2","topic":"s-photosynthesis","prompt":"Which substance absorbs light for photosynthesis?","choices":["Chlorophyll","Haemoglobin","Amylase","Insulin"],"correct":0,"explanation":"Chlorophyll absorbs light energy.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-photosynthesis-3','s-photosynthesis','{"id":"s-photosynthesis-3","topic":"s-photosynthesis","prompt":"Which carbohydrate is produced directly in the usual word equation?","choices":["Starch","Cellulose","Glycogen","Glucose"],"correct":3,"explanation":"The standard word equation has glucose and oxygen as products.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-photosynthesis-4','s-photosynthesis','{"id":"s-photosynthesis-4","topic":"s-photosynthesis","prompt":"Photosynthesis is…","choices":["A type of combustion","A form of digestion","Endothermic","Always exothermic"],"correct":2,"explanation":"Photosynthesis transfers energy from the surroundings using light.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-photosynthesis-5','s-photosynthesis','{"id":"s-photosynthesis-5","topic":"s-photosynthesis","prompt":"At low light intensity, which change may increase photosynthesis?","choices":["Destroying chloroplasts","Increasing light intensity","Removing all water","Removing carbon dioxide"],"correct":1,"explanation":"Increasing a limiting factor such as light can increase the rate.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-inheritance-1','s-inheritance','{"id":"s-inheritance-1","topic":"s-inheritance","prompt":"A gene is a section of…","choices":["DNA","Starch","Lipid","Cellulose"],"correct":0,"explanation":"A gene is a section of DNA that codes for a functional product, often a protein.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-inheritance-2','s-inheritance','{"id":"s-inheritance-2","topic":"s-inheritance","prompt":"Different versions of a gene are called…","choices":["Enzymes","Tissues","Gametes","Alleles"],"correct":3,"explanation":"Alleles are alternative forms of a gene.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-inheritance-3','s-inheritance','{"id":"s-inheritance-3","topic":"s-inheritance","prompt":"Which genotype is heterozygous?","choices":["bb","XX","Bb","BB"],"correct":2,"explanation":"Heterozygous means having two different alleles for a gene.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-inheritance-4','s-inheritance','{"id":"s-inheritance-4","topic":"s-inheritance","prompt":"Human gametes normally contain how many chromosomes?","choices":["92","23","46","12"],"correct":1,"explanation":"Gametes contain one set of 23 chromosomes.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-inheritance-5','s-inheritance','{"id":"s-inheritance-5","topic":"s-inheritance","prompt":"For Bb × Bb, what is the probability of bb?","choices":["1/4","1/2","3/4","1"],"correct":0,"explanation":"The four equally likely combinations are BB, Bb, Bb and bb.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-atoms-1','s-atoms','{"id":"s-atoms-1","topic":"s-atoms","prompt":"Which particle has a negative charge?","choices":["Proton","Neutron","Nucleus","Electron"],"correct":3,"explanation":"Electrons have a relative charge of −1.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-atoms-2','s-atoms','{"id":"s-atoms-2","topic":"s-atoms","prompt":"The atomic number equals the number of…","choices":["Protons plus neutrons","Electron shells","Protons","Neutrons only"],"correct":2,"explanation":"The proton number defines the element.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-atoms-3','s-atoms','{"id":"s-atoms-3","topic":"s-atoms","prompt":"Isotopes of an element have different numbers of…","choices":["Protons in each nucleus","Neutrons","Protons","Nuclei"],"correct":1,"explanation":"Isotopes have the same proton number but different neutron numbers.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-atoms-4','s-atoms','{"id":"s-atoms-4","topic":"s-atoms","prompt":"Elements in the same group usually have the same number of…","choices":["Outer-shell electrons","Neutrons","Electron shells","Protons"],"correct":0,"explanation":"For the main groups, similar outer electron arrangements give similar chemical properties.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-atoms-5','s-atoms','{"id":"s-atoms-5","topic":"s-atoms","prompt":"A neutral atom has equal numbers of…","choices":["Protons and neutrons","Neutrons and electrons always","Shells and protons","Protons and electrons"],"correct":3,"explanation":"Equal positive and negative charges make the atom neutral.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-bonding-1','s-bonding','{"id":"s-bonding-1","topic":"s-bonding","prompt":"An ionic bond is an attraction between…","choices":["Two identical charges","Two nuclei without electrons","Oppositely charged ions","Two neutrons"],"correct":2,"explanation":"Ionic bonding is a strong electrostatic attraction between oppositely charged ions.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-bonding-2','s-bonding','{"id":"s-bonding-2","topic":"s-bonding","prompt":"A covalent bond involves…","choices":["Only metal atoms","A shared pair of electrons","A transferred pair of protons","Shared neutrons"],"correct":1,"explanation":"Covalent bonds form when atoms share electron pairs.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-bonding-3','s-bonding','{"id":"s-bonding-3","topic":"s-bonding","prompt":"Metallic bonding involves positive ions and…","choices":["Delocalised electrons","Free neutrons","Negative protons","Water molecules"],"correct":0,"explanation":"Metals contain a lattice of positive ions attracted to delocalised electrons.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-bonding-4','s-bonding','{"id":"s-bonding-4","topic":"s-bonding","prompt":"Why can molten ionic compounds conduct electricity?","choices":["Their protons leave nuclei","They have no charges","All their atoms become metals","Their ions can move"],"correct":3,"explanation":"Mobile ions carry charge in molten ionic compounds.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-bonding-5','s-bonding','{"id":"s-bonding-5","topic":"s-bonding","prompt":"Diamond is very hard because it has…","choices":["Only ionic bonds","Layers that slide easily","Many strong covalent bonds in a giant structure","Weak forces between small molecules"],"correct":2,"explanation":"Each carbon bonds to four others in a rigid giant covalent structure.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-acids-1','s-acids','{"id":"s-acids-1","topic":"s-acids","prompt":"A solution with pH 2 is…","choices":["Always pure water","Acidic","Neutral","Alkaline"],"correct":1,"explanation":"A pH below 7 indicates an acidic aqueous solution.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-acids-2','s-acids','{"id":"s-acids-2","topic":"s-acids","prompt":"Acid + alkali produces…","choices":["Salt and water","Metal and oxygen","Hydrogen and carbon","Only carbon dioxide"],"correct":0,"explanation":"Neutralisation produces a salt and water.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-acids-3','s-acids','{"id":"s-acids-3","topic":"s-acids","prompt":"Which ion makes aqueous solutions acidic?","choices":["OH⁻","Na⁺","Cl⁻","H⁺"],"correct":3,"explanation":"Acids produce hydrogen ions in aqueous solution.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-acids-4','s-acids','{"id":"s-acids-4","topic":"s-acids","prompt":"An acid reacting with a carbonate usually releases…","choices":["Nitrogen","Chlorine","Carbon dioxide","Oxygen"],"correct":2,"explanation":"Acid + carbonate produces salt, water and carbon dioxide.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-acids-5','s-acids','{"id":"s-acids-5","topic":"s-acids","prompt":"Hydrochloric acid produces salts called…","choices":["Carbonates","Chlorides","Sulfates","Nitrates"],"correct":1,"explanation":"The acid supplies chloride ions, forming chloride salts.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-energy-1','s-energy','{"id":"s-energy-1","topic":"s-energy","prompt":"A moving object has energy in its…","choices":["Kinetic store","Chemical store only","Nuclear store only","Magnetic store only"],"correct":0,"explanation":"The kinetic energy store is associated with movement.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-energy-2','s-energy','{"id":"s-energy-2","topic":"s-energy","prompt":"Lifting a book increases its…","choices":["Chemical mass","Electrical charge necessarily","Nuclear energy store","Gravitational potential energy store"],"correct":3,"explanation":"Energy is transferred to the gravitational potential store as height increases.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-energy-3','s-energy','{"id":"s-energy-3","topic":"s-energy","prompt":"Energy is measured in…","choices":["Newtons","Amperes","Joules","Watts"],"correct":2,"explanation":"The joule is the SI unit of energy.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-energy-4','s-energy','{"id":"s-energy-4","topic":"s-energy","prompt":"Efficiency is useful output energy divided by…","choices":["Useful output power only","Total input energy","Time only","Mass only"],"correct":1,"explanation":"Efficiency compares useful output with total input, often expressed as a percentage.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-energy-5','s-energy','{"id":"s-energy-5","topic":"s-energy","prompt":"An appliance transfers 200 J usefully from 500 J input. Its efficiency is…","choices":["40%","60%","250%","20%"],"correct":0,"explanation":"200 ÷ 500 × 100 = 40%.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-electricity-1','s-electricity','{"id":"s-electricity-1","topic":"s-electricity","prompt":"Current is measured in…","choices":["Volts","Ohms","Joules","Amperes"],"correct":3,"explanation":"Current is the rate of charge flow, measured in amperes.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-electricity-2','s-electricity','{"id":"s-electricity-2","topic":"s-electricity","prompt":"Which equation links potential difference, current and resistance?","choices":["V = R/I","V = I + R","V = IR","V = I/R"],"correct":2,"explanation":"Potential difference equals current multiplied by resistance.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-electricity-3','s-electricity','{"id":"s-electricity-3","topic":"s-electricity","prompt":"A 6 Ω resistor carries 2 A. What is the potential difference?","choices":["4 V","12 V","3 V","8 V"],"correct":1,"explanation":"V = IR = 2 × 6 = 12 V.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-electricity-4','s-electricity','{"id":"s-electricity-4","topic":"s-electricity","prompt":"In a series circuit the current is…","choices":["The same at every point","Used up by the first bulb","Zero after each resistor","Always 1 A"],"correct":0,"explanation":"Charge flow is the same throughout a single series loop.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-electricity-5','s-electricity','{"id":"s-electricity-5","topic":"s-electricity","prompt":"A voltmeter is connected…","choices":["In series only","Instead of the power supply","Across an open switch only","In parallel with a component"],"correct":3,"explanation":"A voltmeter measures potential difference across a component.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-forces-1','s-forces','{"id":"s-forces-1","topic":"s-forces","prompt":"Force is measured in…","choices":["Watts","Metres","Newtons","Joules"],"correct":2,"explanation":"The SI unit of force is the newton.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-forces-2','s-forces','{"id":"s-forces-2","topic":"s-forces","prompt":"A 4 kg object accelerates at 3 m/s². Its resultant force is…","choices":["24 N","12 N","7 N","1.33 N"],"correct":1,"explanation":"F = ma = 4 × 3 = 12 N.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-forces-3','s-forces','{"id":"s-forces-3","topic":"s-forces","prompt":"With zero resultant force, a moving object…","choices":["Continues at constant velocity","Must stop immediately","Must speed up","Must move in a circle"],"correct":0,"explanation":"Zero resultant force means zero acceleration.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-forces-4','s-forces','{"id":"s-forces-4","topic":"s-forces","prompt":"Speed is calculated using…","choices":["Time ÷ distance","Distance × time","Mass ÷ time","Distance ÷ time"],"correct":3,"explanation":"Average speed is distance travelled divided by time taken.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-forces-5','s-forces','{"id":"s-forces-5","topic":"s-forces","prompt":"Weight is a force caused by…","choices":["Temperature alone","Electrical insulation","Gravity","Volume alone"],"correct":2,"explanation":"Weight is the gravitational force on a mass.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-waves-1','s-waves','{"id":"s-waves-1","topic":"s-waves","prompt":"Frequency is measured in…","choices":["Newtons","Hertz","Metres","Seconds"],"correct":1,"explanation":"Hertz means cycles per second.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-waves-2','s-waves','{"id":"s-waves-2","topic":"s-waves","prompt":"Wave speed equals…","choices":["Frequency × wavelength","Frequency ÷ wavelength","Wavelength ÷ frequency","Amplitude × time"],"correct":0,"explanation":"v = fλ.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-waves-3','s-waves','{"id":"s-waves-3","topic":"s-waves","prompt":"Sound in air is a…","choices":["Transverse electromagnetic wave","Vacuum-only wave","Stationary particle","Longitudinal wave"],"correct":3,"explanation":"Sound travels through compressions and rarefactions parallel to the direction of travel.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-waves-4','s-waves','{"id":"s-waves-4","topic":"s-waves","prompt":"Which can travel through a vacuum?","choices":["Water surface waves","Seismic P waves","Light","Sound in air"],"correct":2,"explanation":"Electromagnetic waves, including light, do not require a material medium.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('s-waves-5','s-waves','{"id":"s-waves-5","topic":"s-waves","prompt":"Increasing sound-wave amplitude usually increases…","choices":["Wave speed in the same air","Loudness","Pitch","Frequency"],"correct":1,"explanation":"Amplitude relates to loudness; frequency relates to pitch.","hint":"Think about the definition or relationship in the question.","passage":""}'::jsonb),
('r-inference-1','r-inference','{"id":"r-inference-1","topic":"r-inference","prompt":"What is most strongly suggested about Mara?","choices":["She feels nervous about arriving","She is angry with the guests","She has forgotten the address","She is leaving a familiar workplace"],"correct":0,"explanation":"Her repeated checking and hesitation suggest nervousness.","hint":"Return to the passage and find the detail that supports your choice.","passage":"Mara reached the gate five minutes early. She checked the invitation again, smoothing a corner that had already gone soft. Behind the glass doors, strangers laughed. She raised her hand towards the bell, then stopped to straighten her coat. When the door opened, she smiled before anyone spoke."}'::jsonb),
('r-inference-2','r-inference','{"id":"r-inference-2","topic":"r-inference","prompt":"Which detail best supports the idea that Mara has checked the invitation repeatedly?","choices":["Strangers laughed","The door opened","She smiled","A corner had already gone soft"],"correct":3,"explanation":"The worn corner suggests repeated handling.","hint":"Return to the passage and find the detail that supports your choice.","passage":"Mara reached the gate five minutes early. She checked the invitation again, smoothing a corner that had already gone soft. Behind the glass doors, strangers laughed. She raised her hand towards the bell, then stopped to straighten her coat. When the door opened, she smiled before anyone spoke."}'::jsonb),
('r-inference-3','r-inference','{"id":"r-inference-3","topic":"r-inference","prompt":"What does “strangers” suggest about Mara’s relationship to those inside?","choices":["They are threatening her","They have invited nobody","She does not know them","They are her relatives"],"correct":2,"explanation":"The word indicates unfamiliar people, without proving hostility.","hint":"Return to the passage and find the detail that supports your choice.","passage":"Mara reached the gate five minutes early. She checked the invitation again, smoothing a corner that had already gone soft. Behind the glass doors, strangers laughed. She raised her hand towards the bell, then stopped to straighten her coat. When the door opened, she smiled before anyone spoke."}'::jsonb),
('r-inference-4','r-inference','{"id":"r-inference-4","topic":"r-inference","prompt":"Which action delays Mara ringing the bell?","choices":["Speaking to a guest","Straightening her coat","Losing her invitation","Closing the gate"],"correct":1,"explanation":"She stops her hand to straighten her coat.","hint":"Return to the passage and find the detail that supports your choice.","passage":"Mara reached the gate five minutes early. She checked the invitation again, smoothing a corner that had already gone soft. Behind the glass doors, strangers laughed. She raised her hand towards the bell, then stopped to straighten her coat. When the door opened, she smiled before anyone spoke."}'::jsonb),
('r-inference-5','r-inference','{"id":"r-inference-5","topic":"r-inference","prompt":"Which statement is a fact explicitly given in the passage?","choices":["Mara arrives five minutes early","Mara dislikes every guest","Mara has never attended a party","The host is her teacher"],"correct":0,"explanation":"The first sentence states her arrival time directly.","hint":"Return to the passage and find the detail that supports your choice.","passage":"Mara reached the gate five minutes early. She checked the invitation again, smoothing a corner that had already gone soft. Behind the glass doors, strangers laughed. She raised her hand towards the bell, then stopped to straighten her coat. When the door opened, she smiled before anyone spoke."}'::jsonb),
('r-language-1','r-language','{"id":"r-language-1","topic":"r-language","prompt":"“The harbour shook itself awake” is an example of…","choices":["A direct quotation from Jonah","A statistic","A literal description of a person","Personification"],"correct":3,"explanation":"A place is given the human action of waking.","hint":"Return to the passage and find the detail that supports your choice.","passage":"At dawn, the harbour shook itself awake. Ropes creaked against wet posts, and the sea tapped patiently at the stone steps. Beyond the wall, fishing boats wore small crowns of gulls. Jonah pulled his scarf higher. The wind slipped cold fingers beneath his collar, but a ribbon of sunlight had begun to unroll across the water."}'::jsonb),
('r-language-2','r-language','{"id":"r-language-2","topic":"r-language","prompt":"What does “crowns of gulls” most likely describe?","choices":["Painted royal symbols","Birds wearing metal crowns","Gulls gathered above or on boats","Jewels stored in boats"],"correct":2,"explanation":"The image compares the arrangement of gulls to crowns.","hint":"Return to the passage and find the detail that supports your choice.","passage":"At dawn, the harbour shook itself awake. Ropes creaked against wet posts, and the sea tapped patiently at the stone steps. Beyond the wall, fishing boats wore small crowns of gulls. Jonah pulled his scarf higher. The wind slipped cold fingers beneath his collar, but a ribbon of sunlight had begun to unroll across the water."}'::jsonb),
('r-language-3','r-language','{"id":"r-language-3","topic":"r-language","prompt":"Which detail appeals most directly to hearing?","choices":["A ribbon of sunlight","Ropes creaked","Wet posts","Small crowns"],"correct":1,"explanation":"Creaking is a sound.","hint":"Return to the passage and find the detail that supports your choice.","passage":"At dawn, the harbour shook itself awake. Ropes creaked against wet posts, and the sea tapped patiently at the stone steps. Beyond the wall, fishing boats wore small crowns of gulls. Jonah pulled his scarf higher. The wind slipped cold fingers beneath his collar, but a ribbon of sunlight had begun to unroll across the water."}'::jsonb),
('r-language-4','r-language','{"id":"r-language-4","topic":"r-language","prompt":"What does “cold fingers” emphasise about the wind?","choices":["It reaches uncomfortably into Jonah’s clothing","It is warm and gentle","It has stopped blowing","It is literally human"],"correct":0,"explanation":"The personification makes the cold feel intrusive and physical.","hint":"Return to the passage and find the detail that supports your choice.","passage":"At dawn, the harbour shook itself awake. Ropes creaked against wet posts, and the sea tapped patiently at the stone steps. Beyond the wall, fishing boats wore small crowns of gulls. Jonah pulled his scarf higher. The wind slipped cold fingers beneath his collar, but a ribbon of sunlight had begun to unroll across the water."}'::jsonb),
('r-language-5','r-language','{"id":"r-language-5","topic":"r-language","prompt":"Which change happens near the end?","choices":["The harbour becomes empty","Jonah takes off his scarf","The gulls disappear","Sunlight begins spreading across the water"],"correct":3,"explanation":"The final image describes increasing sunlight.","hint":"Return to the passage and find the detail that supports your choice.","passage":"At dawn, the harbour shook itself awake. Ropes creaked against wet posts, and the sea tapped patiently at the stone steps. Beyond the wall, fishing boats wore small crowns of gulls. Jonah pulled his scarf higher. The wind slipped cold fingers beneath his collar, but a ribbon of sunlight had begun to unroll across the water."}'::jsonb),
('r-retrieval-1','r-retrieval','{"id":"r-retrieval-1","topic":"r-retrieval","prompt":"When does the café take place?","choices":["The last Sunday of each month","Every weekday","The first Saturday of each month","Every Saturday evening"],"correct":2,"explanation":"The opening sentence gives the schedule.","hint":"Return to the passage and find the detail that supports your choice.","passage":"The Oak Street library will open its repair café on the first Saturday of each month, from 10 am until 1 pm. Volunteers will help visitors repair small household items. Electrical items must be checked by a trained volunteer before any work begins. There is no entry charge, but replacement parts may cost money. Visitors should book a thirty-minute slot and describe the fault in advance. The café cannot accept large appliances such as washing machines."}'::jsonb),
('r-retrieval-2','r-retrieval','{"id":"r-retrieval-2","topic":"r-retrieval","prompt":"How long is each booked slot?","choices":["Three hours","Thirty minutes","Ten minutes","One hour"],"correct":1,"explanation":"Visitors should book a thirty-minute slot.","hint":"Return to the passage and find the detail that supports your choice.","passage":"The Oak Street library will open its repair café on the first Saturday of each month, from 10 am until 1 pm. Volunteers will help visitors repair small household items. Electrical items must be checked by a trained volunteer before any work begins. There is no entry charge, but replacement parts may cost money. Visitors should book a thirty-minute slot and describe the fault in advance. The café cannot accept large appliances such as washing machines."}'::jsonb),
('r-retrieval-3','r-retrieval','{"id":"r-retrieval-3","topic":"r-retrieval","prompt":"Which item is explicitly not accepted?","choices":["A washing machine","A small lamp","A loose drawer handle","A torn cushion"],"correct":0,"explanation":"Washing machines are given as an example of large appliances the café cannot accept.","hint":"Return to the passage and find the detail that supports your choice.","passage":"The Oak Street library will open its repair café on the first Saturday of each month, from 10 am until 1 pm. Volunteers will help visitors repair small household items. Electrical items must be checked by a trained volunteer before any work begins. There is no entry charge, but replacement parts may cost money. Visitors should book a thirty-minute slot and describe the fault in advance. The café cannot accept large appliances such as washing machines."}'::jsonb),
('r-retrieval-4','r-retrieval','{"id":"r-retrieval-4","topic":"r-retrieval","prompt":"What may visitors need to pay for?","choices":["Entry to the library","Every volunteer’s travel","A compulsory membership","Replacement parts"],"correct":3,"explanation":"Entry is free, but replacement parts may cost money.","hint":"Return to the passage and find the detail that supports your choice.","passage":"The Oak Street library will open its repair café on the first Saturday of each month, from 10 am until 1 pm. Volunteers will help visitors repair small household items. Electrical items must be checked by a trained volunteer before any work begins. There is no entry charge, but replacement parts may cost money. Visitors should book a thirty-minute slot and describe the fault in advance. The café cannot accept large appliances such as washing machines."}'::jsonb),
('r-retrieval-5','r-retrieval','{"id":"r-retrieval-5","topic":"r-retrieval","prompt":"What must happen before work on an electrical item?","choices":["It must be left for a month","Any visitor must dismantle it","A trained volunteer must check it","The visitor must buy a new one"],"correct":2,"explanation":"The passage explicitly requires a trained volunteer’s check.","hint":"Return to the passage and find the detail that supports your choice.","passage":"The Oak Street library will open its repair café on the first Saturday of each month, from 10 am until 1 pm. Volunteers will help visitors repair small household items. Electrical items must be checked by a trained volunteer before any work begins. There is no entry charge, but replacement parts may cost money. Visitors should book a thirty-minute slot and describe the fault in advance. The café cannot accept large appliances such as washing machines."}'::jsonb),
('r-argument-1','r-argument','{"id":"r-argument-1","topic":"r-argument","prompt":"What is the writer’s main purpose?","choices":["To advertise a specific company","To persuade readers to support more shade","To describe a historical forest","To ban all outdoor activities"],"correct":1,"explanation":"The writer presents a problem, proposes action and asks readers to support it.","hint":"Return to the passage and find the detail that supports your choice.","passage":"Our playground needs more shade. On hot days, the few benches beneath the tree fill quickly, leaving many pupils sitting beside the wall. Planting more trees would take time, so shade sails could offer a useful first step. They would not solve every problem: the school would need to check costs and arrange maintenance. Even so, providing a comfortable outdoor space should be a priority. Let us ask the school council to investigate the options this term."}'::jsonb),
('r-argument-2','r-argument','{"id":"r-argument-2","topic":"r-argument","prompt":"Why does the writer mention costs and maintenance?","choices":["To acknowledge practical limitations","To prove shade is impossible","To change the subject entirely","To claim trees require no care"],"correct":0,"explanation":"Acknowledging drawbacks makes the proposal more balanced.","hint":"Return to the passage and find the detail that supports your choice.","passage":"Our playground needs more shade. On hot days, the few benches beneath the tree fill quickly, leaving many pupils sitting beside the wall. Planting more trees would take time, so shade sails could offer a useful first step. They would not solve every problem: the school would need to check costs and arrange maintenance. Even so, providing a comfortable outdoor space should be a priority. Let us ask the school council to investigate the options this term."}'::jsonb),
('r-argument-3','r-argument','{"id":"r-argument-3","topic":"r-argument","prompt":"What action does the writer ask for?","choices":["Remove the existing tree today","Cancel every break time","Buy sails immediately without checks","Ask the school council to investigate"],"correct":3,"explanation":"The last sentence asks for investigation this term.","hint":"Return to the passage and find the detail that supports your choice.","passage":"Our playground needs more shade. On hot days, the few benches beneath the tree fill quickly, leaving many pupils sitting beside the wall. Planting more trees would take time, so shade sails could offer a useful first step. They would not solve every problem: the school would need to check costs and arrange maintenance. Even so, providing a comfortable outdoor space should be a priority. Let us ask the school council to investigate the options this term."}'::jsonb),
('r-argument-4','r-argument','{"id":"r-argument-4","topic":"r-argument","prompt":"Which phrase most clearly expresses a judgement?","choices":["This term","Beside the wall","Should be a priority","Beneath the tree"],"correct":2,"explanation":"“Should” communicates what the writer believes ought to happen.","hint":"Return to the passage and find the detail that supports your choice.","passage":"Our playground needs more shade. On hot days, the few benches beneath the tree fill quickly, leaving many pupils sitting beside the wall. Planting more trees would take time, so shade sails could offer a useful first step. They would not solve every problem: the school would need to check costs and arrange maintenance. Even so, providing a comfortable outdoor space should be a priority. Let us ask the school council to investigate the options this term."}'::jsonb),
('r-argument-5','r-argument','{"id":"r-argument-5","topic":"r-argument","prompt":"Why are shade sails suggested as a first step?","choices":["The benches are all broken","Trees would take time to grow","Trees never provide shade","Sails need no maintenance"],"correct":1,"explanation":"The writer contrasts the time required for trees with an earlier practical step.","hint":"Return to the passage and find the detail that supports your choice.","passage":"Our playground needs more shade. On hot days, the few benches beneath the tree fill quickly, leaving many pupils sitting beside the wall. Planting more trees would take time, so shade sails could offer a useful first step. They would not solve every problem: the school would need to check costs and arrange maintenance. Even so, providing a comfortable outdoor space should be a priority. Let us ask the school council to investigate the options this term."}'::jsonb),
('r-structure-1','r-structure','{"id":"r-structure-1","topic":"r-structure","prompt":"What changes between the first and second sentences?","choices":["A familiar routine is interrupted","Ben leaves the town forever","The story moves into the future","The shop closes for the first time"],"correct":0,"explanation":"His usual habit of hurrying past changes when he notices yellow.","hint":"Return to the passage and find the detail that supports your choice.","passage":"For years, Ben had hurried past the boarded shop without looking up. Today, a splash of yellow stopped him. The boards were gone. Through the new window he could see shelves, a low counter and a ladder balanced beside a half-painted wall. He remembered buying warm bread there with his grandfather, long before the shutters closed. A woman inside lifted a paintbrush in greeting. Ben raised his hand and crossed the road."}'::jsonb),
('r-structure-2','r-structure','{"id":"r-structure-2","topic":"r-structure","prompt":"Which detail introduces a memory?","choices":["A woman lifts a paintbrush","Ben crosses the road","There is a ladder","Buying bread with his grandfather"],"correct":3,"explanation":"The bread-buying event belongs to an earlier time.","hint":"Return to the passage and find the detail that supports your choice.","passage":"For years, Ben had hurried past the boarded shop without looking up. Today, a splash of yellow stopped him. The boards were gone. Through the new window he could see shelves, a low counter and a ladder balanced beside a half-painted wall. He remembered buying warm bread there with his grandfather, long before the shutters closed. A woman inside lifted a paintbrush in greeting. Ben raised his hand and crossed the road."}'::jsonb),
('r-structure-3','r-structure','{"id":"r-structure-3","topic":"r-structure","prompt":"How does Ben’s behaviour at the end contrast with the beginning?","choices":["He closes the window","He paints the boards","He approaches rather than ignores the shop","He runs away instead of walking"],"correct":2,"explanation":"At first he passes without looking; at the end he crosses towards it.","hint":"Return to the passage and find the detail that supports your choice.","passage":"For years, Ben had hurried past the boarded shop without looking up. Today, a splash of yellow stopped him. The boards were gone. Through the new window he could see shelves, a low counter and a ladder balanced beside a half-painted wall. He remembered buying warm bread there with his grandfather, long before the shutters closed. A woman inside lifted a paintbrush in greeting. Ben raised his hand and crossed the road."}'::jsonb),
('r-structure-4','r-structure','{"id":"r-structure-4","topic":"r-structure","prompt":"What does the half-painted wall suggest?","choices":["There has been a fire","Work on the shop is still in progress","The shop has no owner","The shop is permanently abandoned"],"correct":1,"explanation":"The unfinished painting suggests ongoing preparation.","hint":"Return to the passage and find the detail that supports your choice.","passage":"For years, Ben had hurried past the boarded shop without looking up. Today, a splash of yellow stopped him. The boards were gone. Through the new window he could see shelves, a low counter and a ladder balanced beside a half-painted wall. He remembered buying warm bread there with his grandfather, long before the shutters closed. A woman inside lifted a paintbrush in greeting. Ben raised his hand and crossed the road."}'::jsonb),
('r-structure-5','r-structure','{"id":"r-structure-5","topic":"r-structure","prompt":"Which description best fits the passage’s sequence?","choices":["Habit, discovery, memory, response","Argument, statistics, conclusion, warning","Dream, battle, escape, punishment","Instructions in chronological steps"],"correct":0,"explanation":"The passage moves from routine to change, recalls the past, then shows Ben’s response.","hint":"Return to the passage and find the detail that supports your choice.","passage":"For years, Ben had hurried past the boarded shop without looking up. Today, a splash of yellow stopped him. The boards were gone. Through the new window he could see shelves, a low counter and a ladder balanced beside a half-painted wall. He remembered buying warm bread there with his grandfather, long before the shutters closed. A woman inside lifted a paintbrush in greeting. Ben raised his hand and crossed the road."}'::jsonb),
('r-vocabulary-1','r-vocabulary','{"id":"r-vocabulary-1","topic":"r-vocabulary","prompt":"“Proceeded” most nearly means…","choices":["Argued loudly","Fell asleep","Turned invisible","Moved onwards"],"correct":3,"explanation":"In context, the walkers continued along the path.","hint":"Return to the passage and find the detail that supports your choice.","passage":"The path was narrow, so the walkers proceeded in single file. Leila paused beside a weathered sign. Its letters were faint, but the arrow was still visible. “We should be cautious,” she said, pointing to loose stones near the edge. Tom, usually impatient, nodded and waited while she checked the map. Their progress was slow, but neither wanted to take an unnecessary risk."}'::jsonb),
('r-vocabulary-2','r-vocabulary','{"id":"r-vocabulary-2","topic":"r-vocabulary","prompt":"A “weathered” sign has probably been…","choices":["Made of clouds","Removed from its post","Worn by exposure to the elements","Recently polished indoors"],"correct":2,"explanation":"Weathered describes the effects of long exposure to weather.","hint":"Return to the passage and find the detail that supports your choice.","passage":"The path was narrow, so the walkers proceeded in single file. Leila paused beside a weathered sign. Its letters were faint, but the arrow was still visible. “We should be cautious,” she said, pointing to loose stones near the edge. Tom, usually impatient, nodded and waited while she checked the map. Their progress was slow, but neither wanted to take an unnecessary risk."}'::jsonb),
('r-vocabulary-3','r-vocabulary','{"id":"r-vocabulary-3","topic":"r-vocabulary","prompt":"“Faint” letters are…","choices":["Always very large","Difficult to see clearly","Written in a loud voice","Completely absent"],"correct":1,"explanation":"The contrast with a visible arrow suggests the lettering is faded.","hint":"Return to the passage and find the detail that supports your choice.","passage":"The path was narrow, so the walkers proceeded in single file. Leila paused beside a weathered sign. Its letters were faint, but the arrow was still visible. “We should be cautious,” she said, pointing to loose stones near the edge. Tom, usually impatient, nodded and waited while she checked the map. Their progress was slow, but neither wanted to take an unnecessary risk."}'::jsonb),
('r-vocabulary-4','r-vocabulary','{"id":"r-vocabulary-4","topic":"r-vocabulary","prompt":"“Cautious” most nearly means…","choices":["Careful about possible danger","Certain that nothing can go wrong","Uninterested in the route","Eager to run"],"correct":0,"explanation":"Loose stones near an edge give a reason to be careful.","hint":"Return to the passage and find the detail that supports your choice.","passage":"The path was narrow, so the walkers proceeded in single file. Leila paused beside a weathered sign. Its letters were faint, but the arrow was still visible. “We should be cautious,” she said, pointing to loose stones near the edge. Tom, usually impatient, nodded and waited while she checked the map. Their progress was slow, but neither wanted to take an unnecessary risk."}'::jsonb),
('r-vocabulary-5','r-vocabulary','{"id":"r-vocabulary-5","topic":"r-vocabulary","prompt":"What makes Tom’s waiting notable?","choices":["He has no map-reading ability","He has injured his foot","He is the group leader","He is usually impatient"],"correct":3,"explanation":"The writer explicitly contrasts waiting with his usual impatience.","hint":"Return to the passage and find the detail that supports your choice.","passage":"The path was narrow, so the walkers proceeded in single file. Leila paused beside a weathered sign. Its letters were faint, but the arrow was still visible. “We should be cautious,” she said, pointing to loose stones near the edge. Tom, usually impatient, nodded and waited while she checked the map. Their progress was slow, but neither wanted to take an unnecessary risk."}'::jsonb)
ON CONFLICT(id) DO NOTHING;


-- OneSixth additive setup. Use the EXISTING OneEducation MIS project.

DO $$ BEGIN IF to_regprocedure('__SCHOOL__.oe_role()') IS NULL THEN RAISE EXCEPTION 'Run in the existing OneEducation MIS Supabase project.'; END IF; END $$;
CREATE TABLE IF NOT EXISTS __SCHOOL__.ss_subjects(id text PRIMARY KEY,name text NOT NULL,group_type text NOT NULL CHECK(group_type IN ('core','option')));
CREATE TABLE IF NOT EXISTS __SCHOOL__.ss_students(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),first text NOT NULL,last text NOT NULL,year integer NOT NULL CHECK(year BETWEEN 12 AND 14),login_code text NOT NULL UNIQUE DEFAULT upper(replace(gen_random_uuid()::text,'-','')),access_code text NOT NULL UNIQUE DEFAULT ('SF-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),gcse_notes text NOT NULL DEFAULT '',archived boolean NOT NULL DEFAULT false,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS __SCHOOL__.ss_classes(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),subject_id text NOT NULL REFERENCES __SCHOOL__.ss_subjects(id),year integer NOT NULL CHECK(year BETWEEN 12 AND 14),section integer NOT NULL DEFAULT 1,room text NOT NULL CHECK(room IN ('A01','A02','A03','A04','A05','A06')),capacity integer NOT NULL DEFAULT 24 CHECK(capacity BETWEEN 1 AND 40),UNIQUE(subject_id,year,section));
CREATE TABLE IF NOT EXISTS __SCHOOL__.ss_enrolments(student_id uuid REFERENCES __SCHOOL__.ss_students(id),class_id uuid REFERENCES __SCHOOL__.ss_classes(id),PRIMARY KEY(student_id,class_id));
CREATE TABLE IF NOT EXISTS __SCHOOL__.ss_notices(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),title text NOT NULL,body text NOT NULL,year integer CHECK(year BETWEEN 12 AND 14),published boolean NOT NULL DEFAULT true,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS __SCHOOL__.ss_attendance(student_id uuid REFERENCES __SCHOOL__.ss_students(id),date date NOT NULL,session text NOT NULL CHECK(session IN ('AM','PM')),mark text NOT NULL CHECK(mark IN ('present','absent','late','ill','authorised')),note text NOT NULL DEFAULT '',updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(student_id,date,session));
CREATE TABLE IF NOT EXISTS __SCHOOL__.ss_settings(id integer PRIMARY KEY CHECK(id=1),choices_open boolean NOT NULL DEFAULT true,school_name text NOT NULL DEFAULT 'Sixth Form');
INSERT INTO __SCHOOL__.ss_settings(id) VALUES(1) ON CONFLICT DO NOTHING;
ALTER TABLE __SCHOOL__.ss_subjects ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.ss_students ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.ss_classes ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.ss_enrolments ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.ss_notices ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.ss_attendance ENABLE ROW LEVEL SECURITY;
ALTER TABLE __SCHOOL__.ss_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON __SCHOOL__.ss_subjects,__SCHOOL__.ss_students,__SCHOOL__.ss_classes,__SCHOOL__.ss_enrolments,__SCHOOL__.ss_notices,__SCHOOL__.ss_attendance,__SCHOOL__.ss_settings FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_pupil(p_code text) RETURNS __SCHOOL__.ss_students LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p __SCHOOL__.ss_students; code text:=upper(regexp_replace(COALESCE(p_code,''),'[-[:space:]]','','g'));
BEGIN
IF code !~ '^[A-F0-9]{32}$' THEN RAISE EXCEPTION 'Student login code not recognised. Use the login code, not the access code.'; END IF;
SELECT * INTO p FROM __SCHOOL__.ss_students WHERE login_code=code AND NOT archived;
IF p.id IS NULL THEN RAISE EXCEPTION 'Student login code not recognised.'; END IF;
RETURN p;
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_staff() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r text:=__SCHOOL__.oe_role();
BEGIN IF r IS NULL THEN RAISE EXCEPTION 'Verified OneEducation staff access required.'; END IF;
RETURN jsonb_build_object('role',r,'settings',(SELECT to_jsonb(s) FROM __SCHOOL__.ss_settings s WHERE id=1),
'subjects',COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.name) FROM __SCHOOL__.ss_subjects s),'[]'::jsonb),
'students',COALESCE((SELECT jsonb_agg(CASE WHEN r='admin' THEN to_jsonb(s) ELSE to_jsonb(s)-'login_code' END ORDER BY s.last,s.first) FROM __SCHOOL__.ss_students s),'[]'::jsonb),
'classes',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.year,c.subject_id,c.section) FROM __SCHOOL__.ss_classes c),'[]'::jsonb),
'enrolments',COALESCE((SELECT jsonb_agg(to_jsonb(e)) FROM __SCHOOL__.ss_enrolments e),'[]'::jsonb),
'notices',COALESCE((SELECT jsonb_agg(to_jsonb(n) ORDER BY created_at DESC) FROM __SCHOOL__.ss_notices n),'[]'::jsonb),
'attendance',COALESCE((SELECT jsonb_agg(to_jsonb(a)) FROM __SCHOOL__.ss_attendance a),'[]'::jsonb));
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_allocate(p_student uuid,p_subjects text[]) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p __SCHOOL__.ss_students; sid text; c __SCHOOL__.ss_classes; sec integer; subj __SCHOOL__.ss_subjects;
BEGIN
-- Serialises allocation so concurrent imports cannot overfill classes.
PERFORM pg_advisory_xact_lock(731204);
SELECT * INTO p FROM __SCHOOL__.ss_students WHERE id=p_student AND NOT archived FOR UPDATE;
IF p.id IS NULL THEN RAISE EXCEPTION 'Student not available.'; END IF;
IF p_subjects IS NULL OR cardinality(p_subjects)<>5 OR (SELECT count(DISTINCT x) FROM unnest(p_subjects) x)<>5 THEN RAISE EXCEPTION 'Choose five different subjects: three options and two core choices.'; END IF;
IF (SELECT count(*) FROM __SCHOOL__.ss_subjects WHERE id=ANY(p_subjects) AND group_type='option')<>3 OR (SELECT count(*) FROM __SCHOOL__.ss_subjects WHERE id=ANY(p_subjects) AND group_type='core')<>2 THEN RAISE EXCEPTION 'Choose three options and two from English, Maths, Biology, Physics or Chemistry.'; END IF;
-- Retain valid existing groups; changing one subject does not move all classes.
DELETE FROM __SCHOOL__.ss_enrolments e USING __SCHOOL__.ss_classes cl WHERE e.student_id=p.id AND e.class_id=cl.id AND (cl.year<>p.year OR NOT(cl.subject_id=ANY(p_subjects)));
FOREACH sid IN ARRAY p_subjects LOOP
IF EXISTS(SELECT 1 FROM __SCHOOL__.ss_enrolments e JOIN __SCHOOL__.ss_classes cl ON cl.id=e.class_id WHERE e.student_id=p.id AND cl.subject_id=sid AND cl.year=p.year) THEN CONTINUE; END IF;
SELECT cl.* INTO c FROM __SCHOOL__.ss_classes cl WHERE cl.year=p.year AND cl.subject_id=sid AND (SELECT count(*) FROM __SCHOOL__.ss_enrolments e JOIN __SCHOOL__.ss_students st ON st.id=e.student_id WHERE e.class_id=cl.id AND NOT st.archived)<cl.capacity
ORDER BY (SELECT count(*) FROM __SCHOOL__.ss_enrolments e WHERE e.class_id=cl.id),random() LIMIT 1 FOR UPDATE;
IF c.id IS NULL THEN
SELECT COALESCE(max(section),0)+1 INTO sec FROM __SCHOOL__.ss_classes WHERE year=p.year AND subject_id=sid;
INSERT INTO __SCHOOL__.ss_classes(subject_id,year,section,room) VALUES(sid,p.year,sec,'A0'||(1+floor(random()*6))::integer::text) RETURNING * INTO c;
END IF;
INSERT INTO __SCHOOL__.ss_enrolments(student_id,class_id) VALUES(p.id,c.id);
END LOOP;
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_import(p_names jsonb,p_year integer,p_subjects text[] DEFAULT NULL,p_gcse text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE n jsonb; student uuid; ids uuid[]:='{}'; skipped integer:=0; f text;l text;
BEGIN IF __SCHOOL__.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required for imports.'; END IF;
IF p_year IS NULL OR p_year NOT BETWEEN 12 AND 14 OR p_names IS NULL OR jsonb_typeof(p_names)<>'array' OR jsonb_array_length(p_names) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Choose Year 12–14 and between 1 and 500 students.'; END IF;
IF length(COALESCE(p_gcse,''))>2000 THEN RAISE EXCEPTION 'GCSE notes must be at most 2000 characters.'; END IF;
PERFORM pg_advisory_xact_lock(731204);
FOR n IN SELECT value FROM jsonb_array_elements(p_names) LOOP
f:=trim(n->>'first');l:=trim(n->>'last');
IF f IS NULL OR l IS NULL OR length(f) NOT BETWEEN 1 AND 80 OR length(l) NOT BETWEEN 1 AND 100 OR (f||l) ~ '[<>0-9]' THEN RAISE EXCEPTION 'Each student needs a valid first name and surname.'; END IF;
IF EXISTS(SELECT 1 FROM __SCHOOL__.ss_students WHERE NOT archived AND year=p_year AND lower(first)=lower(f) AND lower(last)=lower(l)) THEN skipped:=skipped+1;CONTINUE;END IF;
INSERT INTO __SCHOOL__.ss_students(first,last,year,gcse_notes) VALUES(f,l,p_year,COALESCE(p_gcse,'')) RETURNING id INTO student;
IF COALESCE(cardinality(p_subjects),0)>0 THEN PERFORM __SCHOOL__.ss_allocate(student,p_subjects); END IF;
ids:=array_append(ids,student);
END LOOP;
RETURN jsonb_build_object('imported',cardinality(ids),'skipped',skipped,'ids',to_jsonb(ids));
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_student(p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p __SCHOOL__.ss_students:=__SCHOOL__.ss_pupil(p_code);
BEGIN RETURN jsonb_build_object('student',to_jsonb(p)-'login_code','settings',(SELECT to_jsonb(s) FROM __SCHOOL__.ss_settings s WHERE id=1),
'subjects',(SELECT jsonb_agg(to_jsonb(s) ORDER BY s.name) FROM __SCHOOL__.ss_subjects s),
'classes',COALESCE((SELECT jsonb_agg(to_jsonb(c)) FROM __SCHOOL__.ss_classes c JOIN __SCHOOL__.ss_enrolments e ON e.class_id=c.id WHERE e.student_id=p.id),'[]'::jsonb),
'notices',COALESCE((SELECT jsonb_agg(to_jsonb(n) ORDER BY created_at DESC) FROM __SCHOOL__.ss_notices n WHERE published AND (year IS NULL OR year=p.year)),'[]'::jsonb),
'attendance',COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY date DESC,session) FROM __SCHOOL__.ss_attendance a WHERE student_id=p.id),'[]'::jsonb)); END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_choose(p_code text,p_subjects text[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p __SCHOOL__.ss_students:=__SCHOOL__.ss_pupil(p_code); opened boolean;
BEGIN SELECT choices_open INTO opened FROM __SCHOOL__.ss_settings WHERE id=1 FOR SHARE;
IF NOT opened THEN RAISE EXCEPTION 'Subject choices are closed. Please contact staff.'; END IF;
PERFORM __SCHOOL__.ss_allocate(p.id,p_subjects);RETURN __SCHOOL__.ss_student(p_code);END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_edit_student(p_id uuid,p_year integer,p_subjects text[],p_gcse text,p_archived boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF __SCHOOL__.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required.'; END IF;
IF p_year IS NULL OR p_year NOT BETWEEN 12 AND 14 OR p_archived IS NULL OR length(COALESCE(p_gcse,''))>2000 THEN RAISE EXCEPTION 'Check the year and notes.'; END IF;
PERFORM pg_advisory_xact_lock(731204);
UPDATE __SCHOOL__.ss_students SET year=p_year,gcse_notes=COALESCE(p_gcse,''),archived=p_archived WHERE id=p_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Student not found.'; END IF;
IF p_archived OR COALESCE(cardinality(p_subjects),0)=0 THEN DELETE FROM __SCHOOL__.ss_enrolments WHERE student_id=p_id;ELSE PERFORM __SCHOOL__.ss_allocate(p_id,p_subjects);END IF;
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_rotate(p_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF __SCHOOL__.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required.'; END IF;
UPDATE __SCHOOL__.ss_students SET login_code=upper(replace(gen_random_uuid()::text,'-','')),access_code='SF-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)) WHERE id=p_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Student not found.'; END IF;END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_notice(p_title text,p_body text,p_year integer DEFAULT NULL,p_id uuid DEFAULT NULL,p_published boolean DEFAULT true) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN IF __SCHOOL__.oe_role() IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
IF p_title IS NULL OR length(trim(p_title)) NOT BETWEEN 1 AND 160 OR p_body IS NULL OR length(trim(p_body)) NOT BETWEEN 1 AND 10000 OR p_published IS NULL OR (p_year IS NOT NULL AND p_year NOT BETWEEN 12 AND 14) THEN RAISE EXCEPTION 'Check notice title, message and audience.'; END IF;
IF p_id IS NULL THEN INSERT INTO __SCHOOL__.ss_notices(title,body,year,published) VALUES(trim(p_title),trim(p_body),p_year,p_published) RETURNING id INTO result;
ELSE UPDATE __SCHOOL__.ss_notices SET title=trim(p_title),body=trim(p_body),year=p_year,published=p_published WHERE id=p_id RETURNING id INTO result;IF result IS NULL THEN RAISE EXCEPTION 'Notice not found.'; END IF;END IF;RETURN result;END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_register(p_date date,p_session text,p_marks jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m jsonb;school jsonb;
BEGIN IF __SCHOOL__.oe_role() IS NULL THEN RAISE EXCEPTION 'Staff access required.'; END IF;
SELECT data INTO school FROM __SCHOOL__.oe_workspace WHERE id=1;
IF school#>>'{school,status}' IN ('closed','closing') OR EXISTS(SELECT 1 FROM jsonb_array_elements(COALESCE(school->'closures','[]'::jsonb)) c WHERE p_date BETWEEN (c->>'start')::date AND (c->>'end')::date AND c->>'status'<>'open') THEN RAISE EXCEPTION 'Attendance is locked while the school is closed or closing.'; END IF;
IF p_date IS NULL OR p_date>(now() AT TIME ZONE 'Europe/London')::date OR extract(isodow FROM p_date)>5 OR p_session IS NULL OR p_session NOT IN ('AM','PM') OR p_marks IS NULL OR jsonb_typeof(p_marks)<>'array' OR jsonb_array_length(p_marks) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Choose a weekday up to today, AM or PM, and valid students.'; END IF;
FOR m IN SELECT value FROM jsonb_array_elements(p_marks) LOOP
IF NOT EXISTS(SELECT 1 FROM __SCHOOL__.ss_students WHERE id=(m->>'id')::uuid AND NOT archived) OR COALESCE(m->>'mark','') NOT IN ('present','absent','late','ill','authorised') OR length(COALESCE(m->>'note',''))>1000 THEN RAISE EXCEPTION 'Invalid register entry.';END IF;
INSERT INTO __SCHOOL__.ss_attendance(student_id,date,session,mark,note) VALUES((m->>'id')::uuid,p_date,p_session,m->>'mark',COALESCE(m->>'note','')) ON CONFLICT(student_id,date,session) DO UPDATE SET mark=excluded.mark,note=excluded.note,updated_at=now();END LOOP;
END $$;
CREATE OR REPLACE FUNCTION __SCHOOL__.ss_settings_save(p_open boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF __SCHOOL__.oe_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Administrator access required.'; END IF;IF p_open IS NULL THEN RAISE EXCEPTION 'Choose open or closed.';END IF;UPDATE __SCHOOL__.ss_settings SET choices_open=p_open WHERE id=1;END $$;
REVOKE ALL ON FUNCTION __SCHOOL__.ss_pupil(text),__SCHOOL__.ss_allocate(uuid,text[]),__SCHOOL__.ss_staff(),__SCHOOL__.ss_import(jsonb,integer,text[],text),__SCHOOL__.ss_student(text),__SCHOOL__.ss_choose(text,text[]),__SCHOOL__.ss_edit_student(uuid,integer,text[],text,boolean),__SCHOOL__.ss_rotate(uuid),__SCHOOL__.ss_notice(text,text,integer,uuid,boolean),__SCHOOL__.ss_register(date,text,jsonb),__SCHOOL__.ss_settings_save(boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION __SCHOOL__.ss_staff(),__SCHOOL__.ss_import(jsonb,integer,text[],text),__SCHOOL__.ss_edit_student(uuid,integer,text[],text,boolean),__SCHOOL__.ss_rotate(uuid),__SCHOOL__.ss_notice(text,text,integer,uuid,boolean),__SCHOOL__.ss_register(date,text,jsonb),__SCHOOL__.ss_settings_save(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION __SCHOOL__.ss_student(text),__SCHOOL__.ss_choose(text,text[]) TO anon,authenticated;

INSERT INTO __SCHOOL__.ss_subjects(id,name,group_type) VALUES
('english-lit','English Literature','core'),
('english-lang','English Language','core'),
('maths','Mathematics','core'),
('biology','Biology','core'),
('physics','Physics','core'),
('chemistry','Chemistry','core'),
('history','History','option'),
('geography','Geography','option'),
('business','Business','option'),
('economics','Economics','option'),
('psychology','Psychology','option'),
('sociology','Sociology','option'),
('computer-science','Computer Science','option'),
('film','Film Studies','option'),
('media','Media Studies','option'),
('art','Art & Design','option'),
('photography','Photography','option'),
('drama','Drama & Theatre','option'),
('music','Music','option'),
('politics','Politics','option'),
('french','French','option'),
('spanish','Spanish','option'),
('pe','Physical Education','option'),
('further-maths','Further Mathematics','option')
ON CONFLICT(id) DO NOTHING;
INSERT INTO __SCHOOL__.ss_classes(subject_id,year,section,room) SELECT s.id,y,n,'A0'||(1+((row_number() OVER(ORDER BY y,s.id,n)-1)%6))::text FROM __SCHOOL__.ss_subjects s CROSS JOIN generate_series(12,14) y CROSS JOIN generate_series(1,2) n ON CONFLICT(subject_id,year,section) DO NOTHING;


UPDATE __SCHOOL__.oe_workspace SET data=$blank${"version":1,"school":{"name":"Your school","year":"2026/27","status":"open","reason":""},"houses":[{"name":"House 1","color":"#467fc5"},{"name":"House 2","color":"#29a58c"},{"name":"House 3","color":"#b880c6"},{"name":"House 4","color":"#db9f3d"}],"tutors":[],"teachers":[],"rooms":[{"id":"26fb4071-25f6-46c4-9268-ea77d3fd5d4b","code":"G01","name":"G01","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"621a493c-eded-4370-96e2-1683ddbbd75e","code":"G02","name":"G02","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"1bfa6eec-e120-4561-abec-65638d9a4eac","code":"G03","name":"G03","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"e828e586-3066-47c0-b454-666a02ea0a10","code":"G04","name":"G04","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"779a33d8-c0cf-403b-b892-c492bbc27103","code":"G05","name":"G05","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"c57c5b47-61f7-4555-8a7b-26da44224619","code":"G06","name":"G06","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"e497ec4d-8319-4242-a40d-50b527be510d","code":"G07","name":"G07","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"c5ee27e6-64b0-419c-90b8-0806ae82371c","code":"G08","name":"G08","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"d1a8f281-7ee3-4bb4-bdad-02ef5579d08e","code":"G09","name":"G09","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"dfee30cf-a011-4f16-a2c3-5f1e34d354b1","code":"G10","name":"G10","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"87e639cf-fce9-4938-af2e-801c279b2b25","code":"G11","name":"G11","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"3e686909-952c-4a4d-bb88-5b83c0f7457e","code":"G12","name":"G12","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"bcce5246-ed00-469f-92b5-69d00d83d65f","code":"G13","name":"G13","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"d6689181-7c88-4715-bec2-70fc3ad6c365","code":"G14","name":"G14","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"17677e22-936b-44ee-8c92-34c70e653b39","code":"G15","name":"G15","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"7eac8430-6780-4016-af49-9eb7b98a1dfb","code":"G16","name":"G16","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"43779362-7d2e-4e2d-9366-aa492a6cac8f","code":"G17","name":"G17","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"f931a6fb-7b79-47fc-b662-4307a270bbd2","code":"G18","name":"G18","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"0ec431f7-58f2-49ca-a125-9be920e9a315","code":"G19","name":"G19","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"760ca95a-93ca-406f-a75d-d5fca5853adc","code":"G20","name":"G20","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"769c92d1-cdad-4e58-9a0b-4c3f9daed4b5","code":"G21","name":"G21","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"70722ccc-517b-42bd-85b9-abeb89eab8ad","code":"G22","name":"G22","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"dcefe0a9-ee4a-46b4-9f90-5bac6caf92f7","code":"G23","name":"G23","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"a6467a48-cb03-47f0-8735-72ce4f23cec7","code":"G24","name":"G24","building":"Learning block","type":"General","capacity":32,"teaching":true},{"id":"959cfbde-d355-4fa9-a740-76b74d458f3a","code":"S01","name":"S01","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"aa3f0661-0290-410d-9a95-7d8ca9f7d6a4","code":"S02","name":"S02","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"5e2ecb49-e757-42ad-aa4c-77b042f7669d","code":"S03","name":"S03","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"62bf5b20-702f-48a3-8e69-ca0fdfdcd785","code":"S04","name":"S04","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"7934c948-1176-4115-b7b9-3fa290fb9639","code":"S05","name":"S05","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"3bc794b3-d4d3-45dc-a4d6-344a32f5c014","code":"S06","name":"S06","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"87e50ca2-94f1-4a82-b5e2-5ce4ed95e612","code":"S07","name":"S07","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"9b31921b-5ad4-4a46-9d61-7542fdbe81e8","code":"S08","name":"S08","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"5d409915-7c29-41c1-ada7-55069349386f","code":"S09","name":"S09","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"26fde00b-44a4-4f06-ace6-dd902ac01ddb","code":"S10","name":"S10","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"c49cfe00-3076-48f5-9f4d-61489c892431","code":"S11","name":"S11","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"766300b3-bff5-40eb-a0a3-a32ee71f268d","code":"S12","name":"S12","building":"Science block","type":"Science","capacity":32,"teaching":true},{"id":"62800baa-147c-413d-a2af-c31f73e50319","code":"A01","name":"A01","building":"Arts block","type":"Arts","capacity":32,"teaching":true},{"id":"35b71de9-e2fe-4e8d-bbaf-5a333d68b942","code":"A02","name":"A02","building":"Arts block","type":"Arts","capacity":32,"teaching":true},{"id":"53771287-cb33-4631-9104-c69adff8e98b","code":"A03","name":"A03","building":"Arts block","type":"Arts","capacity":32,"teaching":true},{"id":"32d9cb82-031f-4b73-8188-af8037199ef8","code":"A04","name":"A04","building":"Arts block","type":"Arts","capacity":32,"teaching":true},{"id":"d53eab18-6efc-4bd6-b0cb-2bea4e1276d0","code":"A05","name":"A05","building":"Arts block","type":"Arts","capacity":32,"teaching":true},{"id":"b366e039-1c0c-44be-b6e7-0081ac00b67e","code":"A06","name":"A06","building":"Arts block","type":"Arts","capacity":32,"teaching":true},{"id":"2e89a479-ed72-4ed4-af5e-dcc2340532fd","code":"T01","name":"T01","building":"Technology block","type":"Technology","capacity":32,"teaching":true},{"id":"d5b11953-8103-43eb-9645-4220044117b2","code":"T02","name":"T02","building":"Technology block","type":"Technology","capacity":32,"teaching":true},{"id":"71655e05-5892-40c3-8fed-f6626299b728","code":"T03","name":"T03","building":"Technology block","type":"Technology","capacity":32,"teaching":true},{"id":"e271a9b3-2f1f-49f9-88d2-8bdfaed5cb86","code":"T04","name":"T04","building":"Technology block","type":"Technology","capacity":32,"teaching":true},{"id":"d63ffaa6-475c-4bfd-99a1-113581894a94","code":"T05","name":"T05","building":"Technology block","type":"Technology","capacity":32,"teaching":true},{"id":"762dc891-8d7a-43f2-905b-4d6ce8fe1fbf","code":"T06","name":"T06","building":"Technology block","type":"Technology","capacity":32,"teaching":true},{"id":"e5cf193a-c497-400e-894f-784beeedeb10","code":"I01","name":"I01","building":"Computing block","type":"Computing","capacity":32,"teaching":true},{"id":"a2ec2adc-3fcb-435b-a710-d40afdb7174f","code":"I02","name":"I02","building":"Computing block","type":"Computing","capacity":32,"teaching":true},{"id":"7aa0273c-e6f5-442f-b455-55e5393428d0","code":"I03","name":"I03","building":"Computing block","type":"Computing","capacity":32,"teaching":true},{"id":"1f81bfed-8231-455a-ac9f-3bc23bfe2eac","code":"I04","name":"I04","building":"Computing block","type":"Computing","capacity":32,"teaching":true},{"id":"3930003c-fcc2-4aec-a10c-05869c60553e","code":"I05","name":"I05","building":"Computing block","type":"Computing","capacity":32,"teaching":true},{"id":"68b0e242-467b-4385-b39f-06352e0995f6","code":"I06","name":"I06","building":"Computing block","type":"Computing","capacity":32,"teaching":true},{"code":"P01","name":"P01 · Gym","type":"PE","capacity":40,"teaching":true,"id":"7be5e803-5378-4ff8-bad8-430ae77ea3a0","building":"Sports & assembly"},{"code":"P02","name":"P02 · Sports Hall","type":"PE","capacity":120,"teaching":true,"id":"b42ccaa4-02b5-4686-8bf8-4d4308c8e22e","building":"Sports & assembly"},{"code":"P01-ER","name":"Equipment Room · P01","type":"Store","capacity":0,"teaching":false,"id":"bdcd3f4d-842d-43ac-8016-abc88f5c2d52","building":"Sports & assembly"},{"code":"P02-PO","name":"PE Office · P02","type":"Office","capacity":6,"teaching":false,"id":"08432329-ff61-43ca-b135-ae2c7cd52614","building":"Sports & assembly"},{"code":"P03","name":"Playing field","type":"PE","capacity":90,"teaching":true,"id":"cc5af535-7ac6-4d23-8440-d61ded042ac1","building":"Sports & assembly"},{"code":"H01","name":"Main Hall","type":"Exams","capacity":180,"teaching":true,"id":"7782f5dd-d0fd-4256-8dfc-926bbdc3d705","building":"Sports & assembly"}],"classes":[],"students":[],"attendance":[],"points":[],"incidents":[],"removals":[],"closures":[],"cycles":[],"exams":[],"covers":[],"announcements":[],"audit":[]}$blank$::jsonb WHERE id=1;$template$) ON CONFLICT(id) DO UPDATE SET body=excluded.body;
NOTIFY pgrst, 'reload schema';
COMMIT;
