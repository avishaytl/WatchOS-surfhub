# Watch LIVE Session — End-to-End Spec

This document is the single source of truth for the **live riding session**
feature: a rider records on the watch, followers see them go live and get
record-break alerts in real time, and the full session syncs to the phone at the
end. It is written for the engineer (or AI) building the **native watch app on
the Mac**, because the watch app lives in a separate repo/toolchain.

Everything on the **server** (Supabase DB + Edge Functions) and the **phone app**
(`surfhub-app`, React Native) is **already implemented in this repo**. The watch
side only has to: pair, then call one HTTP endpoint at four lifecycle moments.

---

## 1. The flow in one picture

```
 ┌──────────────────── AUTH (login on the watch, see WATCH_AUTH.md) ───────┐
 │  Registration happens in the PHONE app (sign-up → user + UID).          │
 │                                                                         │
 │  Watch (SPOTEQ):        login screen (Email / Google, NO sign-up)       │
 │    WatchAuth.signInWithEmail / signInWithGoogle                         │
 │      └─POST {base}/auth/v1/token (GoTrue) ─► access+refresh+uid         │
 │      └─► WatchPairingStore.apply(session)  (Keychain, same UID as phone)│
 └────────────────────────────────────────────────────────────────────────┘

 ┌──────────────────────────── A RIDING SESSION ──────────────────────────┐
 │  rider taps START  ─► LiveSessionController.begin(lat,lng)              │
 │        └─POST watch-ingest {type:start} ─► sessions row (live=true)     │
 │                                            live_pings row               │
 │                                            └─► followers get "X is live"│
 │  riding…                                                                │
 │     every ~10s ─► {type:ping}    (position heartbeat)                   │
 │     new best   ─► {type:record}  (jump/air/speed/dist)                  │
 │                     └─► server checks all-time PB; if beaten:           │
 │                          record_events row ─► followers get "new record"│
 │  rider taps END   ─► finish(...)                                        │
 │        └─POST {type:end} ─► sessions UPDATE (full metrics+j_data+track) │
 │                              live=false (rankings refresh)              │
 │                              final PB promotion · live_pings deleted    │
 │                              └─► phone Profile shows session + new PBs  │
 └────────────────────────────────────────────────────────────────────────┘
```

---

## 2. What is ALREADY built (do not re-implement)

### Server — run `supabase_watch_live.sql` once in the SQL editor
- `sessions` — adds `started_at, dur_min, jmax, jcnt, air_s, spd_kmh, dist_km,
  avg_kmh, spot_lat, spot_lng, poi_id, poi_kind, track, j_data, source`.
  Canonical session time is **`created_at`** (there is no `ts` column).
- `live_pings` — one row per live rider (the live map/banner source).
- `personal_records` — server-authoritative all-time bests per rider.
- `record_events` — append-only log of record breaks (drives the push).
- `resolve_poi(lat,lng,max_km)` — nearest kite spot / club to a GPS fix.
- `record_break(sessId, jump, air, speed, dist, live)` — atomic PB check.
- Realtime publication + rankings refresh trigger + stale-ping cleanup.

### Edge Functions (`supabase/functions/`)
- **`watch-ingest`** — the ONE endpoint the watch calls. Verifies the rider JWT,
  pins all writes to that uid, resolves POIs, calls `record_break`. **Deploy it:**
  `supabase functions deploy watch-ingest` (leave `verify_jwt` on / default).
- **`send-push`** (extended) — already fans DM/group/social pushes. Now also
  handles two new webhook sources. **Create two Database Webhooks** (Dashboard ▸
  Database ▸ Webhooks), both pointing at `send-push`:
    - `live_pings`     INSERT → send-push   (→ "X is live" to followers)
    - `record_events`  INSERT → send-push   (→ "X set a new record" to followers)

### Phone app (`surfhub-app`)
- `watch.service.ts` — subscriptions (`subscribeToLiveRiders`,
  `subscribeToAllLivePings`). No token handoff — the watch logs in itself.
- `personalRecords.service.ts` — reads `personal_records`, flags fresh breaks.
- `WatchConnectScreen` (Settings ▸ Apple Watch) — informational: tells the rider
  to install the watch app and sign in with the same account.
- `LiveRidersBanner` — live followed-rider strip on the Community feed.
- `ProfileScreen` — Personal Records tiles now read the server PB and flash a
  "NEW" badge for a metric broken in the last 24 h.
- Notification taps with `kind: 'live' | 'record'` route to the Forecast tab.

---

## 3. What YOU build on the watch (Swift) — the deliverables in this repo

These Swift files are provided as a **starting implementation / contract**. Drop
them into the watch app target on the Mac and wire them to your login UI +
recording UI + sensors. **Authentication is login-only — see `WATCH_AUTH.md`.**

| File | Role |
|---|---|
| `watchos/.../WatchAuth.swift` | Email + Google login against Supabase GoTrue; stores the session. |
| `watchos/.../WatchPairingStore.swift` | Keychain session store + token refresh (the `WatchPairing` type = the logged-in session). |
| `watchos/.../WatchSessionUploader.swift` | HTTP client for the 4 `watch-ingest` calls. |
| `watchos/.../LiveSessionController.swift` | Orchestrates start/ping/record/end from the sensor loop. |

### Wiring checklist (Mac)
1. **Login UI (you build):** a SwiftUI login screen → `WatchAuth.signInWithEmail`
   / `signInWithGoogle`. NO sign-up on the watch (accounts are created on the
   phone). See `WATCH_AUTH.md` §5. Add `SUPABASE_URL` + `SUPABASE_ANON_KEY`
   (+ `GOOGLE_IOS_CLIENT_ID` if using Google) to the watch app's `Info.plist`.
2. **App launch:** if `await WatchPairingStore.shared.isPaired` → recording
   screen; else → login screen.
3. **Recording UI:** instantiate one `LiveSessionController`. Call:
   - `await live.begin(lat:lng:)` once you have the first GPS fix after START.
   - `live.onJump(heightM:airS:)` for each jump the engine confirms.
   - `live.onLocation(lat:lng:speedKmh:cumulativeDistKm:)` from the GPS tick.
   - `await live.finish(durMin:windKts:dir:avgKmh:jumps:track:stars:)` on END.
4. Server is already live (the SQL was run, `watch-ingest` + `send-push` are
   deployed, and the `live_pings` / `record_events` webhooks exist). The watch
   only needs to authenticate and POST to `watch-ingest`.

---

## 4. The `watch-ingest` HTTP contract (authoritative)

```
POST {ingestUrl}            ingestUrl = {SUPABASE_URL}/functions/v1/watch-ingest
Authorization: Bearer {riderAccessToken}
Content-Type: application/json
```

Body is one of (camelCase in, snake_case stored by the server):

### start
```json
{ "type": "start", "lat": 36.0128, "lng": -5.6012, "startedAt": "2026-06-09T08:00:00Z" }
```
→ `200 { "sessId": 1234, "spot": "Tarifa", "poiKind": "kitespot" }`
Side effects: creates the `sessions` row (live=true) and the `live_pings` row →
followers receive **"{name} is riding · {spot}"**.

### ping  (every ~10 s)
```json
{ "type": "ping", "sessId": 1234, "lat": 36.0130, "lng": -5.6014, "jmax": 2.1, "jcnt": 3 }
```
→ `200 { "ok": true }`  · updates position + keeps the live banner ordering.
`jmax`/`jcnt` are optional and do **not** trigger a record check.

### record  (only when a session best improves)
```json
{ "type": "record", "sessId": 1234, "jumpM": 4.8, "airS": 3.1 }
```
→ `200 { "broken": ["jump"] }`  · `broken` ⊆ `jump|air|speed|dist`.
Pass only the metric(s) that improved. The server compares to the rider's
all-time PB; a genuine break writes `record_events` → followers receive
**"{name} just set a new highest jump — 4.8 m!"**.

### end
```json
{
  "type": "end", "sessId": 1234,
  "durMin": 72, "windKts": 18, "dir": "W",
  "jmax": 4.8, "jcnt": 9, "airS": 3.1, "spdKmh": 41, "distKm": 12.5, "avgKmh": 24.3,
  "stars": 4,
  "track": [[360128,-56012],[360130,-56014]],
  "jData": [{ "t":120,"h":480,"a":31,"s":41,"d":21,"y":360128,"x":-56012 }]
}
```
→ `200 { "ok": true, "broken": [...] }`  · finalizes the session (live=false,
rankings refresh), promotes any end-of-session PBs, deletes the live ping.

### Auth failures
A `401` means the watch's token is dead (rider signed out, or the refresh
failed). `WatchPairingStore` clears the session and the watch UI should return
to its own login screen (see `WATCH_AUTH.md`).

---

## 5. Compact data formats (must match exactly)

These mirror the watch core types and `surfhub-app/src/data/types.ts`.
`Models.swift` already defines `JumpEvent`; `TrackPoint` is `[Int]` = `[lat*1e4, lng*1e4]`.

```
JumpEvent { t, h, a, s, d, y, x }
  t = seconds offset from session start (int)
  h = height cm            (480 = 4.80 m)
  a = air time tenths-sec  (31  = 3.1 s)
  s = top speed km/h       (int)
  d = jump distance dm     (21  = 2.1 m)
  y = lat * 1e4   x = lng * 1e4   (int)

TrackPoint = [lat*1e4, lng*1e4]   one point every ~5 s
```

Units the watch works in vs. what `end` expects:
- `jmax` → metres (e.g. 4.8). `airS` → seconds (3.1). `spdKmh` → km/h int.
- `distKm` → km. `durMin` → whole minutes.
- The `jData[]` per-jump values use the **compact** encoding above (cm / tenths /
  dm / ×1e4), NOT the metre/second scalars — exactly like the existing
  `core/sessionAnalysis.ts` → `toJumpEvent` output.

---

## 6. Record-break logic — why the server decides

The watch only knows the **current session**. A rider's all-time PB may come from
an earlier watch session or a session logged on the phone. So:

- The watch gates `record` calls on the **session** best (don't spam every jump).
- The server (`record_break`, under a row lock) compares to `personal_records`
  and emits `record_events` only on a true **all-time** PB. This makes follower
  "new record" pushes exactly-once and lets the phone show a reliable badge.

So a rider can beat their session best many times; followers are only pinged when
they beat their lifetime best.

---

## 7. Security notes

- The watch logs in itself and stores its session (access + refresh tokens) only
  in the watch **Keychain**; tokens are sent only to Supabase over TLS and never
  logged. The public **anon key** may ship in the binary; the **service_role**
  key never appears on the watch. Full detail in `WATCH_AUTH.md` §7.
- The watch authenticates to `watch-ingest` with the rider JWT; the server pins
  every write to `auth.uid()` from that token — the watch cannot write for anyone
  else even if the body claimed a different uid (it can't; uid isn't in the body).
- The dev-only **calib-log** path (CALIB_TOKEN) is unrelated to this and stays
  separate. Never mix the two: production sessions use the JWT path only.

---

## 8. Test plan (Mac)

1. **Account:** register in the PHONE app (sign-up). Confirm email if required.
2. **Login:** on the watch, sign in with that Email/Google account. Confirm
   `await WatchPairingStore.shared.isPaired == true` and the UID matches the phone.
3. **Start:** begin a session on the watch. Verify a `sessions` row (live=true)
   and a `live_pings` row appear; a follower account receives the "is riding" push
   and sees the rider in `LiveRidersBanner` on the Community feed.
4. **Record:** simulate a jump bigger than the rider's PB. Verify a `record_events`
   row is created and a follower gets the "new record" push.
5. **End:** finish. Verify the `sessions` row has full `j_data`/`track`,
   `live=false`, the `live_pings` row is gone, and the rider's profile shows the
   session plus a "NEW" badge on any beaten Personal Records tile.
6. **Sign out** on the watch → confirm the session is cleared and the login
   screen returns; a stale token then 401s on `watch-ingest`.
```
