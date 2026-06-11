# Watch Authentication & Upload — complete REST contract for a 3rd-party watch app

This is everything a **separately-built** watch app needs to (1) log a rider in
and (2) upload riding sessions to SurfHub's backend. It is a **pure REST/HTTP
contract** — no dependency on SurfHub's app code. Implement it in Swift, Kotlin,
or anything that can make HTTPS calls + store a token securely.

> Model: **registration happens in the SurfHub phone app**. The watch app shows a
> **LOGIN-ONLY** screen (Email + Google). The rider signs in with the same
> account; the watch gets its own session for the same UID and uploads sessions
> that land under that rider's account.

---

## 0. Project connection values (constants you hardcode/ship)

| Value | Setting |
|---|---|
| **Base URL** | `https://vvowvcdylztsqpzifdqc.supabase.co` |
| **Project ref** | `vvowvcdylztsqpzifdqc` |
| **anon key (`apikey`)** | `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2b3d2Y2R5bHp0c3FwemlmZHFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTc1NDcsImV4cCI6MjA5MDk5MzU0N30.jPBYr6f9fTABLHAD1rY_b1HP8xI0cDEQPJczxjCKsSY` |
| **Google Web client ID** | `504073436614-k185g5tlbg7asjhag6l97rdnf43nian8.apps.googleusercontent.com` |
| **Google iOS client ID** | `504073436614-9qec94thlrslcbvqfnot83ovrg2uoctu.apps.googleusercontent.com` |
| **watch-ingest URL** | `https://vvowvcdylztsqpzifdqc.supabase.co/functions/v1/watch-ingest` |

- The **anon key is PUBLIC** — it is designed to ship in client binaries. It is
  required on EVERY auth + function call as the `apikey` header. It is NOT a
  secret and does NOT grant data access on its own (Row-Level Security does).
- The **service_role key must NEVER appear in the watch app.** If anyone hands
  you one, refuse it — it bypasses all security.

> ⚠️ The anon key is included here so the watch team can integrate without
> waiting on us. It is safe to commit in the watch repo. Do **not** add any other
> key. If we ever rotate the anon key we'll send the new value.

---

## 1. The end-to-end picture

```
Phone app:  Sign UP  ─► Supabase Auth creates the user + UID
                         (a `profiles` row is auto-created by a DB trigger)
                                   │
Watch app:  Sign IN (Email or Google, SAME account)
              POST /auth/v1/token  ─► { access_token, refresh_token, user.id … }
                                   │  store securely (Keychain)
                                   ▼
            POST /functions/v1/watch-ingest   (Authorization: Bearer <access_token>)
              start ─► ping… ─► record… ─► end
                                   │
                         sessions land under the rider's UID
                         (server pins every write to the token's UID via RLS)
```

There is **no pairing with the phone**, no codes, no WatchConnectivity. The
watch is an independent Supabase client for the same account.

---

## 2. AUTH — Supabase GoTrue REST

Every request below includes **two required headers**:
```
apikey: <anon key>
Content-Type: application/json
```

### 2.1 Email + password sign-in
```
POST {base}/auth/v1/token?grant_type=password
{ "email": "rider@example.com", "password": "••••••••" }
```
**200 response (store all three of access_token, refresh_token, the UID):**
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
**Error responses to handle:**
| HTTP | body `error_code` / `msg` | Show the rider |
|---|---|---|
| 400 | `invalid_credentials` | "Wrong email or password." |
| 400 | `email_not_confirmed` | "Confirm your email from the SurfHub app first." |
| 429 | rate limited | "Too many attempts — wait a moment." |
| 400 | user doesn't exist | "No account found. Sign up in the SurfHub app." |

> The watch must NOT offer sign-up. New accounts are created only in the phone
> app (which also creates the required `profiles` row). A watch-only "sign up"
> would create an auth user with no profile and uploads would fail.

### 2.2 Google sign-in (ID-token flow)
Obtain a Google **ID token** on the watch using Google Sign-In configured with
the **iOS client ID** above (request scopes `openid email profile`), then:
```
POST {base}/auth/v1/token?grant_type=id_token
{ "provider": "google", "id_token": "<google id_token>" }
```
Same 200 response shape as 2.1. (Supabase's Google provider already trusts the
Web client ID above — no backend change needed.)

> watchOS note: native Google Sign-In on watchOS is limited. Options, in order of
> ease: **Email+password** (always works, no SDK) → **Sign in with Apple**
> (`grant_type=id_token`, `"provider":"apple"`, identical flow) → Google SDK.
> Ship email first; add the others when convenient.

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
recording; otherwise show login.

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
only ever write their own data. A `401` means the token is invalid/expired →
refresh (2.3) and retry once; if it still 401s, send the rider to login.

### 3.1 start — open a live session (rider hits the water)
```json
{ "type": "start", "lat": 36.0128, "lng": -5.6012, "startedAt": "2026-06-09T08:00:00Z" }
```
→ `200 { "sessId": 1234, "spot": "ProSurf Tarifa", "poiKind": "club" }`
Keep `sessId` for every later call. The server resolves the nearby spot/club
name from the GPS and notifies the rider's followers that they're live.
`startedAt` is ISO-8601; omit it and the server uses "now".

### 3.2 ping — position heartbeat (~every 10 s while riding)
```json
{ "type": "ping", "sessId": 1234, "lat": 36.0130, "lng": -5.6014, "jmax": 2.1, "jcnt": 3 }
```
→ `200 { "ok": true }`
`jmax` (session-best jump in metres so far) and `jcnt` (jumps so far) are
optional and only keep the live leaderboard ordering fresh. They do NOT trigger
record notifications — use `record` for that.

### 3.3 record — a NEW session-best metric (the moment it happens)
Send ONLY the metric(s) that just improved this session:
```json
{ "type": "record", "sessId": 1234, "jumpM": 4.8, "airS": 3.1 }
```
→ `200 { "broken": ["jump", "air"] }`
The server decides if it beats the rider's ALL-TIME personal best; if so it
pushes "new record!" to followers and returns which metrics were genuinely
broken. Fields (all optional): `jumpM` (m), `airS` (s), `speedKmh`, `distKm`.
Gate your calls on the session best so you don't call on every jump.

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
Saves the full session, flips it out of "live", runs a final PB check, and clears
the live ping. Required: `durMin, jmax, jcnt, airS, spdKmh, distKm, track, jData`.
Optional: `windKts, dir, avgKmh, stars` (stars defaults to 3).

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
- `WatchAuth.swift` — login + refresh + logout (§2)
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
- ✅ Row-Level Security pins writes to the JWT's UID — the watch can only write
  for the signed-in rider.
- ✅ On `401`: refresh once; if still failing, clear tokens → login screen.

---

## 8. What the rider sees (so you can verify your build)

After a real `end`:
- The rider's **profile** in the phone app shows the new session and updated
  Personal Records (with a "NEW" badge on any record broken in the last 24 h).
- **Followers** got a push when the session started ("X is riding · ProSurf
  Tarifa") and on each new personal record ("X just set a new highest jump —
  4.8 m!"), and saw the rider live on the Community feed while riding.
- The session feeds the global **rankings**.
