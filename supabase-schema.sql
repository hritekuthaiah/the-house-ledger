-- =====================================================================
--  THE HOUSE LEDGER — Supabase schema
--  Run this once in your Supabase project:
--    Dashboard ▸ SQL Editor ▸ New query ▸ paste ▸ Run.
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------- tables ----------
create table if not exists sessions (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null,
  name       text not null,
  currency   text not null default '₹',
  status     text not null default 'active',   -- 'active' | 'settled'
  created_at timestamptz not null default now()
);

create table if not exists players (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references sessions(id) on delete cascade,
  name       text not null,
  created_at timestamptz not null default now()
);

create table if not exists entries (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references sessions(id) on delete cascade,
  player_id  uuid not null references players(id)  on delete cascade,
  type       text not null check (type in ('buyin','cashout')),
  amount     numeric not null check (amount >= 0),
  created_at timestamptz not null default now()
);

create index if not exists players_session_idx on players(session_id);
create index if not exists entries_session_idx on entries(session_id);

-- ---------- row level security ----------
-- This is a casual app with no logins: anyone holding the public anon key
-- (i.e. anyone with the site URL) plus a table code can read/write.
-- That's an intentional trade-off for a friends-only poker tracker.
-- If you ever want it locked down, replace these with auth-based policies.
alter table sessions enable row level security;
alter table players  enable row level security;
alter table entries  enable row level security;

drop policy if exists "anon_all_sessions" on sessions;
drop policy if exists "anon_all_players"  on players;
drop policy if exists "anon_all_entries"  on entries;

create policy "anon_all_sessions" on sessions for all using (true) with check (true);
create policy "anon_all_players"  on players  for all using (true) with check (true);
create policy "anon_all_entries"  on entries  for all using (true) with check (true);

-- ---------- realtime ----------
-- Lets every phone at the table see buy-ins / cash-outs live.
alter publication supabase_realtime add table sessions;
alter publication supabase_realtime add table players;
alter publication supabase_realtime add table entries;

-- =====================================================================
--  MIGRATION (2026-06-27) — host PIN + edit-access delegation
--  Run this once more, after the block above, in the same SQL Editor.
--  Safe to run on a database that already has real session/player/entry
--  data: it only adds a new nullable column + a new table, nothing
--  existing is touched. Old sessions end up with host_pin = NULL, which
--  the app treats as "legacy/unlocked" — fully open, exactly like today.
-- =====================================================================

-- one device can be flagged as host per table; NULL = table is unlocked
alter table sessions add column if not exists host_pin text;

-- derived boolean the client CAN see (the raw host_pin is never sent to the
-- client on read paths — see getSession/listSessions in index.html and the
-- check_host_pin RPC below). Lets the app tell a table is locked without
-- ever exposing the PIN value.
alter table sessions
  add column if not exists is_locked boolean
  generated always as (host_pin is not null) stored;

-- durable list of devices the host has granted edit rights to
create table if not exists session_editors (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references sessions(id) on delete cascade,
  device_id    text not null,
  display_name text,
  granted_at   timestamptz not null default now(),
  unique(session_id, device_id)
);

create index if not exists session_editors_session_idx on session_editors(session_id);

alter table session_editors enable row level security;
drop policy if exists "anon_all_session_editors" on session_editors;
create policy "anon_all_session_editors" on session_editors for all using (true) with check (true);

alter publication supabase_realtime add table session_editors;

-- Realtime DELETE events only carry the primary key under the default replica
-- identity, so a subscription FILTERED by session_id never receives deletes
-- (revoking an editor, removing a player, or deleting an entry wouldn't
-- propagate to other devices — they kept stale state until a manual reload).
-- FULL replica identity puts every column in the old-record payload so the
-- session_id filter can match deletes too. (sessions is left default — its
-- realtime filter is on the primary key `id`, which already works.)
alter table session_editors replica identity full;
alter table players         replica identity full;
alter table entries         replica identity full;

-- Server-side PIN check: the client NEVER selects host_pin directly (the
-- anon_all policy above is permissive, so a raw select('*') on sessions
-- would otherwise leak the PIN in plaintext to every viewer). This RPC
-- runs with the function owner's privileges and only ever returns a
-- boolean.
create or replace function check_host_pin(p_session_id uuid, p_pin text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists(
    select 1 from sessions where id = p_session_id and host_pin = p_pin
  );
$$;

-- =====================================================================
--  MIGRATION (2026-06-28) — UPI settle-up
--  Adds an optional UPI ID (VPA) per player so settle-up rows can build
--  tap-to-pay links + QR codes. A UPI ID is a shareable receiving handle,
--  not a secret, so unlike host_pin it's fine to return on read paths.
--  Additive + nullable: existing players are unaffected (upi_id = NULL).
--  The phased game flow (status 'active' → 'ended' → 'settled') needs NO
--  migration — status is a plain text column with no CHECK constraint.
-- =====================================================================
alter table players add column if not exists upi_id text;

-- =====================================================================
--  MIGRATION (2026-06-28) — Stage 1 auth: user profiles
--  One profile per signed-in user (Supabase Auth). Lets people sign in once
--  and have their name + UPI auto-fill everywhere. Additive — the rest of the
--  app still works for the existing device/code flow.
--  RLS: a user manages ONLY their own row (auth.uid() = id); profiles are
--  readable so co-players' names can show. (Tightened to co-membership in a
--  later stage, alongside the broader account/membership RLS rewrite.)
--  The app upserts a row on first sign-in, so no trigger is needed. Not added
--  to the realtime publication (not needed).
-- =====================================================================
create table if not exists profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  upi_id       text,
  created_at   timestamptz not null default now()
);
alter table profiles enable row level security;
drop policy if exists "profiles_self_write" on profiles;
create policy "profiles_self_write" on profiles for all
  using (auth.uid() = id) with check (auth.uid() = id);
drop policy if exists "profiles_read" on profiles;
create policy "profiles_read" on profiles for select using (true);

-- =====================================================================
--  MIGRATION (2026-06-28) — Stage 2: per-account session membership
--  Scopes "Recent Nights" / history to the games a signed-in user actually
--  belongs to, instead of every session in the project. A row is created when
--  a user creates a table (role 'owner'), joins by code, or opens a shared
--  link (role 'member') — the app upserts it on every session open.
--  RLS: a user sees and manages ONLY their own membership rows (one stage
--  before the full account/membership RLS rewrite in Stage 3). Backfill any
--  pre-existing sessions to their owner once (data step, run separately) so
--  their history doesn't disappear.
-- =====================================================================
create table if not exists session_members (
  session_id uuid not null references sessions(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null default 'member',   -- 'owner' | 'member'
  joined_at  timestamptz not null default now(),
  primary key (session_id, user_id)
);
create index if not exists session_members_user_idx on session_members(user_id);

alter table session_members enable row level security;
-- NOTE: this self-only policy is REPLACED by the Stage 3 block below
-- (session_members_select / _insert_self / _delete_self). Kept here for the
-- historical record of how Stage 2 shipped.
drop policy if exists "session_members_self" on session_members;
create policy "session_members_self" on session_members for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- =====================================================================
--  MIGRATION (2026-06-28) — Stage 3: account/membership RLS
--  Replaces the permissive anon-all policies with real account-based access:
--  reads require membership, writes require owner/editor role. Creating and
--  joining tables, role changes, and the self-serve UPI/seat-claim exceptions
--  all run through SECURITY DEFINER RPCs so the table policies stay strict.
--  The host-PIN / session_editors machinery is retired in the follow-up block
--  (run AFTER the Stage 3 client is deployed, so the old client doesn't break).
-- =====================================================================

-- link players to accounts (nullable → owner-added guest seats stay valid)
alter table players add column if not exists user_id uuid references auth.users(id) on delete set null;
create index if not exists players_user_idx on players(user_id);

-- 4-char table code from an unambiguous alphabet (no 0/O/1/I)
create or replace function gen_table_code() returns text
language plpgsql set search_path=public as $$
declare alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; code text := ''; i int;
begin
  for i in 1..4 loop
    code := code || substr(alphabet, 1 + floor(random()*length(alphabet))::int, 1);
  end loop;
  return code;
end $$;

-- Role helpers. SECURITY DEFINER so they bypass RLS on session_members (no
-- policy recursion when referenced from sessions/players/entries policies);
-- auth.uid() still reflects the calling user inside a definer function.
create or replace function is_member(sid uuid) returns boolean
language sql security definer set search_path=public stable as $$
  select exists(select 1 from session_members where session_id=sid and user_id=auth.uid());
$$;
create or replace function can_edit(sid uuid) returns boolean
language sql security definer set search_path=public stable as $$
  select exists(select 1 from session_members where session_id=sid and user_id=auth.uid() and role in ('owner','editor'));
$$;
create or replace function is_owner(sid uuid) returns boolean
language sql security definer set search_path=public stable as $$
  select exists(select 1 from session_members where session_id=sid and user_id=auth.uid() and role='owner');
$$;

-- create a table + owner membership + auto-seat the creator (linked, seeded from
-- their profile name + UPI) so a logged-in creator never has to "This is me".
create or replace function create_session(p_name text) returns sessions
language plpgsql security definer set search_path=public as $$
declare v_code text; v_row sessions; v_try int := 0; v_name text; v_upi text;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  loop
    v_try := v_try + 1;
    v_code := gen_table_code();
    begin
      insert into sessions(code, name, currency, status)
        values (v_code, coalesce(nullif(trim(p_name),''),'Poker Night'), '₹', 'active')
        returning * into v_row;
      exit;
    exception when unique_violation then
      if v_try >= 8 then raise; end if;
    end;
  end loop;
  insert into session_members(session_id, user_id, role)
    values (v_row.id, auth.uid(), 'owner')
    on conflict (session_id,user_id) do update set role='owner';
  select coalesce(nullif(trim(display_name),''),'Player'), upi_id into v_name, v_upi
    from profiles where id=auth.uid();
  insert into players(session_id, name, user_id, upi_id)
    values (v_row.id, coalesce(v_name,'Player'), auth.uid(), v_upi);
  return v_row;
end $$;

-- join by code: become a member + auto-seat (linked, seeded from profile name+UPI)
create or replace function join_by_code(p_code text) returns sessions
language plpgsql security definer set search_path=public as $$
declare v_row sessions; v_name text; v_upi text;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  select * into v_row from sessions where code = upper(trim(p_code)) limit 1;
  if not found then return null; end if;
  insert into session_members(session_id, user_id, role)
    values (v_row.id, auth.uid(), 'member')
    on conflict (session_id,user_id) do nothing;
  if not exists(select 1 from players where session_id=v_row.id and user_id=auth.uid()) then
    select coalesce(nullif(trim(display_name),''),'Player'), upi_id into v_name, v_upi
      from profiles where id=auth.uid();
    insert into players(session_id, name, user_id, upi_id)
      values (v_row.id, coalesce(v_name,'Player'), auth.uid(), v_upi);
  end if;
  return v_row;
end $$;

-- owner-only role changes (the owner row itself is never demoted here)
create or replace function grant_editor(p_session_id uuid, p_user_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not is_owner(p_session_id) then raise exception 'owner only'; end if;
  update session_members set role='editor'
    where session_id=p_session_id and user_id=p_user_id and role<>'owner';
end $$;
create or replace function revoke_editor(p_session_id uuid, p_user_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not is_owner(p_session_id) then raise exception 'owner only'; end if;
  update session_members set role='member'
    where session_id=p_session_id and user_id=p_user_id and role<>'owner';
end $$;

-- set a player's UPI: editors, or the account that owns that seat
create or replace function set_player_upi(p_player_id uuid, p_upi text) returns void
language plpgsql security definer set search_path=public as $$
declare v_sid uuid; v_uid uuid;
begin
  select session_id, user_id into v_sid, v_uid from players where id=p_player_id;
  if v_sid is null then raise exception 'no such player'; end if;
  if not (can_edit(v_sid) or v_uid = auth.uid()) then raise exception 'not allowed'; end if;
  update players set upi_id = nullif(trim(p_upi),'') where id=p_player_id;
end $$;

-- claim a seat for your account (settle-up follows you across devices). A user
-- has at most one linked seat per table: claiming MOVES the link off any other
-- seat they were on (e.g. their auto-created join seat) onto the chosen one.
create or replace function claim_seat(p_player_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare v_sid uuid; v_uid uuid;
begin
  select session_id, user_id into v_sid, v_uid from players where id=p_player_id;
  if v_sid is null then raise exception 'no such player'; end if;
  if not is_member(v_sid) then raise exception 'join first'; end if;
  if v_uid is not null and v_uid <> auth.uid() then raise exception 'seat already claimed'; end if;
  update players set user_id=null where session_id=v_sid and user_id=auth.uid() and id<>p_player_id;
  update players set user_id=auth.uid() where id=p_player_id;
end $$;

grant execute on function create_session(text), join_by_code(text),
  grant_editor(uuid,uuid), revoke_editor(uuid,uuid),
  set_player_upi(uuid,text), claim_seat(uuid) to authenticated;

-- ---------- membership/role RLS (replaces anon-all) ----------
drop policy if exists "anon_all_sessions" on sessions;
create policy sessions_select on sessions for select using (is_member(id));
create policy sessions_update on sessions for update using (can_edit(id)) with check (can_edit(id));
create policy sessions_delete on sessions for delete using (is_owner(id));
-- INSERT only via create_session() (SECURITY DEFINER); no direct-insert policy.

drop policy if exists "anon_all_players" on players;
create policy players_select on players for select using (is_member(session_id));
create policy players_insert on players for insert with check (can_edit(session_id));
create policy players_update on players for update using (can_edit(session_id)) with check (can_edit(session_id));
create policy players_delete on players for delete using (can_edit(session_id));
-- self-serve UPI + seat-claim go through set_player_upi()/claim_seat() (DEFINER).

drop policy if exists "anon_all_entries" on entries;
create policy entries_select on entries for select using (is_member(session_id));
create policy entries_insert on entries for insert with check (can_edit(session_id));
create policy entries_update on entries for update using (can_edit(session_id)) with check (can_edit(session_id));
create policy entries_delete on entries for delete using (can_edit(session_id));

-- session_members: members see co-members (names + Edit Access); you may add only
-- yourself as a plain member and remove only yourself (leave). Role changes are
-- owner-only via grant_editor/revoke_editor.
drop policy if exists "session_members_self" on session_members;
create policy session_members_select on session_members for select using (is_member(session_id));
create policy session_members_insert_self on session_members for insert
  with check (user_id = auth.uid() and role = 'member');
create policy session_members_delete_self on session_members for delete using (user_id = auth.uid());

-- realtime: role grants/revokes + leaves propagate live
alter table session_members replica identity full;
do $$ begin
  alter publication supabase_realtime add table session_members;
exception when duplicate_object then null; end $$;

-- =====================================================================
--  MIGRATION (2026-06-28) — Stage 3 cleanup: retire host-PIN / session_editors
--  Applied AFTER the Stage 3 client shipped (the old client read is_locked /
--  check_host_pin / session_editors, so these were kept dormant until deploy).
--  Editing is now governed by membership role, so this machinery is dead weight.
-- =====================================================================
drop table if exists session_editors;
drop function if exists check_host_pin(uuid, text);
alter table sessions drop column if exists is_locked;   -- generated from host_pin
alter table sessions drop column if exists host_pin;

-- =====================================================================
--  MIGRATION (2026-06-29) — chip counter (optional)
--  Per-session chip set for the chip-counter UI: a JSON array of
--  {value, color} denominations shared across the table. NULL = the app's
--  default poker chip set. Editable by editors (sessions UPDATE = can_edit),
--  readable by members (sessions SELECT = is_member). Counts entered while
--  counting are transient (client-side) — only the resulting cash-out is saved.
-- =====================================================================
alter table sessions add column if not exists chip_config jsonb;
