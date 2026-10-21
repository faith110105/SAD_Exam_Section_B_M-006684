# Student Scholarship Monitoring and Academic Compliance System
SAD Laboratory Examination - Section B. Stack: HTML + CSS + JavaScript (no build step), Supabase (Postgres, Auth, Row Level Security), GitHub.
Synthetic data only. The Registrar remains the source of official grades; this app never alters official grades or releases payments.

## Folder
- `supabase/schema.sql` - tables, keys, constraints, two policy records, SQL functions, row-level security
- `supabase/seed.sql` - six seeded scholars B01-B06 (AY 2026-2027 Sem 1) and test-account linking
- `web/` - `index.html`, `app.js`, `style.css`, `config.js`
- `docs/` - Part I analysis report (`SAD_Section_B_Part_I_Analysis.docx`), diagram images and sources

## Setup (about 10 minutes)
1. Create a Supabase project. In **Authentication > Providers > Email**, turn off "Confirm email" (or create users with auto-confirm).
2. In **Authentication > Users > Add user**, create the two synthetic test accounts (choose your own passwords; do not put them in code or screenshots):
   - `staff@example.test` -> Scholarship Staff
   - `b01@example.test` -> Scholar B01
3. SQL Editor: run `supabase/schema.sql`, then `supabase/seed.sql`. (Both are re-runnable.)
4. Edit `web/config.js` and paste the Project URL and the **anon/publishable** key. Environment variable names used: `SUPABASE_URL`, `SUPABASE_ANON_KEY`. Never use the service-role key.
5. Run locally: open `web/index.html` in a browser, or from the `web` folder run `python3 -m http.server 8080` and visit http://localhost:8080 . Hosting is optional (GitHub Pages works because the site is static).

Test-account passwords are given privately to the instructor, not in this repository.

## How access is enforced (not just hidden buttons)
- RLS: scholars can `select` only rows tied to their own scholar record; staff can select all. No table has insert/update/delete rights for the browser role.
- Every change is a SQL function (`submit_semester`, `resubmit_submission`, `register_scholar`, `assign_program`, `verify_submission`, `evaluate_submission`, `decide_renewal`) that checks the caller role inside the database.
- Policy thresholds are read from the `programs` row of the scholar; nothing is hard-coded in evaluation.

## Running the tests
- Staff: sign in as staff -> **Test console** -> *Run TC01-TC06 and TC10* (table of expected vs actual, pass/fail).
- Scholar: sign in as `b01@example.test` -> *Access and validation self-test* (TC07, TC08, TC10).
- TC09 (manual): as B01 submit AY 2025-2026 Semester 2; as staff open it and **Return** with a reason; as B01 click **Correct**, change a value and resubmit; refresh the page. Status is Pending and the History list shows SUBMITTED, RETURNED, RESUBMITTED.
- Take screenshots of: submission, verification, compliance (checks + reasons), renewal, dashboard, and the self-test table for role access.
- Part I report: `docs/SAD_Section_B_Part_I_Analysis.docx` (fill in name/ID/program/date).

## Assumptions
- Lateness uses the original submission timestamp; a correction after a return does not make an on-time submission late.
- Holding renewal requires a note; approving does not.
- Re-evaluating a record whose result is no longer Compliant resets an earlier Approved decision to Undecided.

## Known defects / limitations
- The browser pages were syntax-checked but not yet clicked through by the author; the SQL logic was run and passed TC01-TC10 on a local PostgreSQL stand-in. Record anything you find here before submitting.
- Evidence is a text reference only (no file upload). No in-app policy editor (use `update public.programs ...`). No e-mail notification.
- If hosting or network fails, run from the local folder as above and report the error text to the instructor.

## Submission
Name the folder `SAD_Exam_Section_B_<YourStudentID>` and push to GitHub or zip it, as instructed.
