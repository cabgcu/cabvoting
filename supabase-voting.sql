-- ============================================================
-- CAB Voting — Supabase setup (cabgcu.com/cabvoting)
--
-- Run this in Supabase → SQL Editor for the SAME project the
-- VIP Check In uses. It needs section 5 of the check-in's
-- supabase-setup.sql (the admin password) to have been run already:
-- the voting admin logs in with that same password.
--
-- Safe to run more than once:
--   * tables/indexes are only created if missing
--   * functions are replaced with the latest version
--   * no data is dropped, deleted or overwritten
--
-- Security: every voting table has Row Level Security ON with no
-- policies, so the publishable key can't read or change them directly.
-- Everything goes through the functions below:
--   * public functions (voting_form_public, voting_check_voter, cast_vote)
--     only show a form and accept one ballot per student ID
--   * admin functions need a session token from voting_admin_login,
--     which only the staff password can get
-- ============================================================

create extension if not exists pgcrypto with schema extensions;


-- ── 1. Tables ────────────────────────────────────────────────

-- One row per voting page. The public link is vote.html?f=<slug>.
create table if not exists public.voting_forms (
    id               uuid        primary key default gen_random_uuid(),
    slug             text        not null unique,
    name             text        not null default 'Untitled vote',   -- name in the admin
    event_id         text,                                           -- optional link to a check-in event
    title            text,                                           -- heading on the voting page
    intro            text,
    banner_url       text,
    status           text        not null default 'closed',          -- 'closed' | 'open' | 'auto'
    opens_at         timestamptz,
    closes_at        timestamptz,
    voter_check      text        not null default 'roster',          -- 'roster' = ID must be on the student ID list | 'any'
    id_label         text        not null default 'Student ID',
    max_choices      integer     not null default 1,                 -- picks per ballot
    candidates       jsonb       not null default '[]'::jsonb,       -- [{ id, name, subtitle, image_url }]
    closed_message   text,
    success_message  text,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now()
);

-- One row per pick. A ballot with 3 picks = 3 rows sharing a ballot_id.
create table if not exists public.voting_votes (
    id              uuid        primary key default gen_random_uuid(),
    form_id         uuid        not null references public.voting_forms(id) on delete cascade,
    ballot_id       uuid        not null,
    voter_id        text,                                 -- normalized student ID; null for manual votes
    candidate_id    text        not null,
    candidate_name  text,                                 -- name at the time of the vote
    method          text        not null default 'WEB',   -- 'WEB' | 'MANUAL'
    created_at      timestamptz not null default now()
);
create index if not exists voting_votes_form_idx on public.voting_votes (form_id, created_at desc);
create index if not exists voting_votes_ballot_idx on public.voting_votes (ballot_id);
-- Backstop: the same ID can never pick the same performer twice on one form
create unique index if not exists voting_votes_voter_uniq
    on public.voting_votes (form_id, voter_id, candidate_id) where voter_id is not null;

-- Student IDs allowed to vote (shared by every form that checks the list)
create table if not exists public.voting_roster (
    student_id  text        primary key,
    added_at    timestamptz not null default now()
);

-- Admin login sessions (only the sha256 of each token is stored)
create table if not exists public.voting_admin_sessions (
    token_hash  text        primary key,
    expires_at  timestamptz not null
);

alter table public.voting_forms          enable row level security;
alter table public.voting_votes          enable row level security;
alter table public.voting_roster         enable row level security;
alter table public.voting_admin_sessions enable row level security;
revoke all on public.voting_forms, public.voting_votes, public.voting_roster, public.voting_admin_sessions
    from anon, authenticated;


-- ── 2. Helpers ───────────────────────────────────────────────

-- Student IDs are compared without spaces and case: " 2012 3456 " = "20123456"
create or replace function public.voting_norm_id(p text)
returns text language sql immutable as $$
    select lower(regexp_replace(coalesce(p, ''), '\s+', '', 'g'))
$$;

-- Is a form open right now? (server clock, so nobody can vote early)
create or replace function public.voting_form_state(f public.voting_forms)
returns text language sql stable as $$
    select case
        when f.status = 'open' then 'open'
        when f.status <> 'auto' then 'closed'
        when f.opens_at is not null and now() < f.opens_at then 'not_yet'
        when f.closes_at is not null and now() >= f.closes_at then 'ended'
        else 'open'
    end
$$;

create or replace function public.voting_token_hash(p_token text)
returns text language sql immutable set search_path = public, extensions as $$
    select encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

-- Raises if the token isn't a live admin session. Only called by the functions below.
create or replace function public.voting_admin_check(p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
    if p_token is null or p_token = '' or not exists (
        select 1 from public.voting_admin_sessions
         where token_hash = public.voting_token_hash(p_token) and expires_at > now()) then
        raise exception 'not_authorized' using errcode = '28000';
    end if;
end $$;
revoke all on function public.voting_admin_check(text) from public, anon, authenticated;


-- ── 3. Admin login ───────────────────────────────────────────

-- Checks the staff password (verify_admin_password from the check-in setup)
-- and returns a session token, or null if the password is wrong.
create or replace function public.voting_admin_login(pass text, remember boolean default true)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
    v_token text;
begin
    if not public.verify_admin_password(pass) then
        return null;
    end if;
    delete from public.voting_admin_sessions where expires_at < now();
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    insert into public.voting_admin_sessions (token_hash, expires_at)
    values (public.voting_token_hash(v_token),
            now() + case when remember then interval '30 days' else interval '12 hours' end);
    return v_token;
end $$;

create or replace function public.voting_admin_valid(p_token text)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.voting_admin_sessions
                    where token_hash = public.voting_token_hash(p_token) and expires_at > now())
$$;

create or replace function public.voting_admin_logout(p_token text)
returns void language sql security definer set search_path = public as $$
    delete from public.voting_admin_sessions where token_hash = public.voting_token_hash(p_token)
$$;


-- ── 4. Admin: voting forms ───────────────────────────────────

create or replace function public.voting_forms_list(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
    perform public.voting_admin_check(p_token);
    return coalesce((
        select jsonb_agg(to_jsonb(f) || jsonb_build_object(
                   'state', public.voting_form_state(f),
                   'ballots', (select count(distinct v.ballot_id) from public.voting_votes v where v.form_id = f.id))
               order by f.created_at desc)
          from public.voting_forms f), '[]'::jsonb);
end $$;

-- Create (no id) or update (with id) a form. The page sends the whole form.
create or replace function public.voting_form_save(p_token text, p_form jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_id   uuid;
    v_slug text := lower(btrim(coalesce(p_form->>'slug', '')));
    v_row  public.voting_forms;
begin
    perform public.voting_admin_check(p_token);

    if v_slug !~ '^[a-z0-9][a-z0-9-]{0,59}$' then
        return jsonb_build_object('ok', false, 'error', 'slug');
    end if;
    if exists (select 1 from public.voting_forms
                where slug = v_slug and id::text is distinct from nullif(p_form->>'id', '')) then
        return jsonb_build_object('ok', false, 'error', 'slug_taken');
    end if;
    if p_form->'candidates' is not null and jsonb_typeof(p_form->'candidates') <> 'array' then
        return jsonb_build_object('ok', false, 'error', 'candidates');
    end if;

    if nullif(p_form->>'id', '') is null then
        insert into public.voting_forms (slug) values (v_slug) returning id into v_id;
    else
        v_id := (p_form->>'id')::uuid;
    end if;

    update public.voting_forms set
        slug            = v_slug,
        name            = coalesce(nullif(btrim(p_form->>'name'), ''), name),
        event_id        = nullif(p_form->>'event_id', ''),
        title           = nullif(btrim(coalesce(p_form->>'title', '')), ''),
        intro           = nullif(btrim(coalesce(p_form->>'intro', '')), ''),
        banner_url      = nullif(btrim(coalesce(p_form->>'banner_url', '')), ''),
        status          = case when p_form->>'status' in ('open', 'closed', 'auto') then p_form->>'status' else 'closed' end,
        opens_at        = nullif(p_form->>'opens_at', '')::timestamptz,
        closes_at       = nullif(p_form->>'closes_at', '')::timestamptz,
        voter_check     = case when p_form->>'voter_check' = 'any' then 'any' else 'roster' end,
        id_label        = coalesce(nullif(btrim(p_form->>'id_label'), ''), 'Student ID'),
        max_choices     = greatest(1, least(coalesce(nullif(p_form->>'max_choices', '')::int, 1), 50)),
        candidates      = coalesce(p_form->'candidates', '[]'::jsonb),
        closed_message  = nullif(btrim(coalesce(p_form->>'closed_message', '')), ''),
        success_message = nullif(btrim(coalesce(p_form->>'success_message', '')), ''),
        updated_at      = now()
     where id = v_id
    returning * into v_row;

    if not found then
        return jsonb_build_object('ok', false, 'error', 'missing');
    end if;
    return jsonb_build_object('ok', true, 'form', to_jsonb(v_row) || jsonb_build_object(
        'state', public.voting_form_state(v_row),
        'ballots', (select count(distinct ballot_id) from public.voting_votes where form_id = v_row.id)));
end $$;

-- Deletes the form and all of its votes
create or replace function public.voting_form_delete(p_token text, p_form_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
    perform public.voting_admin_check(p_token);
    delete from public.voting_forms where id = p_form_id;
end $$;


-- ── 5. Admin: results & vote management ──────────────────────

create or replace function public.voting_results(p_token text, p_form_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
    perform public.voting_admin_check(p_token);
    return jsonb_build_object(
        'ballots',        (select count(distinct ballot_id) from public.voting_votes where form_id = p_form_id),
        'web_ballots',    (select count(distinct ballot_id) from public.voting_votes where form_id = p_form_id and method = 'WEB'),
        'manual_ballots', (select count(distinct ballot_id) from public.voting_votes where form_id = p_form_id and method <> 'WEB'),
        'picks',          (select count(*) from public.voting_votes where form_id = p_form_id),
        'last_hour',      (select count(distinct ballot_id) from public.voting_votes where form_id = p_form_id and created_at >= now() - interval '1 hour'),
        'by_candidate', coalesce((
            select jsonb_agg(jsonb_build_object('candidate_id', candidate_id, 'name', name, 'count', n, 'web', web, 'manual', manual))
              from (select candidate_id, max(candidate_name) as name, count(*) as n,
                           count(*) filter (where method = 'WEB') as web,
                           count(*) filter (where method <> 'WEB') as manual
                      from public.voting_votes where form_id = p_form_id
                     group by candidate_id) t), '[]'::jsonb),
        'recent', coalesce((
            select jsonb_agg(to_jsonb(r) order by r.created_at desc)
              from (select voter_id, candidate_name, method, created_at
                      from public.voting_votes where form_id = p_form_id
                     order by created_at desc limit 15) r), '[]'::jsonb),
        'server_now', now());
end $$;

create or replace function public.voting_export(p_token text, p_form_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
    perform public.voting_admin_check(p_token);
    return coalesce((
        select jsonb_agg(jsonb_build_object('ballot_id', ballot_id, 'voter_id', voter_id, 'candidate_id', candidate_id,
                                            'candidate_name', candidate_name, 'method', method, 'created_at', created_at)
                         order by created_at)
          from public.voting_votes where form_id = p_form_id), '[]'::jsonb);
end $$;

-- Paper ballots / judges' votes: add p_count votes for one performer
create or replace function public.voting_add_manual(p_token text, p_form_id uuid, p_candidate_id text, p_count integer)
returns integer language plpgsql security definer set search_path = public as $$
declare
    v_name text;
begin
    perform public.voting_admin_check(p_token);
    select c->>'name' into v_name
      from public.voting_forms f, jsonb_array_elements(f.candidates) c
     where f.id = p_form_id and c->>'id' = p_candidate_id;
    if v_name is null then
        raise exception 'Unknown performer';
    end if;
    if p_count is null or p_count < 1 or p_count > 10000 then
        raise exception 'Count must be between 1 and 10000';
    end if;
    insert into public.voting_votes (form_id, ballot_id, voter_id, candidate_id, candidate_name, method)
    select p_form_id, gen_random_uuid(), null, p_candidate_id, v_name, 'MANUAL'
      from generate_series(1, p_count);
    return p_count;
end $$;

-- Undo the most recent p_count manual votes for a performer (fixes a typo)
create or replace function public.voting_remove_manual(p_token text, p_form_id uuid, p_candidate_id text, p_count integer)
returns integer language plpgsql security definer set search_path = public as $$
declare
    v_n integer;
begin
    perform public.voting_admin_check(p_token);
    delete from public.voting_votes where id in (
        select id from public.voting_votes
         where form_id = p_form_id and candidate_id = p_candidate_id and method = 'MANUAL'
         order by created_at desc limit greatest(coalesce(p_count, 0), 0));
    get diagnostics v_n = row_count;
    return v_n;
end $$;

-- Remove one student's ballot so they can vote again
create or replace function public.voting_clear_voter(p_token text, p_form_id uuid, p_voter text)
returns integer language plpgsql security definer set search_path = public as $$
declare
    v_n integer;
begin
    perform public.voting_admin_check(p_token);
    delete from public.voting_votes where form_id = p_form_id and voter_id = public.voting_norm_id(p_voter);
    get diagnostics v_n = row_count;
    return v_n;
end $$;

create or replace function public.voting_reset(p_token text, p_form_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
    v_n integer;
begin
    perform public.voting_admin_check(p_token);
    delete from public.voting_votes where form_id = p_form_id;
    get diagnostics v_n = row_count;
    return v_n;
end $$;


-- ── 6. Admin: student ID list ────────────────────────────────

create or replace function public.voting_roster_count(p_token text)
returns integer language plpgsql security definer set search_path = public as $$
begin
    perform public.voting_admin_check(p_token);
    return (select count(*) from public.voting_roster);
end $$;

-- Adds IDs (the page sends them in batches). p_replace clears the list first.
create or replace function public.voting_roster_add(p_token text, p_ids text[], p_replace boolean default false)
returns integer language plpgsql security definer set search_path = public as $$
declare
    v_n integer;
begin
    perform public.voting_admin_check(p_token);
    if p_replace then
        delete from public.voting_roster where true;
    end if;
    insert into public.voting_roster (student_id)
    select distinct public.voting_norm_id(x) from unnest(coalesce(p_ids, '{}')) x
     where public.voting_norm_id(x) <> '' and length(public.voting_norm_id(x)) <= 40
    on conflict do nothing;
    get diagnostics v_n = row_count;
    return v_n;
end $$;

create or replace function public.voting_roster_remove(p_token text, p_ids text[])
returns integer language plpgsql security definer set search_path = public as $$
declare
    v_n integer;
begin
    perform public.voting_admin_check(p_token);
    delete from public.voting_roster
     where student_id in (select public.voting_norm_id(x) from unnest(coalesce(p_ids, '{}')) x);
    get diagnostics v_n = row_count;
    return v_n;
end $$;

create or replace function public.voting_roster_lookup(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_id text := public.voting_norm_id(p_id);
begin
    perform public.voting_admin_check(p_token);
    return jsonb_build_object(
        'on_list', exists (select 1 from public.voting_roster where student_id = v_id),
        'voted_in', coalesce((select jsonb_agg(distinct f.name)
                                from public.voting_votes v join public.voting_forms f on f.id = v.form_id
                               where v.voter_id = v_id), '[]'::jsonb));
end $$;


-- ── 7. Public voting page (vote.html) ────────────────────────

create or replace function public.voting_form_public(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    f       public.voting_forms;
    v_event text;
begin
    select * into f from public.voting_forms where slug = lower(btrim(coalesce(p_slug, '')));
    if not found then
        return jsonb_build_object('state', 'missing');
    end if;
    if f.event_id is not null then
        select name into v_event from public.events where id::text = f.event_id;
    end if;
    return jsonb_build_object(
        'state', public.voting_form_state(f),
        'title', coalesce(f.title, f.name), 'intro', f.intro, 'banner_url', f.banner_url,
        'event_name', v_event, 'id_label', f.id_label, 'max_choices', f.max_choices,
        'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
                           'id', c->>'id', 'name', c->>'name', 'subtitle', c->>'subtitle', 'image_url', c->>'image_url')), '[]'::jsonb)
                         from jsonb_array_elements(f.candidates) c),
        'closed_message', f.closed_message, 'success_message', f.success_message,
        'opens_at', f.opens_at, 'closes_at', f.closes_at);
end $$;

-- Step 1 on the page: is this ID allowed to vote, and has it voted already?
create or replace function public.voting_check_voter(p_slug text, p_voter text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
    f    public.voting_forms;
    v_id text := public.voting_norm_id(p_voter);
begin
    select * into f from public.voting_forms where slug = lower(btrim(coalesce(p_slug, '')));
    if not found or public.voting_form_state(f) <> 'open' then
        return jsonb_build_object('ok', false, 'error', 'closed');
    end if;
    if v_id = '' or length(v_id) > 40 then
        return jsonb_build_object('ok', false, 'error', 'id');
    end if;
    if f.voter_check = 'roster' and not exists (select 1 from public.voting_roster where student_id = v_id) then
        return jsonb_build_object('ok', false, 'error', 'not_on_list');
    end if;
    if exists (select 1 from public.voting_votes where form_id = f.id and voter_id = v_id) then
        return jsonb_build_object('ok', false, 'error', 'already');
    end if;
    return jsonb_build_object('ok', true);
end $$;

-- Step 2: cast the ballot. Everything is checked again here, under a
-- per-student lock, so one ID can only ever vote once per form.
-- p_choices: ["<candidate id>", ...] — 1 up to the form's max_choices
create or replace function public.cast_vote(p_slug text, p_voter text, p_choices jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    f        public.voting_forms;
    v_id     text := public.voting_norm_id(p_voter);
    v_ballot uuid := gen_random_uuid();
    v_n      integer;
begin
    select * into f from public.voting_forms where slug = lower(btrim(coalesce(p_slug, '')));
    if not found or public.voting_form_state(f) <> 'open' then
        return jsonb_build_object('ok', false, 'error', 'closed');
    end if;
    if v_id = '' or length(v_id) > 40 then
        return jsonb_build_object('ok', false, 'error', 'id');
    end if;
    if f.voter_check = 'roster' and not exists (select 1 from public.voting_roster where student_id = v_id) then
        return jsonb_build_object('ok', false, 'error', 'not_on_list');
    end if;
    if p_choices is null or jsonb_typeof(p_choices) <> 'array' then
        return jsonb_build_object('ok', false, 'error', 'choices');
    end if;

    v_n := (select count(distinct x) from jsonb_array_elements_text(p_choices) x);
    if v_n < 1 or v_n <> jsonb_array_length(p_choices) or v_n > f.max_choices then
        return jsonb_build_object('ok', false, 'error', 'choices', 'max', f.max_choices);
    end if;
    if exists (select 1 from jsonb_array_elements_text(p_choices) x
                where not exists (select 1 from jsonb_array_elements(f.candidates) c where c->>'id' = x)) then
        return jsonb_build_object('ok', false, 'error', 'choices', 'max', f.max_choices);
    end if;

    perform pg_advisory_xact_lock(hashtext('voting:' || f.id::text || ':' || v_id));
    if exists (select 1 from public.voting_votes where form_id = f.id and voter_id = v_id) then
        return jsonb_build_object('ok', false, 'error', 'already');
    end if;

    insert into public.voting_votes (form_id, ballot_id, voter_id, candidate_id, candidate_name, method)
    select f.id, v_ballot, v_id, x, (select c->>'name' from jsonb_array_elements(f.candidates) c where c->>'id' = x limit 1), 'WEB'
      from jsonb_array_elements_text(p_choices) x;

    return jsonb_build_object('ok', true, 'ballot_id', v_ballot);
exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'already');
end $$;


-- ── 8. Who can call what ─────────────────────────────────────

grant execute on function public.voting_form_public(text)               to anon, authenticated;
grant execute on function public.voting_check_voter(text, text)         to anon, authenticated;
grant execute on function public.cast_vote(text, text, jsonb)           to anon, authenticated;

-- Admin functions: callable with the publishable key, but each one checks the session token
grant execute on function public.voting_admin_login(text, boolean)      to anon, authenticated;
grant execute on function public.voting_admin_valid(text)               to anon, authenticated;
grant execute on function public.voting_admin_logout(text)              to anon, authenticated;
grant execute on function public.voting_forms_list(text)                to anon, authenticated;
grant execute on function public.voting_form_save(text, jsonb)          to anon, authenticated;
grant execute on function public.voting_form_delete(text, uuid)         to anon, authenticated;
grant execute on function public.voting_results(text, uuid)             to anon, authenticated;
grant execute on function public.voting_export(text, uuid)              to anon, authenticated;
grant execute on function public.voting_add_manual(text, uuid, text, integer)    to anon, authenticated;
grant execute on function public.voting_remove_manual(text, uuid, text, integer) to anon, authenticated;
grant execute on function public.voting_clear_voter(text, uuid, text)   to anon, authenticated;
grant execute on function public.voting_reset(text, uuid)               to anon, authenticated;
grant execute on function public.voting_roster_count(text)              to anon, authenticated;
grant execute on function public.voting_roster_add(text, text[], boolean) to anon, authenticated;
grant execute on function public.voting_roster_remove(text, text[])     to anon, authenticated;
grant execute on function public.voting_roster_lookup(text, text)       to anon, authenticated;
