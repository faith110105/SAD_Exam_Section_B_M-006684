/* Scholarship Monitoring and Academic Compliance System - browser client.
   All authorization is enforced by Supabase (RLS + SQL functions); this file only calls them. */
const sb = supabase.createClient(APP_CONFIG.SUPABASE_URL, APP_CONFIG.SUPABASE_ANON_KEY);
const $ = (s, r = document) => r.querySelector(s);
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmt = ts => ts ? new Date(ts).toLocaleString('en-PH', { timeZone: 'Asia/Manila', dateStyle: 'medium', timeStyle: 'medium' }) + ' PHT' : '-';
const YEARS = ['2026-2027', '2025-2026'];
const state = { me: null, programs: [], tab: 'dashboard', ay: '2026-2027', sem: 1, q: '', prog: '', comp: '', rows: [], scholars: [] };

// ---------- helpers ----------
let toastTimer;
function toast(msg, ok = true) {
  const t = $('#toast'); t.textContent = msg; t.className = 'toast ' + (ok ? 'ok' : 'err'); t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.hidden = true, 6000);
}
const errMsg = e => (e && e.message) ? e.message : String(e);
async function rpc(fn, args) { const { data, error } = await sb.rpc(fn, args); if (error) throw error; return data; }
function badge(text) {
  const map = { Verified: 'ok', Compliant: 'ok', Approved: 'ok', Active: 'ok', Pending: 'warn', 'With Deficiency': 'bad', Returned: 'bad', Held: 'bad', 'Not Evaluated': 'mut', Undecided: 'mut', 'Not submitted': 'mut' };
  return `<span class="badge b-${map[text] || 'mut'}">${esc(text)}</span>`;
}
const progOpts = (sel) => state.programs.map(p => `<option value="${p.id}" ${p.id === sel ? 'selected' : ''}>${esc(p.name)}</option>`).join('');
const ayOpts = sel => YEARS.map(y => `<option ${y === sel ? 'selected' : ''}>${y}</option>`).join('');
const num = v => (v === '' || v === null ? NaN : Number(v));
const roleLabel = r => r === 'staff' ? 'Scholarship Staff' : 'Scholar';

// ---------- auth / boot ----------
$('#loginForm').addEventListener('submit', async e => {
  e.preventDefault();
  const { error } = await sb.auth.signInWithPassword({ email: $('#email').value.trim(), password: $('#password').value });
  if (error) toast(error.message, false);
});
$('#logoutBtn').addEventListener('click', () => sb.auth.signOut());
let lastUid = undefined;
sb.auth.onAuthStateChange((evt, session) => {
  const uid = session?.user?.id || null;
  if (evt === 'TOKEN_REFRESHED' || (evt !== 'INITIAL_SESSION' && uid === lastUid && evt !== 'SIGNED_OUT')) return;
  lastUid = uid; setTimeout(() => boot(session), 0);
});

async function boot(session) {
  ['loginView', 'scholarView', 'staffView'].forEach(id => $('#' + id).hidden = true);
  $('#who').hidden = true;
  if (!session) { state.me = null; $('#loginView').hidden = false; return; }

  // always read the role fresh from the database (never cached)
  const { data: me, error } = await sb.from('profiles').select('*').eq('id', session.user.id).maybeSingle();
  if (error || !me) { toast('Profile not found. Ask the administrator to run schema.sql.', false); return; }
  state.me = me;

  const pr = await sb.from('programs').select('*').order('name');
  if (pr.error) toast('Could not load programs: ' + pr.error.message, false);
  state.programs = pr.data || [];

  $('#whoText').textContent = `${me.full_name || me.email} (${roleLabel(me.role)})`;
  $('#who').hidden = false;

  if (me.role === 'staff') { $('#staffView').hidden = false; renderStaff(); }
  else { $('#scholarView').hidden = false; renderScholar(); }
}

// =====================================================================
// SCHOLAR VIEW
// =====================================================================
let editing = null;   // submission being corrected
async function renderScholar() {
  const root = $('#scholarView');
  const scRes = await sb.from('scholars').select('*, programs(*)').eq('user_id', state.me.id).maybeSingle();
  if (scRes.error) { toast('Could not load scholar record: ' + scRes.error.message, false); }
  const sc = scRes.data;
  if (!sc) {
    root.innerHTML = `<div class="card"><h2>No scholar record</h2>
      <p>Your account is not linked to a scholar record. Contact the Scholarship Office.</p>
      <p class="muted">Signed in as <b>${esc(state.me.email)}</b> with role <b>${esc(roleLabel(state.me.role))}</b>.
      If you are a staff member, your profile role must be set to <b>staff</b> in the database. If you are a scholar,
      staff must register your email under Scholars so it links to your account.</p>
      <button id="reloadBtn" class="ghost" style="color:var(--pri)">Reload</button></div>`;
    $('#reloadBtn').onclick = async () => { const { data } = await sb.auth.getSession(); boot(data.session); };
    return;
  }
  const subs = (await sb.from('submissions').select('*').eq('scholar_id', sc.id).order('submitted_at', { ascending: false })).data || [];
  const logs = subs.length ? (await sb.from('audit_log').select('*').in('submission_id', subs.map(s => s.id)).order('created_at')).data || [] : [];
  const e = editing ? subs.find(s => s.id === editing) : null;
  const p = sc.programs;
  root.innerHTML = `
  <div class="card"><h2>${esc(sc.full_name)} <small class="muted">${esc(sc.student_id)}</small></h2>
    <p>Program: <b>${esc(p.name)}</b> &middot; Award status: ${badge(sc.award_status)} &middot; Deadline: ${fmt(p.deadline)}</p>
    <p class="muted">Required: GWA &le; ${p.max_gwa}, units &ge; ${p.min_units}, failed &le; ${p.max_failed}, incomplete &le; ${p.max_incomplete}, dropped &le; ${p.max_dropped}. Grades are never changed by this system; the Registrar holds official grades.</p></div>

  <div class="card"><h2>${e ? `Correct and resubmit - AY ${esc(e.academic_year)} Sem ${e.semester}` : 'Submit semester academic summary'}</h2>
   ${e ? `<div class="note"><b>Returned by staff:</b> ${esc(e.verification_reason)}</div>` : ''}
   <form id="subForm" class="grid g4">
     <label>Academic year <select id="fAy" ${e ? 'disabled' : ''}>${ayOpts(e?.academic_year || '2026-2027')}</select></label>
     <label>Semester <select id="fSem" ${e ? 'disabled' : ''}><option ${e?.semester === 1 || !e ? 'selected' : ''}>1</option><option ${e?.semester === 2 ? 'selected' : ''}>2</option></select></label>
     <label>GWA (1.00 - 5.00) <input id="fGwa" type="number" step="0.01" min="1" max="5" required value="${e?.gwa ?? ''}"></label>
     <label>Enrolled units <input id="fUnits" type="number" min="0" step="1" required value="${e?.enrolled_units ?? ''}"></label>
     <label>Failed subjects <input id="fFail" type="number" min="0" step="1" required value="${e?.failed_count ?? 0}"></label>
     <label>Incomplete grades <input id="fInc" type="number" min="0" step="1" required value="${e?.incomplete_count ?? 0}"></label>
     <label>Dropped subjects <input id="fDrop" type="number" min="0" step="1" required value="${e?.dropped_count ?? 0}"></label>
     <label>Grade-document reference <input id="fEv" type="text" required placeholder="e.g. GRADES-B01-2026-2027-S1.pdf" value="${esc(e?.evidence_ref || '')}"></label>
     <div style="grid-column:1/-1"><button type="submit">${e ? 'Resubmit correction' : 'Submit'}</button>
       ${e ? '<button type="button" id="cancelEdit" class="ghost" style="color:var(--ink)">Cancel</button>' : ''}</div>
   </form></div>

  <div class="card"><h2>My submissions</h2><div class="scroll"><table>
   <tr><th>Period</th><th>GWA</th><th>Units</th><th>F / INC / DRP</th><th>Submitted</th><th>Verification</th><th>Compliance</th><th>Renewal</th><th></th></tr>
   ${subs.map(s => `<tr><td>${esc(s.academic_year)} S${s.semester}</td><td>${Number(s.gwa).toFixed(2)}</td><td>${s.enrolled_units}</td>
     <td>${s.failed_count} / ${s.incomplete_count} / ${s.dropped_count}</td><td>${fmt(s.submitted_at)}</td>
     <td>${badge(s.verification_status)}${s.verification_status === 'Returned' ? `<div class="muted">${esc(s.verification_reason)}</div>` : ''}</td>
     <td>${badge(s.compliance_result)}${(s.deficiency_reasons || []).map(r => `<div class="muted">${esc(r)}</div>`).join('')}</td>
     <td>${badge(s.renewal_decision)}${s.decision_note ? `<div class="muted">${esc(s.decision_note)}</div>` : ''}</td>
     <td>${s.verification_status === 'Returned' ? `<button class="sm" data-edit="${s.id}">Correct</button>` : ''}</td></tr>
     <tr><td colspan="9"><details><summary class="muted">History (${logs.filter(l => l.submission_id === s.id).length})</summary><ul class="hist">
       ${logs.filter(l => l.submission_id === s.id).map(l => `<li>${fmt(l.created_at)} - <b>${esc(l.action)}</b> by ${esc(l.actor_name)} (${esc(l.actor_role)}): ${esc(l.detail)}</li>`).join('')}</ul></details></td></tr>`).join('')
     || '<tr><td colspan="9" class="muted">No submissions yet.</td></tr>'}
  </table></div></div>`;

  $('#subForm').addEventListener('submit', async ev => {
    ev.preventDefault();
    const v = { gwa: num($('#fGwa').value), units: num($('#fUnits').value), fail: num($('#fFail').value), inc: num($('#fInc').value), drop: num($('#fDrop').value), ev: $('#fEv').value.trim() };
    if (!(v.gwa >= 1 && v.gwa <= 5)) return toast('GWA must be from 1.00 to 5.00 inclusive.', false);
    if ([v.units, v.fail, v.inc, v.drop].some(n => !Number.isInteger(n) || n < 0)) return toast('Units and counts must be non-negative whole numbers.', false);
    if (!v.ev) return toast('A grade-document reference is required.', false);
    try {
      if (e) await rpc('resubmit_submission', { p_id: e.id, p_gwa: v.gwa, p_units: v.units, p_failed: v.fail, p_incomplete: v.inc, p_dropped: v.drop, p_evidence: v.ev });
      else await rpc('submit_semester', { p_academic_year: $('#fAy').value, p_semester: Number($('#fSem').value), p_gwa: v.gwa, p_units: v.units, p_failed: v.fail, p_incomplete: v.inc, p_dropped: v.drop, p_evidence: v.ev });
      toast(e ? 'Correction resubmitted - now Pending verification.' : 'Submission received.'); editing = null; renderScholar();
    } catch (err) { toast(errMsg(err), false); }
  });
  root.querySelectorAll('[data-edit]').forEach(b => b.onclick = () => { editing = b.dataset.edit; renderScholar(); window.scrollTo(0, 0); });
  $('#cancelEdit')?.addEventListener('click', () => { editing = null; renderScholar(); });
}

// =====================================================================
// STAFF VIEW
// =====================================================================
function renderStaff() {
  const tabs = [['dashboard', 'Dashboard'], ['scholars', 'Scholars'], ['programs', 'Policies']];
  $('#staffView').innerHTML = `<div class="tabs">${tabs.map(([k, l]) => `<button data-tab="${k}" class="${state.tab === k ? 'on' : ''}">${l}</button>`).join('')}</div><div id="staffBody"></div>`;
  $('#staffView').querySelectorAll('[data-tab]').forEach(b => b.onclick = () => { state.tab = b.dataset.tab; renderStaff(); });
  ({ dashboard: renderDashboard, scholars: renderScholars, programs: renderPolicies })[state.tab]();
}

async function loadRows() {
  const scRes = await sb.from('scholars').select('*, programs(code,name)').order('student_id');
  if (scRes.error) toast('Could not load scholars: ' + scRes.error.message, false);
  const sc = scRes.data || [];
  const subRes = await sb.from('submissions').select('*').eq('academic_year', state.ay).eq('semester', state.sem);
  if (subRes.error) toast('Could not load submissions: ' + subRes.error.message, false);
  const subs = subRes.data || [];
  if (!scRes.error && sc.length === 0) toast('No scholars visible. Run seed.sql, and make sure this account has the staff role.', false);
  state.scholars = sc;
  state.rows = sc.map(s => ({ scholar: s, sub: subs.find(x => x.scholar_id === s.id) || null }));
}

async function renderDashboard() {
  await loadRows();
  const rows = state.rows, subs = rows.filter(r => r.sub);
  const stats = {
    total: rows.length,
    pending: subs.filter(r => r.sub.verification_status === 'Pending').length,
    ok: subs.filter(r => r.sub.compliance_result === 'Compliant').length,
    def: subs.filter(r => r.sub.compliance_result === 'With Deficiency').length
  };
  $('#staffBody').innerHTML = `
  <div class="card"><div class="row">
    <label>Academic year <select id="dAy">${ayOpts(state.ay)}</select></label>
    <label>Semester <select id="dSem"><option ${state.sem === 1 ? 'selected' : ''}>1</option><option ${state.sem === 2 ? 'selected' : ''}>2</option></select></label>
    <label>Search ID or name <input id="dQ" value="${esc(state.q)}" placeholder="e.g. B03 or Santos"></label>
    <label>Program <select id="dProg"><option value="">All</option>${state.programs.map(p => `<option value="${p.id}" ${state.prog === p.id ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}</select></label>
    <label>Compliance <select id="dComp">${['', 'Not Evaluated', 'Compliant', 'With Deficiency'].map(c => `<option value="${c}" ${state.comp === c ? 'selected' : ''}>${c || 'All'}</option>`).join('')}</select></label>
  </div></div>
  <div class="grid g4" style="margin-bottom:16px">
    <div class="stat"><b>${stats.total}</b><span>Assigned scholars</span></div>
    <div class="stat"><b>${stats.pending}</b><span>Pending verification (selected semester)</span></div>
    <div class="stat"><b>${stats.ok}</b><span>Compliant</span></div>
    <div class="stat"><b>${stats.def}</b><span>With deficiency</span></div></div>
  <div class="card scroll"><table><tr><th>Student ID</th><th>Name</th><th>Program</th><th>Submission</th><th>Compliance</th><th>Renewal</th><th>Submitted</th><th></th></tr>
  <tbody id="dRows"></tbody></table></div>`;
  const draw = () => {
    const q = state.q.toLowerCase();
    const list = rows.filter(r =>
      (!q || r.scholar.student_id.toLowerCase().includes(q) || r.scholar.full_name.toLowerCase().includes(q)) &&
      (!state.prog || r.scholar.program_id === state.prog) &&
      (!state.comp || (r.sub?.compliance_result || 'Not Evaluated') === state.comp));
    $('#dRows').innerHTML = list.map(r => `<tr><td>${esc(r.scholar.student_id)}</td><td>${esc(r.scholar.full_name)}</td><td>${esc(r.scholar.programs?.name)}</td>
      <td>${badge(r.sub ? r.sub.verification_status : 'Not submitted')}</td><td>${badge(r.sub ? r.sub.compliance_result : 'Not Evaluated')}</td>
      <td>${badge(r.sub ? r.sub.renewal_decision : 'Undecided')}</td><td>${r.sub ? fmt(r.sub.submitted_at) : '-'}</td>
      <td>${r.sub ? `<button class="sm" data-open="${r.sub.id}">Open</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="8" class="muted">No matching scholars.</td></tr>';
    $('#dRows').querySelectorAll('[data-open]').forEach(b => b.onclick = () => openDetail(b.dataset.open));
  };
  draw();
  $('#dAy').onchange = e => { state.ay = e.target.value; renderDashboard(); };
  $('#dSem').onchange = e => { state.sem = Number(e.target.value); renderDashboard(); };
  $('#dQ').oninput = e => { state.q = e.target.value; draw(); };
  $('#dProg').onchange = e => { state.prog = e.target.value; draw(); };
  $('#dComp').onchange = e => { state.comp = e.target.value; draw(); };
}

async function openDetail(id) {
  const dlg = $('#detailDlg');
  const sRes = await sb.from('submissions').select('*, scholars(student_id, full_name, award_status, programs(*))').eq('id', id).single();
  if (sRes.error) return toast('Could not open submission: ' + sRes.error.message, false);
  const s = sRes.data;
  const logs = (await sb.from('audit_log').select('*').eq('submission_id', id).order('created_at')).data || [];
  const p = s.scholars.programs;
  dlg.innerHTML = `
  <h2>${esc(s.scholars.student_id)} - ${esc(s.scholars.full_name)} <small class="muted">AY ${esc(s.academic_year)} Sem ${s.semester}</small></h2>
  <p>Program <b>${esc(p.name)}</b> &middot; Award status ${badge(s.scholars.award_status)}</p>
  <div class="grid g3">
    <div>Submission: ${badge(s.verification_status)}</div><div>Compliance: ${badge(s.compliance_result)}</div><div>Renewal: ${badge(s.renewal_decision)}</div></div>
  <h3>Academic summary (test input, not an official grade)</h3>
  <table><tr><th>GWA</th><th>Units</th><th>Failed</th><th>INC</th><th>Dropped</th><th>Evidence reference</th><th>Submitted</th></tr>
  <tr><td>${Number(s.gwa).toFixed(2)}</td><td>${s.enrolled_units}</td><td>${s.failed_count}</td><td>${s.incomplete_count}</td><td>${s.dropped_count}</td><td>${esc(s.evidence_ref)}</td><td>${fmt(s.submitted_at)}</td></tr></table>
  ${s.verification_reason ? `<p class="note"><b>Verification note:</b> ${esc(s.verification_reason)}</p>` : ''}

  <h3>1. Verify evidence</h3>
  <label>Reason (required when returning) <input id="vReason" placeholder="e.g. Grade document is unreadable"></label>
  <button id="bVerify" class="ok">Mark Verified</button> <button id="bReturn" class="warn">Return to scholar</button>

  <h3>2. Evaluate compliance</h3>
  <button id="bEval">Evaluate against ${esc(p.code)} policy</button>
  ${s.checks.length ? `<table><tr><th>Policy check</th><th>Rule</th><th>Actual</th><th>Result</th></tr>${s.checks.map(c => `<tr><td>${esc(c.name)}</td><td>${esc(c.rule)}</td><td>${esc(c.actual)}</td><td class="${c.pass ? 'pass' : 'fail'}">${c.pass ? 'PASS' : 'FAIL'}</td></tr>`).join('')}</table>
     ${s.deficiency_reasons.length ? `<p class="note"><b>Deficiency reasons:</b><ul>${s.deficiency_reasons.map(r => `<li>${esc(r)}</li>`).join('')}</ul></p>` : '<p class="pass">All checks passed.</p>'}` : '<p class="muted">Not evaluated yet.</p>'}

  <h3>3. Renewal decision</h3>
  <label>Decision note (required when holding) <input id="dNote" value="${esc(s.decision_note || '')}"></label>
  <button id="bApprove" class="ok">Approve renewal</button> <button id="bHold" class="bad">Hold renewal</button>
  <p class="muted">Approval requires an evaluated Compliant record. A deficiency flag never disqualifies automatically; staff decide.</p>

  <h3>History</h3><ul class="hist">${logs.map(l => `<li>${fmt(l.created_at)} - <b>${esc(l.action)}</b> by ${esc(l.actor_name)} (${esc(l.actor_role)}): ${esc(l.detail)}</li>`).join('')}</ul>
  <div style="text-align:right"><button id="bClose" class="ghost" style="color:var(--ink)">Close</button></div>`;
  const run = (fn, okMsg) => async () => {
    try { await fn(); toast(okMsg); await openDetail(id); if (state.tab === 'dashboard') renderDashboard(); }
    catch (e) { toast(errMsg(e), false); }
  };
  $('#bVerify').onclick = run(() => rpc('verify_submission', { p_id: id, p_status: 'Verified', p_reason: $('#vReason').value }), 'Evidence verified.');
  $('#bReturn').onclick = run(() => rpc('verify_submission', { p_id: id, p_status: 'Returned', p_reason: $('#vReason').value }), 'Returned to scholar.');
  $('#bEval').onclick = run(() => rpc('evaluate_submission', { p_id: id }), 'Evaluation recorded.');
  $('#bApprove').onclick = run(() => rpc('decide_renewal', { p_id: id, p_decision: 'Approved', p_note: $('#dNote').value }), 'Renewal approved.');
  $('#bHold').onclick = run(() => rpc('decide_renewal', { p_id: id, p_decision: 'Held', p_note: $('#dNote').value }), 'Renewal held.');
  $('#bClose').onclick = () => dlg.close();
  if (!dlg.open) dlg.showModal();
}

async function renderScholars() {
  await loadRows();
  $('#staffBody').innerHTML = `
  <div class="card"><h2>Register scholar</h2>
   <form id="regForm" class="row">
     <label>Student ID <input id="rId" required></label><label>Full name <input id="rName" required></label>
     <label>Account email (optional) <input id="rEmail" type="email"></label>
     <label>Program <select id="rProg">${progOpts()}</select></label><button type="submit">Register</button></form>
   <p class="muted">An email links the scholar to their login account so they can see only their own records.</p></div>
  <div class="card scroll"><h2>Assigned scholars</h2><table><tr><th>Student ID</th><th>Name</th><th>Email</th><th>Account linked</th><th>Award</th><th>Program (change assignment)</th></tr>
   ${state.scholars.map(s => `<tr><td>${esc(s.student_id)}</td><td>${esc(s.full_name)}</td><td>${esc(s.email || '-')}</td><td>${s.user_id ? 'Yes' : 'No'}</td><td>${badge(s.award_status)}</td>
     <td><select data-assign="${s.id}">${progOpts(s.program_id)}</select></td></tr>`).join('')}</table></div>`;
  $('#regForm').onsubmit = async e => {
    e.preventDefault();
    try { await rpc('register_scholar', { p_student_id: $('#rId').value, p_full_name: $('#rName').value, p_email: $('#rEmail').value, p_program_id: $('#rProg').value }); toast('Scholar registered.'); renderScholars(); }
    catch (err) { toast(errMsg(err), false); }
  };
  $('#staffBody').querySelectorAll('[data-assign]').forEach(sel => sel.onchange = async () => {
    try { await rpc('assign_program', { p_scholar_id: sel.dataset.assign, p_program_id: sel.value }); toast('Program assigned.'); }
    catch (err) { toast(errMsg(err), false); renderScholars(); }
  });
}

function renderPolicies() {
  $('#staffBody').innerHTML = `<div class="card scroll"><h2>Scholarship policy records (read by the evaluation function)</h2><table>
   <tr><th>Program</th><th>Max GWA</th><th>Min units</th><th>Max failed</th><th>Max INC</th><th>Max dropped</th><th>Evidence required</th><th>Deadline</th></tr>
   ${state.programs.map(p => `<tr><td>${esc(p.name)}</td><td>${Number(p.max_gwa).toFixed(2)}</td><td>${p.min_units}</td><td>${p.max_failed}</td><td>${p.max_incomplete}</td><td>${p.max_dropped}</td><td>${p.evidence_required ? 'Yes' : 'No'}</td><td>${fmt(p.deadline)}</td></tr>`).join('')}</table>
   <p class="muted">Change a threshold with an UPDATE on the programs table; evaluation uses the stored value, never a copy in code.</p></div>`;
}