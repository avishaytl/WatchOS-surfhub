# Watch Authentication & Upload — complete REST contract for a 3rd-party watch app

This is everything a **separately-built** watch app needs to (1) log a rider in
and (2) upload riding sessions to SurfHub's backend. It is a **pure REST/HTTP
contract** — no dependency on SurfHub's app code. Implement it in Swift, Kotlin,
or anything that can make HTTPS calls + store a token securely.

> 📄 **This file is the authoritative, self-contained REST contract — start
> here.** A second doc, `WATCH_LIVE_SESSION.md`, explains the same flow at a
> higher level (what the live session does, what followers see) and is optional
> reading. If the two ever disagree on a request/response shape, **this file
> wins.**

> Model: **registration happens in the SurfHub phone app**. The watch then gets a
> session for that **same UID** in one of **two ways** — pick whichever you build
> first, you can support both:
>
> 1. **QR pairing (fastest, §2.6)** — the **WATCH displays a one-time QR** and the
>    **PHONE scans it** with its camera (the watch has no camera). After the rider
>    confirms on the phone, the watch polls and receives a fresh token bundle. No
>    keyboard on the watch. **Recommended primary path.**
> 2. **Direct login (§2.1–2.3)** — the watch shows a LOGIN-ONLY screen (Email +
>    Google) and the rider signs in there.
>
> Both end identically: the watch holds `{ access_token, refresh_token, uid }`
> for the rider and uploads via `watch-ingest` (§3). There is **no sign-up on the
> watch** either way.

---

## 0. Project connection values (constants you hardcode/ship)

These are the only fixed values you need. The first two are short; the **anon
key** is one long string — it is given in full as its own block below (do NOT
type it by hand; copy the whole block).

| Value | What it is |
|---|---|
| **Base URL** | `https://vvowvcdylztsqpzifdqc.supabase.co` |
| **Project ref** | `vvowvcdylztsqpzifdqc` |
| **watch-ingest URL** | `https://vvowvcdylztsqpzifdqc.supabase.co/functions/v1/watch-ingest` |
| **watch-link URL** (QR pairing, §2.6) | `https://vvowvcdylztsqpzifdqc.supabase.co/functions/v1/watch-link` |
| **QR payload the WATCH displays** | `surfhub://watch-pair?code=<code>` (code = 10 chars `[A-Z2-9]`) |
| **Google Web client ID** | `504073436614-k185g5tlbg7asjhag6l97rdnf43nian8.apps.googleusercontent.com` |
| **Google iOS client ID** | `504073436614-9qec94thlrslcbvqfnot83ovrg2uoctu.apps.googleusercontent.com` |

### The anon key (the `apikey` header value)

This is **ONE single string** (a JWT). It is sent as the HTTP header
`apikey: <this value>` on **every** request in §2 and §3. It may wrap onto
several lines on screen, but it is one continuous token with **no spaces and no
line breaks** — copy it whole, exactly as is:

```text
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY
```

**What this key is and why it's safe:**
- It is the project's **public "anon" key** — the same one already shipped inside
  the SurfHub phone app. It is *designed* to be embedded in client apps.
- A JWT has three dot-separated parts (`header.payload.signature`). Decoding its
  payload shows `"role": "anon"` and `"ref": "vvowvcdylztsqpzifdqc"` — i.e. it
  only identifies the project and the anonymous role. It grants **no data access
  on its own**; Row-Level Security + the rider's login JWT control all access.
- ✅ Safe to commit in the watch repo / hardcode in the app.
- ❌ This is NOT the `service_role` key. A `service_role` key (its payload would
  say `"role":"service_role"`) bypasses all security and must **never** appear in
  the watch app. If someone gives you a key whose role is `service_role`, do not
  use it.

> If we ever rotate the anon key we'll send you the new value. Until then this
> one is valid (it expires in ~2036).

---

## 1. The end-to-end picture

```
Phone app:  Sign UP  ─► Supabase Auth creates the user + UID
                         (a `profiles` row is auto-created by a DB trigger)
                                   │
              ┌────────────────────┴─────────────────────┐
              │ get a session for that UID — EITHER:      │
              │                                           │
  (A) QR PAIR │ WATCH: watch-link {request} ─► code       │  (B) DIRECT LOGIN
   (watch     │  → DISPLAY QR  surfhub://watch-pair?code=  │   Watch: Email/Google
    shows QR, │  → poll {poll,code} … pending …           │    POST /auth/v1/token
    phone     │ PHONE (camera): scan → {peek} → confirm    │    ─► { access_token,
    scans)    │  → {approve,code,refreshToken}            │       refresh_token,
              │ WATCH: next poll ─► { accessToken,         │       user.id }
              │   refreshToken, uid, ingestUrl, … }        │
              └────────────────────┬─────────────────────┘
                                   │  store { access, refresh, uid } in Keychain
                                   ▼
            POST /functions/v1/watch-ingest   (Authorization: Bearer <access_token>)
              start ─► ping… ─► record… ─► end
                                   │
                         sessions land under the rider's UID
                         (server pins every write to the token's UID via RLS)
```

Both paths leave the watch as an **independent Supabase client for the same
account**. QR pairing (A) hands the watch a freshly-minted session with no
keyboard — the watch only ever DISPLAYS a code and POLLS; the signed-in phone
does the scanning and approving. After pairing, refresh/upload/sign-out are
identical to direct login. WatchConnectivity is **not** used (separate apps).

---

## 2. AUTH — Supabase GoTrue REST

Every request below includes **two required headers**:
```
apikey: <anon key>
Content-Type: application/json
```

> **Enabled providers on this project (verified):** only **Email/password** and
> **Google** are turned on. Apple, phone, and anonymous sign-in are **OFF** — do
> not implement them, they will fail. (Confirmed via `GET {base}/auth/v1/settings`:
> `external.email=true, external.google=true, external.apple=false`.)

### 2.1 Email + password sign-in
```
POST {base}/auth/v1/token?grant_type=password
{ "email": "rider@example.com", "password": "••••••••" }
```
**200 response (store access_token, refresh_token, AND user.id):**
```json
{
  "access_token": "eyJ...",          // JWT — send as Bearer to watch-ingest
  "token_type": "bearer",
  "expires_in": 3600,
  "expires_at": 1775500000,          // unix seconds — when access_token dies
  "refresh_token": "v1.Mr8...",      // use to get a new access_token
  "user": {
    "id": "550e8400-e29b-41d4-a716-446655440000",   // the rider's UID
    "email": "rider@example.com",
    "user_metadata": { "name": "Dani" }
  }
}
```
**Error responses — exact shape (verified). The body is always**
`{ "code": <int>, "error_code": "<string>", "msg": "<string>" }`. Parse
`error_code`:
| HTTP | `error_code` | Show the rider |
|---|---|---|
| 400 | `invalid_credentials` | "Wrong email or password." (also returned when the email doesn't exist — GoTrue does not distinguish, for privacy) |
| 400 | `email_not_confirmed` | "Confirm your email first (check the inbox you used to sign up)." |
| 429 | `over_request_rate_limit` / `over_email_send_rate_limit` | "Too many attempts — wait a moment." |

Example real error body:
`{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}`

> **Email confirmation IS required on this project** (`mailer_autoconfirm=false`).
> A brand-new account must click the confirmation link in the signup email
> (sent by the PHONE app's sign-up) before it can sign in anywhere — including
> the watch. If `email_not_confirmed` comes back, tell the rider to confirm from
> the email, then sign in again. (You never trigger this from the watch because
> the watch does not sign up.)

> The watch must NOT offer sign-up. New accounts are created only in the phone
> app (which also creates the required `profiles` row via a DB trigger). A
> watch-only "sign up" would create an auth user with no profile and uploads
> would fail.

### 2.2 Google sign-in (ID-token flow)
Obtain a Google **ID token** on the watch via Google Sign-In, then exchange it:
```
POST {base}/auth/v1/token?grant_type=id_token
{ "provider": "google", "id_token": "<google id_token>" }
```
Same 200 response shape as 2.1.

**Google setup you must do (one-time, in Google Cloud Console for the watch app):**
1. The watch app needs its **own OAuth client** registered under the **same
   Google Cloud project** that owns the client IDs in §0 — using the watch app's
   **bundle ID** (iOS) or **package name + SHA-1** (Wear OS/Android).
2. Request scopes `openid email profile`.
3. The **ID token's `aud`** (audience) must be a client ID that Supabase's Google
   provider trusts. Supabase already trusts the **Web client ID** in §0; on
   iOS/watchOS, Google Sign-In returns an ID token whose `aud` is your iOS client
   ID but also carries the web client as the server-side audience when you set
   `serverClientID` (iOS) / `requestIdToken(webClientId)` (Android) to the **Web
   client ID** in §0. **Set the web client ID from §0 as the server/requested-token
   client ID** so the resulting `id_token` is accepted by Supabase.
4. No backend change is needed on our side — the Google provider is already on
   and already trusts that Web client ID (the phone app uses the same setup).

> If `grant_type=id_token` returns 400 with `bad_oauth_state` / `validation_failed`,
> the ID token's audience isn't trusted — re-check step 3 (you used the Web
> client ID from §0 as the server/requested client ID).
>
> watchOS note: native Google Sign-In on watchOS is limited. **Email+password
> always works with no SDK** — ship that first; add Google when the SDK path is
> sorted. (Apple sign-in is NOT an option here — it's disabled on the project.)

### 2.3 Refresh the access token (do this before it expires)
Access tokens last ~1 h (`expires_at`). Refresh when within ~2 min of expiry:
```
POST {base}/auth/v1/token?grant_type=refresh_token
{ "refresh_token": "<refresh_token>" }
```
→ same shape; **store the rotated access_token AND refresh_token** (the refresh
token rotates too). If this returns 400/401, the session is dead → clear stored
tokens and show the login screen.

### 2.4 Sign out (optional, best practice)
```
POST {base}/auth/v1/logout
Authorization: Bearer <access_token>
apikey: <anon key>
```
Then delete the stored tokens locally.

### 2.5 Token storage
Persist `{ access_token, refresh_token, expires_at, uid }` in the **Keychain**
(iOS) / **Keystore** (Wear OS). Never write tokens to logs or disk in plaintext.
On app launch: if a stored session exists, refresh it (2.3) and go straight to
recording; otherwise show login (or the QR-pairing screen, §2.6).

### 2.6 QR pairing — the WATCH shows a QR, the PHONE scans it (NO login on the watch)

This is the **recommended primary onboarding**. **The watch has no camera, so the
WATCH DISPLAYS a QR and the PHONE (already signed in) SCANS it** with its camera —
the reverse of WhatsApp Web. This is the "device authorization" pattern (Apple TV
sign-in). No email/password is typed on the watch.

**The watch's job (you implement TWO calls): `request` then loop `poll`.**

```
                WATCH                                  PHONE (SurfHub app)
   1. request ──────────────────────────►
        ◄── { code, qrPayload, expiresAt }
   2. DISPLAY qrPayload as a QR on screen
   3. poll ─► {status:'pending'}  (repeat)
                                          4. rider scans the QR with the phone
                                          5. app peeks + shows "Connect <model>?"
                                          6. rider taps Connect → app approves
   7. poll ─► {status:'approved', accessToken, refreshToken, uid, …}
   8. store the session → paired. Stop polling.
```

**How it stays secure:** the QR/code is a one-time **nonce**, never a token. It is
useless to a stranger — it only lets the holder *poll* a row that stays pending
until the **right signed-in rider approves it on their phone**, and the row dies
in 5 minutes or on first claim. The rider's refresh token is attached only at the
phone's `approve` step and is exchanged server-side for a **brand-new** pair at
the watch's claiming poll.

All calls: `POST {base}/functions/v1/watch-link`, header `apikey: <anon key>`,
`Content-Type: application/json`, **NO Authorization header** (the watch has no
session). Body:

**(1) request** — create a pairing code and show it as a QR:
```json
{ "action": "request", "deviceName": "Dani’s Apple Watch", "deviceModel": "Apple Watch Series 10" }
```
→ `200 { "code": "WWR89D5SUS", "qrPayload": "surfhub://watch-pair?code=WWR89D5SUS", "expiresAt": "<iso>" }`
- `deviceName`/`deviceModel` are **optional** display text shown to the rider in
  the phone's "Connect <model>?" prompt — send them so the rider recognises the
  watch. Render `qrPayload` verbatim as a QR (don't rebuild the string yourself).
- The code lives **5 minutes**. If `expiresAt` passes with no approval, call
  `request` again for a fresh QR.

**(2) poll** — repeat every ~2 s until approved (or expiry):
```json
{ "action": "poll", "code": "WWR89D5SUS" }
```
Responses:
| HTTP | body | Do |
|---|---|---|
| 200 | `{ "status": "pending" }` | Not approved yet — keep polling. |
| 200 | `{ "status": "approved", accessToken, refreshToken, expiresAt, uid, ingestUrl, supabaseUrl, anonKey }` | **Paired!** Store the session, stop polling. |
| 404 / 410 | `{ "status": "expired" }` | Code gone (expired / already claimed). Show a "code expired" state and offer to generate a new QR (`request` again). |
| 401 | `{ "status": "error", "error": "session no longer valid — re-approve on the phone" }` | The phone's session died after approving. Ask the rider to re-open the QR screen on the phone. |

The **approved** body is the **same bundle as a login (§2.1)** plus the project
constants for convenience:
```json
{
  "status": "approved",
  "accessToken":  "eyJ...",            // JWT — send as Bearer to watch-ingest
  "refreshToken": "v1.Mr8...",         // rotate + persist (same as login)
  "expiresAt":    1775500000,          // unix seconds — when accessToken dies
  "uid":          "550e8400-...",      // the rider's UID (matches the phone)
  "ingestUrl":    "https://vvowvcdylztsqpzifdqc.supabase.co/functions/v1/watch-ingest",
  "supabaseUrl":  "https://vvowvcdylztsqpzifdqc.supabase.co",
  "anonKey":      "eyJhbGci..."        // same public anon key as §0
}
```
Persist `{ accessToken, refreshToken, expiresAt, uid }` in the Keychain, refresh
via §2.3, upload via §3 — identical to direct login from here.

> The watch-link endpoint takes **no** `Authorization` header for `request`/`poll`
> (deployed `--no-verify-jwt`); they are gated by the one-time code. The phone's
> `peek`/`approve` (which you do NOT implement on the watch — the SurfHub app does)
> DO carry the rider's JWT. Always send the `apikey` header on every call.
>
> **Polling etiquette:** poll about every **2 seconds**, and stop after
> `expiresAt` (≤5 min) — show "code expired, tap to refresh" rather than polling
> forever. A single claim returns the session exactly once; a later poll of the
> same code returns `expired`.

**Verified live (2026-06-11):** watch `request` → `poll` (pending) → phone `peek`
(returns the device name/model) → phone `approve` → watch `poll` returns the full
bundle above; that `accessToken` authenticates as the phone's UID via
`GET /auth/v1/user`; a **second** poll of the same code returns `404 expired`
(single-use — the row is deleted on claim).

---

## 3. UPLOAD — `watch-ingest` Edge Function

Every call:
```
POST {base}/functions/v1/watch-ingest
Authorization: Bearer <access_token>      ← the rider's JWT from §2
apikey: <anon key>
Content-Type: application/json
```
The server reads the UID from the JWT and pins all writes to it — the rider can
only ever write their own data.

**Two error formats — handle BOTH (verified live):**
- **`401` (auth)** comes from the Supabase platform *before* the function runs,
  so it does NOT use the `{error:…}` shape. Real body:
  `{ "code": "UNAUTHORIZED_INVALID_JWT_FORMAT", "message": "Invalid JWT" }`.
  On any `401`: refresh the token (§2.3) and retry once; if still `401` → login.
- **`400` / `405` (function)** use `{ "error": "<reason>" }`, e.g.
  `405 {"error":"method"}` (must be POST), `400 {"error":"lat/lng required"}`,
  `400 {"error":"unknown type"}`.
- **`200`** always returns JSON in the per-call shapes below.

### 3.1 start — open a live session (rider hits the water)
```json
{ "type": "start", "lat": 36.0128, "lng": -5.6012, "startedAt": "2026-06-09T08:00:00Z" }
```
→ `200 { "sessId": 1234, "spot": "ProSurf Tarifa", "poiKind": "club" }`
Keep `sessId` for every later call. The server resolves the nearby spot/club
name from the GPS and notifies the rider's followers that they're live.
- `startedAt` is ISO-8601; omit it and the server uses "now".
- `lat`/`lng` are **required** — omitting them returns `400 {"error":"lat/lng required"}`.
- If no spot/club is within ~1.5 km, `spot` and `poiKind` come back **`null`**
  (verified): `{ "sessId": 38, "spot": null, "poiKind": null }`. That's fine —
  the session still records; it just has no resolved place name.

### 3.2 ping — position heartbeat (~every 10 s while riding)
```json
{ "type": "ping", "sessId": 1234, "lat": 36.0130, "lng": -5.6014, "jmax": 2.1, "jcnt": 3 }
```
→ `200 { "ok": true }`
`jmax` (session-best jump in metres so far) and `jcnt` (jumps so far) are
optional and only keep the live leaderboard ordering fresh. They do NOT trigger
record notifications — use `record` for that.
> Note: `ping` returns `{ok:true}` even if the `sessId` is wrong/stale (it's a
> best-effort heartbeat). Always use the `sessId` returned by `start`.

### 3.3 record — a NEW session-best metric (the moment it happens)
Send ONLY the metric(s) that just improved this session:
```json
{ "type": "record", "sessId": 1234, "jumpM": 4.8, "airS": 3.1 }
```
→ `200 { "broken": ["jump", "air"] }`
The server decides if each value beats the rider's ALL-TIME personal best; for
every metric that does, it (a) updates the all-time record, (b) writes a
`record_events` row → followers get a "new record" push, and returns that metric
in `broken`. Fields (all optional): `jumpM` (m), `airS` (s), `speedKmh`, `distKm`.
- If **nothing** was an all-time best, you get `200 { "broken": [] }` (no push).
- Gate your calls on the **session** best (only call when this session beats its
  own best so far) so you don't hit the endpoint on every single jump. The
  server still does the authoritative all-time check.
- On a rider's very first ever session, every metric beats their (empty) record,
  so early `record` calls will report breaks — that's correct.

### 3.4 end — finalize (rider leaves the water)
```json
{
  "type": "end", "sessId": 1234,
  "durMin": 72, "windKts": 18, "dir": "W",
  "jmax": 4.8, "jcnt": 9, "airS": 3.1, "spdKmh": 41, "distKm": 12.5, "avgKmh": 24.3,
  "stars": 4,
  "track": [[360128,-56012],[360130,-56014]],
  "jData": [{ "t":120, "h":480, "a":31, "s":41, "d":21, "y":360128, "x":-56012 }]
}
```
→ `200 { "ok": true, "broken": ["speed","dist"] }`
Saves the full session, flips it out of "live", runs a final PB check (so a
record set on the very last jump, or a speed/distance max only the full-session
analysis knows, still counts), and clears the live ping.
- **Send every field** for a complete session: `durMin, jmax, jcnt, airS,
  spdKmh, distKm, track, jData`. The server is lenient — a partial `end`
  (e.g. only `type`+`sessId`) still returns `200` but fills the missing numbers
  with 0/empty, so the saved session looks broken. Don't rely on that; send the
  full payload.
- Optional: `windKts, dir, avgKmh, stars` (stars defaults to 3).
- Call `end` exactly once per session. After it, the live ping is gone and the
  session is no longer "live".

---

## 4. DATA FORMATS — exact encodings (must match)

### Scalars in `end`
| Field | Unit | Example |
|---|---|---|
| `durMin` | whole minutes | `72` |
| `jmax` | metres | `4.8` |
| `jcnt` | count | `9` |
| `airS` | seconds | `3.1` |
| `spdKmh` | km/h (int) | `41` |
| `distKm` | km | `12.5` |
| `avgKmh` | km/h | `24.3` |
| `windKts` | knots (int) | `18` |
| `stars` | 1–5 | `4` |

### `jData` — one object per jump (COMPACT, integer-scaled)
```
{ t, h, a, s, d, y, x }
  t = seconds offset from session start   (int)        120  → at 2:00
  h = jump height in CENTIMETRES           (int)        480  → 4.80 m
  a = air time in TENTHS of a second       (int)        31   → 3.1 s
  s = top speed during the jump, km/h      (int)        41
  d = jump distance in DECIMETRES          (int)        21   → 2.1 m
  y = latitude  * 1e4                       (int)        360128 → 36.0128
  x = longitude * 1e4                       (int)        -56012 → -5.6012
```
> Note the scaling: height is **cm**, air is **tenths-sec**, distance is **dm**,
> lat/lng are **×1e4**. This is NOT the same scale as the `end` scalars (which
> are plain m/s/km). Encode jumps in these integer units.

### `track` — GPS polyline, decimated (one point every ~5 s)
```
[[ lat*1e4, lng*1e4 ], ...]    e.g. [[360128,-56012],[360130,-56014]]
```

---

## 5. Quick connectivity test (run this from any terminal)

Replace `EMAIL`/`PASSWORD` with a real SurfHub account (created in the phone app):
```bash
BASE="https://vvowvcdylztsqpzifdqc.supabase.co"
ANON="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY"

# 1. Sign in → grab access_token + uid
curl -s -X POST "$BASE/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"email":"EMAIL","password":"PASSWORD"}'

# 2. Start a session (paste the access_token from step 1)
JWT="<access_token>"
curl -s -X POST "$BASE/functions/v1/watch-ingest" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"type":"start","lat":36.0128,"lng":-5.6012}'
# → {"sessId":N,"spot":"...","poiKind":"..."}
```
This exact sequence has been verified end-to-end against the live backend
(login → start → ping → record → end → rows written under the rider's UID).

---

## 6. Reference Swift implementation (optional)

If you build the watch app in Swift you may copy these files from
`surfhub-watch/watchos/SurfHubWatch Watch App/` as a starting point (they
implement §2–§4 already):
- `WatchAuth.swift` — login + Google + **QR pairing request/poll (§2.6)** + refresh + logout (§2)
- `WatchPairQR.swift` — the QR-pairing screen (shows the QR + polls) (§2.6)
- `WatchPairingStore.swift` — Keychain token store + auto-refresh (§2.3/§2.5)
- `WatchSessionUploader.swift` — the four `watch-ingest` calls (§3)
- `LiveSessionController.swift` — wires the jump engine + GPS to the uploader

You only build the **login UI** and connect the recording UI. If you build in
Kotlin/other, implement the REST contract above directly — the files are just a
reference.

---

## 7. Security checklist

- ✅ anon key in the binary — fine (public). **service_role key — never.**
- ✅ `apikey` header on EVERY auth + function call.
- ✅ Tokens in Keychain/Keystore only; sent only to `*.supabase.co` over TLS;
  never logged.
- ✅ Login only (no sign-up on the watch). Same UID as the phone account.
- ✅ **QR pairing carries only a one-time code, never a token.** The WATCH shows
  the QR; the PHONE scans + approves. The code is single-use + 5-min TTL and is
  worthless until the right signed-in rider approves it — a photographed QR can at
  most poll a pending row that then expires.
- ✅ Row-Level Security pins writes to the JWT's UID — the watch can only write
  for the signed-in rider (true for both QR-paired and directly-logged-in tokens).
- ✅ On `401`: refresh once; if still failing, clear tokens → login / QR screen.

---

## 8. What the rider sees (so you can verify your build)

After a real `end`:
- The rider's **profile** in the phone app shows the new session and updated
  Personal Records (with a "NEW" badge on any record broken in the last 24 h).
- **Followers** got a push when the session started ("X is riding · ProSurf
  Tarifa") and on each new personal record ("X just set a new highest jump —
  4.8 m!"), and saw the rider live on the Community feed while riding.
- The session feeds the global **rankings**.
