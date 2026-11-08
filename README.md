# CAB Voting

Voting forms for CAB events, hosted at **cabgcu.com/cabvoting**. Uses the same Supabase project as VIP Check In.

| Page | What it is |
| --- | --- |
| `index.html` | Admin: create voting forms, open/close/schedule them, live results, manual votes, student ID list. Logs in with the VIP Check In password. |
| `vote.html?f=<link-ending>` | Public voting page for one form. Each form gets its own link (and QR code) from the admin. |
| `loadtest.mjs` | Load test: simulate thousands of people voting at once (see below). |
| `supabase-voting.sql` | Database setup. Run once in Supabase → SQL Editor (safe to re-run). |

## Setup

1. In Supabase → SQL Editor for the check-in project, run `supabase-voting.sql`.
   It needs the check-in's admin password function (section 5 of the check-in's `supabase-setup.sql`), which is already set up if the check-in login works.
2. Open `index.html`, log in, and click **New voting form**.
3. Upload the student ID list under **Student IDs** (or set a form to "Any ID").
4. Open voting from the form card or the Live Results page.

## Several ways to vote, one result

Make one form per way of voting, and give them all the same **Results group** (e.g. `GGT 2026`):

| Form | Who can vote |
| --- | --- |
| GGT Arena | Student ID on the Student ID list |
| GGT Online | Email address (add an access code shown on the stream) |
| GGT VIP | Email on the VIP Check In guest list for the event |

Quickest way: **New voting form** → pick the voting method → **Copy performers from** your first form. That fills in the same performers and puts both forms in one results group.

The **Active event / form** picker lists each group once (e.g. "GGT 2026 · 3 forms"). Live Results then shows the combined total, a breakdown by form, and each performer's votes split by form (tap a form name to see it alone). Performers are matched by name. A Student ID or email can vote once across the whole group. "Open all" / "Close all" and Reset apply to every form in the group, and manual votes ask which form they go to. The CSV export includes the per-form columns.

Other options: "Any ID (once each)" and "No ID — one vote per phone". Any form can require an access code.

### Text votes from Poll Everywhere

Poll Everywhere no longer has a public API, so text votes come in from its CSV export:

1. Make a form (e.g. **GGT Text**) with "Who can vote" set to **Text message — import from Poll Everywhere**, copying performers from your first form so it joins the same results group.
2. In Poll Everywhere, download the poll's responses as a CSV, with phone numbers included.
3. In Live Results (or on the form's card) click **Import CSV**. The admin finds the answer, phone and source columns, matches each answer to a performer (change any that are wrong), and counts one vote per phone number. A phone's first text is the one that counts.
4. Upload a newer export as often as you like during the show. Phone numbers already counted are skipped, so only new texts are added.

## How it's protected

- All voting tables have Row Level Security on with no policies. The publishable key can't read or edit them directly.
- The voting page can only see an open form and cast one ballot per ID. The database checks the ID list, the pick limit and double votes under a lock.
- Admin actions need a session token that only the staff password gets (30 days with "Keep me signed in", otherwise 12 hours).

## Load test (what happens when 6000 people vote at once)

`loadtest.mjs` makes N simulated voters each load the form and cast a vote at the same moment, using the same 12 s timeout and retry rules as `vote.html`. It needs Node 18 or newer and nothing else.

1. In the admin, make a **test form** (not a live one) with a few performers. Set **Who can vote** to *One vote per phone*, *Any ID* or *Email*; a form that checks the Student ID list or VIP guest list would reject the fake voters.
2. Open voting on it.
3. Run, from this folder:
   ```
   ulimit -n 20000
   node loadtest.mjs --form <link-ending> --voters 6000
   ```
   `ulimit` lets your computer open 6000 connections at once (macOS allows only 256 by default).
4. When it's done, press **Reset** on the test form to delete the test votes.

Options: `--ramp 30` spreads the 6000 arrivals over 30 seconds (more like a real crowd after a QR code goes up); `--think 10` gives each voter up to 10 s to pick; `--code X` for a form with an access code; `--no-retry` shows raw first-try failures.

The report shows how many votes were counted, response times (p50 / p90 / p99), and every HTTP status and error. Mostly `200` and "voted" = it held up. `503`/`429`/timeouts = the server was busy (voters see "Network is busy — still sending…"). If many votes failed after retries, that's what real voters would have seen.

Note: all 6000 requests come from one computer and one IP, which is harsher than real phones on different networks, and Supabase may throttle a single IP. If you see lots of `429`, try a `--ramp`.

