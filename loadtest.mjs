#!/usr/bin/env node
// Load test for the voting page: N simulated voters hit a form at the same time.
//
// Each simulated voter does exactly what vote.html does on a phone:
//   1. voting_form_public  (load the form; on "busy" wait 3–7 s and try again)
//   2. cast_vote           (on "busy" retry up to 4 times, backing off)
// with the same 12 s timeout per request.
//
// USE A TEST FORM, never a live one. Every simulated vote is real and lands in
// the database. Afterwards, clear it with Reset on that form in the admin.
//
// The test form's "Who can vote" must be one of:
//   * One vote per phone (open)  — voters are  device:lt-<run>-<n>
//   * Any ID (any)               — voters are  LT<run><n>
//   * Email (email)              — voters are  lt-<run>-<n>@example.com
// (Student ID list / VIP guest list forms would reject the fake voters.)
// If the form has an access code, pass it with --code.
//
// Needs Node 18 or newer, nothing to install:
//   node loadtest.mjs --form <link-ending> --voters 6000
//
// Options:
//   --form    <slug>  the part after vote.html?f=   (required)
//   --voters  <n>     how many people vote            (default 6000)
//   --ramp    <sec>   spread their arrival over this many seconds; 0 = all at once (default 0)
//   --think   <sec>   max time a voter spends picking before tapping Vote (default 0)
//   --code    <code>  access code, if the form has one
//   --no-retry        report the first answer only (don't retry like the page does)

const API = process.env.VOTING_API || 'https://raraxpjsftqxhwkpwpab.supabase.co/rest/v1/rpc/';
const KEY = 'sb_publishable_p4FqN3nJTT5GFNU_xqZtYg_7fPtkKhS';
const TIMEOUT_MS = 12000;

// ── Options ────────────────────────────────────────────────
const args = process.argv.slice(2);
function opt(name, def) {
  const i = args.indexOf('--' + name);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : def;
}
const SLUG = (opt('form', '') || '').trim().toLowerCase();
const VOTERS = parseInt(opt('voters', '6000'), 10);
const RAMP_MS = parseFloat(opt('ramp', '0')) * 1000;
const THINK_MS = parseFloat(opt('think', '0')) * 1000;
const CODE = opt('code', null);
const RETRY = !args.includes('--no-retry');
if (!SLUG || !(VOTERS > 0)) {
  console.log('Usage: node loadtest.mjs --form <link-ending> [--voters 6000] [--ramp 0] [--think 0] [--code X] [--no-retry]');
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const RUN = Date.now().toString(36).slice(-5);

// ── Stats ──────────────────────────────────────────────────
const stats = {
  load: { ms: [], status: {}, outcome: {} },
  vote: { ms: [], status: {}, outcome: {} },
  voter: {},          // final result per simulated voter
  totalMs: [],        // arrival → vote finished (what the person waits)
  retries: 0,
};
let started = 0, finished = 0, inFlight = 0, peakInFlight = 0;
const bump = (o, k) => { o[k] = (o[k] || 0) + 1; };

// One request, timed, classified the same way vote.html does.
async function call(kind, fn, body) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  const t0 = performance.now();
  inFlight++; peakInFlight = Math.max(peakInFlight, inFlight);
  try {
    const r = await fetch(API + fn, {
      method: 'POST',
      headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: ctl.signal,
    });
    const text = await r.text();
    stats[kind].ms.push(performance.now() - t0);
    bump(stats[kind].status, r.status);
    if (r.status >= 500 || r.status === 429) return { retry: true, why: 'HTTP ' + r.status };
    if (!r.ok) return { failed: true, why: 'HTTP ' + r.status + ' ' + text.slice(0, 120) };
    return JSON.parse(text);
  } catch (e) {
    stats[kind].ms.push(performance.now() - t0);
    const why = e.name === 'AbortError' ? 'timeout (12s)' : 'network: ' + (e.cause?.code || e.message);
    bump(stats[kind].status, why);
    return { retry: true, why };
  } finally {
    clearTimeout(t);
    inFlight--;
  }
}

function voterId(form, n) {
  const id = String(n).padStart(5, '0');
  if (form.voter_check === 'open') return 'device:lt-' + RUN + '-' + id;
  if (form.voter_check === 'email') return 'lt-' + RUN + '-' + id + '@example.com';
  return 'LT' + RUN + id;
}

function pick(form) {
  const ids = form.candidates.map((c) => c.id);
  const k = 1 + Math.floor(Math.random() * Math.min(form.max_choices || 1, ids.length));
  return ids.sort(() => Math.random() - 0.5).slice(0, k);
}

// ── One simulated person ───────────────────────────────────
async function voter(n) {
  started++;
  const t0 = performance.now();
  const end = (result) => { bump(stats.voter, result); stats.totalMs.push(performance.now() - t0); finished++; };

  // 1. Load the form (the page keeps retrying while "Connecting…"; we give up after ~1 min)
  let form;
  for (let tries = 0; ; tries++) {
    const d = await call('load', 'voting_form_public', { p_slug: SLUG });
    if (d && !d.retry && !d.failed) { form = d; bump(stats.load.outcome, 'ok'); break; }
    bump(stats.load.outcome, d.why);
    if (!RETRY || d.failed || tries >= 10) return end('page never loaded (' + d.why + ')');
    stats.retries++;
    await sleep(3000 + Math.random() * 4000);
  }
  if (form.state !== 'open') return end('form is ' + form.state);

  if (THINK_MS) await sleep(Math.random() * THINK_MS);

  // 2. Cast the vote (same retry rule as the page: up to 4 retries, backing off)
  const body = { p_slug: SLUG, p_voter: voterId(form, n), p_choices: pick(form), p_code: CODE };
  let unsure = false;
  for (let tries = 0; ; tries++) {
    const d = await call('vote', 'cast_vote', body);
    if (d.retry && RETRY && tries < 4) {
      bump(stats.vote.outcome, d.why); unsure = true; stats.retries++;
      await sleep(800 * (tries + 1) + Math.random() * 800);
      continue;
    }
    if (d.retry || d.failed) { bump(stats.vote.outcome, d.why); return end('vote failed (' + d.why + ')'); }
    bump(stats.vote.outcome, d.ok ? 'ok' : d.error);
    if (d.ok || (d.error === 'already' && unsure)) return end('voted');
    return end('rejected: ' + d.error);
  }
}

// ── Report ─────────────────────────────────────────────────
function pct(arr, p) {
  if (!arr.length) return 0;
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
}
const sec = (ms) => (ms / 1000).toFixed(2) + 's';
function latency(label, arr) {
  console.log(`  ${label.padEnd(22)} n=${String(arr.length).padEnd(6)} p50 ${sec(pct(arr, 50))}  p90 ${sec(pct(arr, 90))}  p99 ${sec(pct(arr, 99))}  max ${sec(pct(arr, 100))}`);
}
function table(label, obj) {
  console.log('  ' + label);
  for (const [k, v] of Object.entries(obj).sort((a, b) => b[1] - a[1])) console.log(`    ${String(v).padStart(6)}  ${k}`);
}

// ── Go ─────────────────────────────────────────────────────
console.log(`Load test: ${VOTERS} voters → vote.html?f=${SLUG}`);
console.log(`  arrival: ${RAMP_MS ? 'spread over ' + RAMP_MS / 1000 + 's' : 'all at once'}, think time: up to ${THINK_MS / 1000}s, retries: ${RETRY ? 'like the page' : 'off'}, run id: ${RUN}\n`);

// Make sure the form is usable before firing thousands of requests at it.
const probe = await call('load', 'voting_form_public', { p_slug: SLUG });
stats.load = { ms: [], status: {}, outcome: {} };
if (!probe || probe.retry || probe.failed) { console.log('Could not load the form:', probe?.why); process.exit(1); }
if (probe.state === 'missing') { console.log('No form with that link ending.'); process.exit(1); }
if (probe.state !== 'open') { console.log(`The form is "${probe.state}". Open voting on it first.`); process.exit(1); }
if (!['open', 'any', 'email'].includes(probe.voter_check)) {
  console.log(`This form checks voters against a list ("${probe.voter_check}"), so fake voters would be rejected.`);
  console.log('Use a test form set to "One vote per phone", "Any ID" or "Email".');
  process.exit(1);
}
if (probe.needs_code && !CODE) { console.log('This form needs an access code: add --code <code>.'); process.exit(1); }

const t0 = performance.now();
const ticker = setInterval(() => {
  process.stdout.write(`\r  ${sec(performance.now() - t0).padStart(8)}  started ${started}/${VOTERS}  finished ${finished}  requests in flight ${inFlight}   `);
}, 500);

await Promise.all(Array.from({ length: VOTERS }, (_, i) =>
  (RAMP_MS ? sleep((i / VOTERS) * RAMP_MS) : Promise.resolve()).then(() => voter(i + 1))));

clearInterval(ticker);
const wall = performance.now() - t0;
const voted = stats.voter['voted'] || 0;
console.log(`\r  done in ${sec(wall)}${' '.repeat(60)}\n`);

console.log('Result per voter');
for (const [k, v] of Object.entries(stats.voter).sort((a, b) => b[1] - a[1])) console.log(`    ${String(v).padStart(6)}  ${k}`);
console.log(`\n  ${voted}/${VOTERS} votes counted (${((voted / VOTERS) * 100).toFixed(1)}%), ${(voted / (wall / 1000)).toFixed(0)} votes/s, ${stats.retries} retries, peak ${peakInFlight} requests in flight\n`);

console.log('Response times (per request)');
latency('load form', stats.load.ms);
latency('cast vote', stats.vote.ms);
latency('person waited (total)', stats.totalMs);

console.log('\nHTTP status per request');
table('load form', stats.load.status);
table('cast vote', stats.vote.status);

console.log('\nAnswer per request');
table('load form', stats.load.outcome);
table('cast vote', stats.vote.outcome);

if (JSON.stringify(stats).includes('EMFILE')) {
  console.log('\n!! EMFILE means THIS computer ran out of open connections, not the server.');
  console.log('!! Run  ulimit -n 20000  in the same terminal first, then run the test again.');
}
console.log(`\nThese votes are real. Clear them with Reset on the "${SLUG}" form in the admin.`);
