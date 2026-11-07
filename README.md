# CAB Voting

Voting forms for CAB events, hosted at **cabgcu.com/cabvoting**. Uses the same Supabase project as VIP Check In.

| Page | What it is |
| --- | --- |
| `index.html` | Admin: create voting forms, open/close/schedule them, live results, manual votes, student ID list. Logs in with the VIP Check In password. |
| `vote.html?f=<link-ending>` | Public voting page for one form. Each form gets its own link (and QR code) from the admin. |
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

Live Results then shows the combined total, a breakdown by form, and each performer's votes split by form (switch to "only this form" any time). Performers are matched by name. A Student ID or email can vote once across the whole group. The CSV export includes the per-form columns.

Other options: "Any ID (once each)" and "No ID — one vote per phone". Any form can require an access code.

## How it's protected

- All voting tables have Row Level Security on with no policies. The publishable key can't read or edit them directly.
- The voting page can only see an open form and cast one ballot per ID. The database checks the ID list, the pick limit and double votes under a lock.
- Admin actions need a session token that only the staff password gets (30 days with "Keep me signed in", otherwise 12 hours).
