
-- =====================================================================
insert into public.scholars (student_id, full_name, email, program_id) values
 ('B01','Ana Reyes (B01)',    'scholar@gmail.com', (select id from public.programs where code='EXC')),
 ('B02','Ben Cruz (B02)',     'b02@example.test',  (select id from public.programs where code='EXC')),
 ('B03','Carla Santos (B03)', 'b03@example.test',  (select id from public.programs where code='ACC')),
 ('B04','Dino Lopez (B04)',   'b04@example.test',  (select id from public.programs where code='ACC')),
 ('B05','Elena Garcia (B05)', 'b05@example.test',  (select id from public.programs where code='EXC')),
 ('B06','Felix Ramos (B06)',  'b06@example.test',  (select id from public.programs where code='ACC'))
on conflict (student_id) do nothing;

-- if B01 already existed with the old email, point it to scholar@gmail.com
update public.scholars set email = 'scholar@gmail.com' where student_id = 'B01';

-- columns: scholar, GWA, units, failed, INC, drop, submitted_at, verification status
with t(sid,gwa,units,failed,inc,drp,ts,vs) as (values
 ('B01',2.00,18,0,0,0,'2026-11-06 17:00:00+08','Verified'),  -- exactly at the deadline
 ('B02',2.01,18,0,0,0,'2026-11-05 10:00:00+08','Verified'),
 ('B03',2.50,15,0,0,1,'2026-11-05 10:00:00+08','Verified'),
 ('B04',2.50,14,0,1,0,'2026-11-05 10:00:00+08','Verified'),
 ('B05',1.75,18,1,0,0,'2026-11-06 17:01:00+08','Verified'),  -- one minute late
 ('B06',2.25,15,0,0,0,'2026-11-05 10:00:00+08','Pending'))   -- pending verification
insert into public.submissions (scholar_id,academic_year,semester,gwa,enrolled_units,failed_count,incomplete_count,dropped_count,
                                evidence_ref,submitted_at,verification_status,verified_at)
select sc.id,'2026-2027',1,t.gwa,t.units,t.failed,t.inc,t.drp,
       'GRADES-'||t.sid||'-2026-2027-S1.pdf', t.ts::timestamptz, t.vs, case when t.vs='Verified' then t.ts::timestamptz end
from t join public.scholars sc on sc.student_id = t.sid
on conflict (scholar_id, academic_year, semester) do nothing;

insert into public.audit_log (submission_id, scholar_id, actor_name, actor_role, action, detail)
select s.id, s.scholar_id, 'seed script', 'system', 'SEEDED', 'Synthetic test record loaded ('||s.verification_status||')'
from public.submissions s
where not exists (select 1 from public.audit_log a where a.submission_id = s.id and a.action = 'SEEDED');

-- ---- Accounts ----
-- 1) staff account becomes Scholarship Staff
update public.profiles
set role = 'staff', full_name = 'Test Staff'
where lower(email) = 'staff@gmail.com';

-- 2) link scholar accounts to scholar rows by email
update public.scholars sc
set user_id = p.id
from public.profiles p
where lower(p.email) = lower(sc.email) and sc.user_id is null;

-- 3) scholar profile name = scholar name
update public.profiles p
set full_name = sc.full_name
from public.scholars sc
where sc.user_id = p.id and p.role = 'scholar';

-- ---- Check ----
select email, full_name, role from public.profiles order by role;
select student_id, full_name, email, user_id is not null as linked from public.scholars order by student_id;