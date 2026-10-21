-- =====================================================================
-- Student Scholarship Monitoring and Academic Compliance System
-- schema, policies (RLS), functions, policy seed
-- Run once in the Supabase SQL Editor (safe to re-run).
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- TABLES ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  full_name   text,
  role        text not null default 'scholar' check (role in ('scholar','staff')),
  created_at  timestamptz not null default now()
);

create table if not exists public.programs (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  name              text not null,
  max_gwa           numeric(3,2) not null check (max_gwa between 1.00 and 5.00),
  min_units         int not null check (min_units >= 0),
  max_failed        int not null check (max_failed >= 0),
  max_incomplete    int not null check (max_incomplete >= 0),
  max_dropped       int not null check (max_dropped >= 0),
  evidence_required boolean not null default true,
  deadline          timestamptz not null
);

create table if not exists public.scholars (
  id            uuid primary key default gen_random_uuid(),
  student_id    text not null unique,
  full_name     text not null,
  email         text,
  user_id       uuid unique references auth.users(id) on delete set null,
  program_id    uuid not null references public.programs(id),
  award_status  text not null default 'Active' check (award_status in ('Active','Inactive')),
  created_at    timestamptz not null default now()
);

create table if not exists public.submissions (
  id                  uuid primary key default gen_random_uuid(),
  scholar_id          uuid not null references public.scholars(id) on delete cascade,
  academic_year       text not null check (academic_year ~ '^\d{4}-\d{4}$'),
  semester            int  not null check (semester in (1,2)),
  gwa                 numeric(3,2) not null check (gwa between 1.00 and 5.00),
  enrolled_units      int not null check (enrolled_units >= 0),
  failed_count        int not null check (failed_count >= 0),
  incomplete_count    int not null check (incomplete_count >= 0),
  dropped_count       int not null check (dropped_count >= 0),
  evidence_ref        text not null check (length(btrim(evidence_ref)) > 0),
  submitted_at        timestamptz not null default now(),
  resubmitted_at      timestamptz,
  verification_status text not null default 'Pending' check (verification_status in ('Pending','Verified','Returned')),
  verification_reason text,
  verified_by         uuid references auth.users(id),
  verified_at         timestamptz,
  compliance_result   text not null default 'Not Evaluated' check (compliance_result in ('Not Evaluated','Compliant','With Deficiency')),
  deficiency_reasons  text[] not null default '{}',
  checks              jsonb not null default '[]'::jsonb,
  evaluated_by        uuid references auth.users(id),
  evaluated_at        timestamptz,
  renewal_decision    text not null default 'Undecided' check (renewal_decision in ('Undecided','Approved','Held')),
  decision_note       text,
  decided_by          uuid references auth.users(id),
  decided_at          timestamptz,
  constraint uq_scholar_period unique (scholar_id, academic_year, semester)
);

create table if not exists public.audit_log (
  id            bigint generated always as identity primary key,
  submission_id uuid references public.submissions(id) on delete cascade,
  scholar_id    uuid references public.scholars(id) on delete cascade,
  actor_id      uuid,
  actor_name    text,
  actor_role    text,
  action        text not null,
  detail        text,
  created_at    timestamptz not null default now()
);

create index if not exists idx_sub_period  on public.submissions(academic_year, semester);
create index if not exists idx_audit_sub   on public.audit_log(submission_id);

-- ---------- POLICY SEED ----------
insert into public.programs (code,name,max_gwa,min_units,max_failed,max_incomplete,max_dropped,evidence_required,deadline) values
 ('EXC','Excellence Scholar',2.00,18,0,0,0,true,'2026-11-06 17:00:00+08'),
 ('ACC','Access Scholar',    2.50,15,0,0,1,true,'2026-11-06 17:00:00+08')
on conflict (code) do nothing;

-- ---------- HELPERS ----------
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'staff' from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.log_action(p_sub uuid, p_scholar uuid, p_action text, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
declare pr public.profiles;
begin
  select * into pr from public.profiles where id = auth.uid();
  insert into public.audit_log(submission_id, scholar_id, actor_id, actor_name, actor_role, action, detail)
  values (p_sub, p_scholar, auth.uid(), coalesce(pr.full_name, pr.email, 'system'), coalesce(pr.role,'system'), p_action, p_detail);
end $$;

create or replace function public.validate_summary(p_ay text, p_sem int, p_gwa numeric, p_units int,
  p_failed int, p_inc int, p_drop int, p_evidence text) returns void
language plpgsql immutable as $$
begin
  if p_ay is null or p_sem is null or p_gwa is null or p_units is null or p_failed is null
     or p_inc is null or p_drop is null then
    raise exception 'All fields are required.';
  end if;
  if p_ay !~ '^\d{4}-\d{4}$' or substr(p_ay,6,4)::int <> substr(p_ay,1,4)::int + 1 then
    raise exception 'Academic year must look like 2026-2027.';
  end if;
  if p_sem not in (1,2) then raise exception 'Semester must be 1 or 2.'; end if;
  if p_gwa < 1.00 or p_gwa > 5.00 then
    raise exception 'Invalid GWA %: it must be from 1.00 to 5.00 inclusive.', p_gwa;
  end if;
  if p_units < 0 or p_failed < 0 or p_inc < 0 or p_drop < 0 then
    raise exception 'Units and failed/incomplete/dropped counts must be non-negative whole numbers.';
  end if;
  if p_evidence is null or length(btrim(p_evidence)) = 0 then
    raise exception 'A grade-document reference is required.';
  end if;
end $$;

-- ---------- SCHOLAR ACTIONS ----------
create or replace function public.submit_semester(p_academic_year text, p_semester int, p_gwa numeric,
  p_units int, p_failed int, p_incomplete int, p_dropped int, p_evidence text)
returns public.submissions language plpgsql security definer set search_path = public as $$
declare sc public.scholars; r public.submissions;
begin
  select * into sc from public.scholars where user_id = auth.uid();
  if sc.id is null then raise exception 'Your account is not linked to a scholar record. Contact the Scholarship Office.'; end if;
  perform public.validate_summary(p_academic_year,p_semester,p_gwa,p_units,p_failed,p_incomplete,p_dropped,p_evidence);
  if exists (select 1 from public.submissions where scholar_id = sc.id and academic_year = p_academic_year and semester = p_semester) then
    raise exception 'Duplicate submission: you already submitted Academic Year % Semester %. Use correction if it was returned.', p_academic_year, p_semester;
  end if;
  insert into public.submissions(scholar_id,academic_year,semester,gwa,enrolled_units,failed_count,incomplete_count,dropped_count,evidence_ref,submitted_at)
  values (sc.id,p_academic_year,p_semester,p_gwa,p_units,p_failed,p_incomplete,p_dropped,btrim(p_evidence),now())
  returning * into r;
  perform public.log_action(r.id, sc.id, 'SUBMITTED', format('AY %s Sem %s submitted', p_academic_year, p_semester));
  return r;
end $$;

create or replace function public.resubmit_submission(p_id uuid, p_gwa numeric, p_units int,
  p_failed int, p_incomplete int, p_dropped int, p_evidence text)
returns public.submissions language plpgsql security definer set search_path = public as $$
declare sc public.scholars; s public.submissions; r public.submissions;
begin
  select * into sc from public.scholars where user_id = auth.uid();
  select * into s from public.submissions where id = p_id;
  if s.id is null or sc.id is null or s.scholar_id <> sc.id then raise exception 'Access denied: you can only correct your own submission.'; end if;
  if s.verification_status <> 'Returned' then raise exception 'Only a Returned submission can be corrected and resubmitted.'; end if;
  perform public.validate_summary(s.academic_year,s.semester,p_gwa,p_units,p_failed,p_incomplete,p_dropped,p_evidence);
  update public.submissions set gwa=p_gwa, enrolled_units=p_units, failed_count=p_failed, incomplete_count=p_incomplete,
    dropped_count=p_dropped, evidence_ref=btrim(p_evidence), resubmitted_at=now(),
    verification_status='Pending', verification_reason=null, verified_by=null, verified_at=null,
    compliance_result='Not Evaluated', deficiency_reasons='{}', checks='[]'::jsonb, evaluated_by=null, evaluated_at=null,
    renewal_decision='Undecided', decision_note=null, decided_by=null, decided_at=null
  where id = p_id returning * into r;
  perform public.log_action(r.id, sc.id, 'RESUBMITTED', 'Correction submitted; back to Pending verification');
  return r;
end $$;

-- ---------- STAFF ACTIONS ----------
create or replace function public.register_scholar(p_student_id text, p_full_name text, p_email text, p_program_id uuid)
returns public.scholars language plpgsql security definer set search_path = public as $$
declare r public.scholars; uid uuid;
begin
  if not public.is_staff() then raise exception 'Access denied: only Scholarship Staff can register scholars.'; end if;
  if coalesce(btrim(p_student_id),'') = '' or coalesce(btrim(p_full_name),'') = '' then raise exception 'Student ID and full name are required.'; end if;
  if not exists (select 1 from public.programs where id = p_program_id) then raise exception 'Select a scholarship program.'; end if;
  select id into uid from public.profiles where lower(email) = lower(nullif(btrim(p_email),'')) limit 1;
  insert into public.scholars(student_id, full_name, email, user_id, program_id)
  values (btrim(p_student_id), btrim(p_full_name), lower(nullif(btrim(p_email),'')), uid, p_program_id) returning * into r;
  perform public.log_action(null, r.id, 'SCHOLAR_REGISTERED', format('%s (%s) registered', r.full_name, r.student_id));
  return r;
exception when unique_violation then
  raise exception 'Student ID % (or that account) is already registered.', p_student_id;
end $$;

create or replace function public.assign_program(p_scholar_id uuid, p_program_id uuid)
returns public.scholars language plpgsql security definer set search_path = public as $$
declare r public.scholars; pc text;
begin
  if not public.is_staff() then raise exception 'Access denied: only Scholarship Staff can assign programs.'; end if;
  select code into pc from public.programs where id = p_program_id;
  if pc is null then raise exception 'Unknown program.'; end if;
  update public.scholars set program_id = p_program_id where id = p_scholar_id returning * into r;
  if r.id is null then raise exception 'Scholar not found.'; end if;
  perform public.log_action(null, r.id, 'PROGRAM_ASSIGNED', format('%s assigned to %s', r.student_id, pc));
  return r;
end $$;

create or replace function public.verify_submission(p_id uuid, p_status text, p_reason text default null)
returns public.submissions language plpgsql security definer set search_path = public as $$
declare s public.submissions; r public.submissions;
begin
  if not public.is_staff() then raise exception 'Access denied: only Scholarship Staff can verify evidence.'; end if;
  if p_status not in ('Verified','Returned') then raise exception 'Status must be Verified or Returned.'; end if;
  select * into s from public.submissions where id = p_id;
  if s.id is null then raise exception 'Submission not found.'; end if;
  if s.verification_status <> 'Pending' then raise exception 'Only a Pending submission can be verified or returned (current: %).', s.verification_status; end if;
  if p_status = 'Returned' and coalesce(btrim(p_reason),'') = '' then raise exception 'A reason is required when returning evidence.'; end if;
  update public.submissions set verification_status = p_status,
     verification_reason = case when p_status='Returned' then btrim(p_reason) else nullif(btrim(coalesce(p_reason,'')),'') end,
     verified_by = auth.uid(), verified_at = now()
  where id = p_id returning * into r;
  perform public.log_action(r.id, r.scholar_id, case p_status when 'Verified' then 'VERIFIED' else 'RETURNED' end, coalesce(r.verification_reason,'Evidence verified'));
  return r;
end $$;

create or replace function public.evaluate_submission(p_id uuid)
returns public.submissions language plpgsql security definer set search_path = public as $$
declare s public.submissions; p public.programs; r public.submissions;
        reasons text[] := '{}'; chk jsonb := '[]'::jsonb; late boolean; res text; ok boolean; dec text;
begin
  if not public.is_staff() then raise exception 'Access denied: only Scholarship Staff can evaluate compliance.'; end if;
  select * into s from public.submissions where id = p_id;
  if s.id is null then raise exception 'Submission not found.'; end if;
  if s.verification_status <> 'Verified' then
    raise exception 'Evaluation blocked: evidence is % - only Verified submissions can be evaluated.', s.verification_status;
  end if;
  select pr.* into p from public.programs pr join public.scholars sc on sc.program_id = pr.id where sc.id = s.scholar_id;
  if p.evidence_required and coalesce(btrim(s.evidence_ref),'') = '' then raise exception 'Evaluation blocked: grade-document reference is missing.'; end if;

  ok := s.gwa <= p.max_gwa;
  chk := chk || jsonb_build_object('name','GWA','rule',format('<= %s',to_char(p.max_gwa,'FM0.00')),'actual',to_char(s.gwa,'FM0.00'),'pass',ok);
  if not ok then reasons := reasons || format('GWA %s is above the maximum %s', to_char(s.gwa,'FM0.00'), to_char(p.max_gwa,'FM0.00')); end if;

  ok := s.enrolled_units >= p.min_units;
  chk := chk || jsonb_build_object('name','Enrolled units','rule',format('>= %s',p.min_units),'actual',s.enrolled_units::text,'pass',ok);
  if not ok then reasons := reasons || format('Insufficient units: %s enrolled, minimum is %s', s.enrolled_units, p.min_units); end if;

  ok := s.failed_count <= p.max_failed;
  chk := chk || jsonb_build_object('name','Failed subjects','rule',format('<= %s',p.max_failed),'actual',s.failed_count::text,'pass',ok);
  if not ok then reasons := reasons || format('Failing subject: %s failed, allowed %s', s.failed_count, p.max_failed); end if;

  ok := s.incomplete_count <= p.max_incomplete;
  chk := chk || jsonb_build_object('name','Incomplete grades','rule',format('<= %s',p.max_incomplete),'actual',s.incomplete_count::text,'pass',ok);
  if not ok then reasons := reasons || format('Incomplete grade: %s incomplete, allowed %s', s.incomplete_count, p.max_incomplete); end if;

  ok := s.dropped_count <= p.max_dropped;
  chk := chk || jsonb_build_object('name','Dropped subjects','rule',format('<= %s',p.max_dropped),'actual',s.dropped_count::text,'pass',ok);
  if not ok then reasons := reasons || format('Dropped subjects: %s dropped, allowed %s', s.dropped_count, p.max_dropped); end if;

  late := s.submitted_at > p.deadline;
  chk := chk || jsonb_build_object('name','Submission deadline','rule',format('<= %s (Asia/Manila)', to_char(p.deadline at time zone 'Asia/Manila','YYYY-MM-DD HH24:MI')),
         'actual',to_char(s.submitted_at at time zone 'Asia/Manila','YYYY-MM-DD HH24:MI:SS'),'pass',not late);
  if late then reasons := reasons || format('Late submission: received %s, deadline %s (Asia/Manila)',
         to_char(s.submitted_at at time zone 'Asia/Manila','YYYY-MM-DD HH24:MI:SS'), to_char(p.deadline at time zone 'Asia/Manila','YYYY-MM-DD HH24:MI')); end if;

  res := case when cardinality(reasons) = 0 then 'Compliant' else 'With Deficiency' end;
  dec := s.renewal_decision;
  if dec = 'Approved' and res <> 'Compliant' then dec := 'Undecided'; end if;

  update public.submissions set compliance_result = res, deficiency_reasons = reasons, checks = chk,
     evaluated_by = auth.uid(), evaluated_at = now(), renewal_decision = dec,
     decision_note = case when dec = 'Undecided' then null else decision_note end,
     decided_by = case when dec = 'Undecided' then null else decided_by end,
     decided_at = case when dec = 'Undecided' then null else decided_at end
  where id = p_id returning * into r;
  perform public.log_action(r.id, r.scholar_id, 'EVALUATED', res || case when cardinality(reasons)>0 then ': ' || array_to_string(reasons,'; ') else '' end);
  return r;
end $$;

create or replace function public.decide_renewal(p_id uuid, p_decision text, p_note text default null)
returns public.submissions language plpgsql security definer set search_path = public as $$
declare s public.submissions; r public.submissions;
begin
  if not public.is_staff() then raise exception 'Access denied: only Scholarship Staff can record renewal decisions.'; end if;
  if p_decision not in ('Approved','Held') then raise exception 'Decision must be Approved or Held.'; end if;
  select * into s from public.submissions where id = p_id;
  if s.id is null then raise exception 'Submission not found.'; end if;
  if s.verification_status <> 'Verified' then raise exception 'Renewal blocked: evidence is % - it must be Verified first.', s.verification_status; end if;
  if s.compliance_result = 'Not Evaluated' then raise exception 'Renewal blocked: evaluate the submission before deciding.'; end if;
  if p_decision = 'Approved' and s.compliance_result <> 'Compliant' then
    raise exception 'Cannot approve: the record is % (%). Hold it instead.', s.compliance_result, array_to_string(s.deficiency_reasons,'; ');
  end if;
  if p_decision = 'Held' and coalesce(btrim(p_note),'') = '' then raise exception 'A decision note is required when holding renewal.'; end if;
  update public.submissions set renewal_decision = p_decision, decision_note = nullif(btrim(coalesce(p_note,'')),''),
     decided_by = auth.uid(), decided_at = now() where id = p_id returning * into r;
  perform public.log_action(r.id, r.scholar_id, case p_decision when 'Approved' then 'RENEWAL_APPROVED' else 'RENEWAL_HELD' end, coalesce(r.decision_note,'(no note)'));
  return r;
end $$;

-- ---------- NEW-USER TRIGGER (profile + link to scholar by e-mail) ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id,email,full_name,role)
  values (new.id, lower(new.email), coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)), 'scholar')
  on conflict (id) do nothing;
  update public.scholars set user_id = new.id where user_id is null and lower(email) = lower(new.email);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

insert into public.profiles(id,email,full_name,role)
select id, lower(email), split_part(email,'@',1), 'scholar' from auth.users on conflict (id) do nothing;

-- ---------- ROW LEVEL SECURITY ----------
alter table public.profiles    enable row level security;
alter table public.programs    enable row level security;
alter table public.scholars    enable row level security;
alter table public.submissions enable row level security;
alter table public.audit_log   enable row level security;

drop policy if exists profiles_read    on public.profiles;
drop policy if exists programs_read    on public.programs;
drop policy if exists scholars_read    on public.scholars;
drop policy if exists submissions_read on public.submissions;
drop policy if exists audit_read       on public.audit_log;

create policy profiles_read    on public.profiles    for select to authenticated using (id = auth.uid() or public.is_staff());
create policy programs_read    on public.programs    for select to authenticated using (true);
create policy scholars_read    on public.scholars    for select to authenticated using (public.is_staff() or user_id = auth.uid());
create policy submissions_read on public.submissions for select to authenticated
  using (public.is_staff() or scholar_id in (select id from public.scholars where user_id = auth.uid()));
create policy audit_read       on public.audit_log   for select to authenticated
  using (public.is_staff() or scholar_id in (select id from public.scholars where user_id = auth.uid()));

revoke all on all tables in schema public from anon, authenticated;
grant select on public.profiles, public.programs, public.scholars, public.submissions, public.audit_log to authenticated;

do $$ declare r record; begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('is_staff','log_action','validate_summary','submit_semester','resubmit_submission',
             'register_scholar','assign_program','verify_submission','evaluate_submission','decide_renewal') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    if r.sig::text not like 'log_action%' and r.sig::text not like 'validate_summary%' then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;
  end loop;
end $$;