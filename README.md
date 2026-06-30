# The House Ledger — Poker Night Accounting

Track buy-ins, top-ups and chip cash-outs for your poker night, then settle up
with the fewest payments. Live-synced across everyone's phones via a shared
4-letter **table code**.

- **One file:** `index.html` (no build step, no npm).
- **Shared & live:** powered by Supabase realtime.
- **Works offline first:** until you add Supabase keys it runs in **local demo
  mode** (this device/browser only), so you can try it instantly.

---

## How a poker night works in the app

1. **Start a Table** → gives you a 4-letter code (e.g. `K7QM`).
2. Tap the **⧉ copy** button next to the code to copy a share link; send it to
   your cousins on WhatsApp. They open it (or "Join a Table" + the code) and see
   the same table, live.
3. **Add players**, then hit **+ Buy-in** each time someone puts money in
   (re-buys/top-ups just add again).
4. At the end, hit **Cash out** on each player and enter their **final chip
   value**. The pot strip shows when chips counted = money in (**Pot Balanced ✓**).
5. **The Settle-Up** shows each player's net **and** the fewest transfers to
   square everyone up ("Rohit pays Arjun ₹1,200").
6. **♛ Mark night settled** to file it in **history** and feed the all-time
   **leaderboard**.

Every entry can be **edited or deleted** from the Activity log (✎ / ✕).

---

## Going from demo mode → shared cloud sync (5 minutes, free)

### 1. Create a Supabase project
- Go to <https://supabase.com> → sign in → **New project**.
- Pick any name, set a database password, choose the region closest to you
  (e.g. *South Asia (Mumbai)*), and create it. Wait ~2 min for it to spin up.

### 2. Create the tables
- In the project, open **SQL Editor ▸ New query**.
- Paste the entire contents of [`supabase-schema.sql`](./supabase-schema.sql)
  and click **Run**. You should see "Success".

### 3. Copy your keys
- Open **Project Settings ▸ API**.
- Copy two values:
  - **Project URL** — looks like `https://abcdwxyz.supabase.co`
  - **anon public** key — a long string under "Project API keys"

### 4. Paste them into the app
- Open `index.html`, find the `POKER_CONFIG` block near the top, and replace the
  placeholders:

  ```js
  window.POKER_CONFIG = {
    SUPABASE_URL:      "https://abcdwxyz.supabase.co",
    SUPABASE_ANON_KEY: "eyJhbGciOi...your-long-anon-key..."
  };
  ```

- Reload. The status pill in a table now reads **● Live** (green) instead of
  "This device". Done — everyone with the link is in sync.

> Note: the `anon` key is meant to be public (it ships in the page). Access
> control here is "whoever has the link + table code", which is the right level
> for a friends-only game. See the comments in `supabase-schema.sql` if you ever
> want to lock it down with logins.

---

## Sign-in (accounts + profiles) — Stage 1

When Supabase keys are set, the app asks people to **sign in** (Google or an
emailed magic link). Signing in gives each person a profile (name + UPI ID) that
**auto-fills every game** — no re-typing. Joining a table by code still works as
before once signed in.

Two one-time setup steps in your dashboards:

### A. Allow your app's URLs (required for either method)
- **Supabase ▸ Authentication ▸ URL Configuration**
  - **Site URL:** your live domain — `https://thehouseledger.in`. This is the
    *fallback* Supabase redirects to after sign-in if a request's redirect target
    isn't allow-listed, so it must be your real domain.
  - **Redirect URLs (allow-list):** add every origin sign-in can start from, with
    a wildcard path:
    - `https://thehouseledger.in/**`
    - `https://poker-ledger-tau.vercel.app/**` (the Vercel URL, optional)
    - `http://localhost:3460/**` (local dev)
  - Save. **If the app's current origin isn't on this list, Google/magic-link
    sign-in will bounce to the Site URL instead of back to your app** — that's the
    cause of a "404 / DEPLOYMENT_NOT_FOUND" right after picking your Google
    account when you add a new domain.

> **Adding a custom domain later?** The OAuth callback in `index.html` uses
> `location.origin`, so the code needs no change — but you MUST add the new
> domain to the Redirect URLs allow-list above (and usually point Site URL at it).
> Nothing needs to change in Google Cloud: Google only ever redirects to
> `https://<project-ref>.supabase.co/auth/v1/callback`, never to your app domain.

### B. Turn on Google sign-in (optional but recommended)
- **Google Cloud Console ▸ APIs & Services ▸ Credentials** → create an **OAuth
  client ID** (type: *Web application*). Under *Authorized redirect URIs* add:
  `https://<your-project-ref>.supabase.co/auth/v1/callback`
  (your ref is the subdomain of your Project URL). Copy the **Client ID** and
  **Client secret**.
- **Supabase ▸ Authentication ▸ Providers ▸ Google** → enable, paste the Client
  ID + secret, save.

> **Email magic-link works without step B** — Supabase's built-in email is on by
> default (rate-limited to a few per hour on the free tier; add custom SMTP under
> *Authentication ▸ Emails* if you outgrow that). So anyone with *any* email can
> sign in even if you skip Google.

> The `profiles` table + its RLS are created by `supabase-schema.sql` (run it
> once, as in step 2 above). Each person can edit only their own profile.

### Private "Recent Nights" (Stage 2)

Once signed in, **you only see the games you're part of** — the ones you started,
joined by code, or opened from a shared link. Other people's nights never show up
in your lobby, history, or leaderboard. Membership is recorded automatically the
moment you open a table (the `session_members` table, created by
`supabase-schema.sql`; RLS limits each person to their own rows).

> Upgrading an existing project: after running the Stage 2 block, backfill the
> games that pre-date sign-in so they don't vanish from your lobby —
> `insert into session_members(session_id,user_id,role) select id,'<your-auth-user-id>','owner' from sessions on conflict do nothing;`
> (find your id under **Authentication ▸ Users**).

### Roles & access control (Stage 3)

The database now enforces who can read and edit each game (real row-level
security, not just the UI):

- **Whoever starts a table is its _owner_.** Owners can edit everything and, from
  the in-table **Edit Access** panel, make any member an **editor** (or move them
  back to view-only).
- **Joining by code** makes you a **member**: you can see the game and get your
  own seat, but the ledger is **view-only** until the owner makes you an editor.
- **You only ever see games you've joined** — non-members can't read a table even
  with its link; they must join with the 4-letter code.
- **You get your seat automatically.** Creating or joining a table seats you under
  your profile name with your saved UPI already filled in — no "This is me" step,
  and your seat follows your account across all your devices.
- **Your UPI is private.** Only you see your own UPI ID in the player list. When
  it's time to settle, the people *you owe* get a one-tap Pay button / QR for you —
  nobody browses everyone's payment handles.
- **Your profile** lives behind the round avatar (your initials) in the top-right
  corner — tap it for *Edit profile* and *Sign out*.

> The old per-device "host PIN" lock is gone — access is by account now. The
> retirement step (`drop table session_editors` … in `supabase-schema.sql`) is
> intentionally left commented; run it once the Stage 3 app is deployed.

> Upgrading an existing project to Stage 3: run the Stage 3 block in
> `supabase-schema.sql`. Pre-Stage-2 players appear as **guest seats** (not linked
> to anyone) until each person joins by code and taps "This is me".

---

## Hosting it

It's a static file — drop the folder on any static host:
- **Netlify / Vercel / Cloudflare Pages:** drag-and-drop the `poker-ledger`
  folder, or connect the repo.
- **GitHub Pages:** commit `index.html` and enable Pages.

No server needed. Open the URL on every phone at the table.

---

## Local preview

```bash
npx serve poker-ledger -p 3459
```

Then open <http://localhost:3459>.
