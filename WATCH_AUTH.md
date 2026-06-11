# Watch Authentication — LOGIN-ONLY spec (for the Mac team)

The SurfHub watch app authenticates **on its own**: it has a **login screen**
(Email + Google), exactly like the phone app, but **no sign-up**. Accounts are
created only in the phone app. Once a rider has an account, they sign in on the
watch with the same credentials and the watch gets its **own** Supabase session
for the **same UID** — then it can upload sessions per `WATCH_LIVE_SESSION.md`.

```
 Phone app:  Sign UP  ──► Supabase Auth creates user + UID  (+ profiles row)
                                   │
 Watch app:  Sign IN (Email / Google, SAME account) ──► its own JWT, same UID
                                   │
                          stored in watch Keychain
                                   │
              watch-ingest calls  Authorization: Bearer <watch JWT>
                                   │
              sessions land under the rider's UID (RLS-pinned by the server)
```

No pairing, no codes, no WatchConnectivity. The watch is simply a third Supabase
client (alongside phone + admin).

---

## 1. Why login (not pairing)

- The watch app is a **separate project** (different App ID / developer), so a
  phone↔watch token handoff (WatchConnectivity) isn't available.
- Letting the watch authenticate directly is simpler and more robust: it owns
  its session, refreshes it itself, and keeps working even if the phone is gone.
- Same UID guarantees sessions, rankings, records and the live banner all line
  up with the rider's account.

**Login only — never expose sign-up on the watch.** If a sign-in fails with
"user not found", tell the rider to register in the phone app first.

---

## 2. The provided Swift files

| File | Role |
|---|---|
| `watchos/.../WatchAuth.swift` | Email + Google login against Supabase GoTrue; stores the session. |
| `watchos/.../WatchPairingStore.swift` | Keychain-backed session store + token refresh (reused as-is; the type is named `WatchPairing` but represents the logged-in session). |
| `watchos/.../WatchSessionUploader.swift` | watch-ingest client — unchanged; reads the session from the store. |
| `watchos/.../LiveSessionController.swift` | Live session orchestration — unchanged. |

You build only the **login UI** (a SwiftUI view) and wire it to `WatchAuth`.

---

## 3. Supabase Auth (GoTrue) REST — exactly what to call

Base URL = `SUPABASE_URL` (e.g. `https://vvowvcdylztsqpzifdqc.supabase.co`).
Every request sends the public **anon key** as `apikey` (safe to ship in the
binary — it is not a secret).

### 3.1 Email + password
```
POST {base}/auth/v1/token?grant_type=password
apikey: {anonKey}
Content-Type: application/json
{ "email": "rider@example.com", "password": "••••••••" }
```
→ `200`:
```json
{
  "access_token": "eyJ...",
  "refresh_token": "v1.M...",
  "expires_at": 1775500000,
  "token_type": "bearer",
  "user": { "id": "550e8400-e29b-41d4-a716-446655440000", "email": "..." }
}
```
`400/401` → wrong credentials (or unconfirmed email). `WatchAuth` maps this to
`WatchAuthError.invalidCredentials`.

> Email confirmation: if your project requires confirmed emails, a brand-new
> account that hasn't confirmed will fail here. That's fine — the rider confirms
> from the phone-app signup email, then signs in on the watch.

### 3.2 Google (ID-token flow — same as the phone)
The phone uses `supabase.auth.signInWithIdToken({ provider:'google', token })`.
The watch does the identical exchange:
```
POST {base}/auth/v1/token?grant_type=id_token
apikey: {anonKey}
Content-Type: application/json
{ "provider": "google", "id_token": "<Google ID token>" }
```
→ same response shape as 3.1.

To obtain the Google **ID token** on watchOS, use Google Sign-In for iOS/watchOS
with the project's **iOS client ID** (`GOOGLE_IOS_CLIENT_ID`, below). The phone
app already uses these client IDs:
- Web client ID:  `504073436614-k185g5tlbg7asjhag6l97rdnf43nian8.apps.googleusercontent.com`
- iOS client ID:  `504073436614-9qec94thlrslcbvqfnot83ovrg2uoctu.apps.googleusercontent.com`

In Supabase Dashboard ▸ Authentication ▸ Providers ▸ Google, the **Web client
ID** must be in the "Authorized Client IDs" list (it already is for the phone).
The watch can reuse the same Google provider config — no server change needed.

> watchOS Google Sign-In note: native Google Sign-In on watchOS is limited. Two
> viable options:
>   (a) Google Sign-In SDK directly on the watch (watchOS 9+), or
>   (b) an Apple "Sign in with Apple" button (GoTrue `grant_type=id_token`,
>       `provider:"apple"`) — often the smoothest on watchOS.
> Email+password always works and needs no SDK. Ship email first; add Google/
> Apple when convenient. `WatchAuth.signInWithGoogle(idToken:)` is ready; add a
> `signInWithApple(idToken:)` the same way (`provider:"apple"`) if you go that route.

### 3.3 Token refresh (handled for you)
`WatchPairingStore.validPairing()` auto-refreshes when the access token is within
2 minutes of expiry:
```
POST {base}/auth/v1/token?grant_type=refresh_token
apikey: {anonKey}
{ "refresh_token": "<refresh_token>" }
```
Stores the rotated pair. If refresh fails (revoked / signed out), it clears the
session → show the login screen again.

### 3.4 Sign out
`WatchAuth.signOut()` calls `POST {base}/auth/v1/logout` (Bearer access token)
then clears the Keychain.

---

## 4. Config — Info.plist keys (inject per build, never commit secrets)

```
SUPABASE_URL          https://vvowvcdylztsqpzifdqc.supabase.co
SUPABASE_ANON_KEY     <public anon key>            ← safe in the binary
GOOGLE_IOS_CLIENT_ID  504073436614-9qec…apps.googleusercontent.com   (if Google)
```
`WatchAuthConfig.fromBundle()` reads `SUPABASE_URL` + `SUPABASE_ANON_KEY`.
The anon key is public by design (RLS protects data); the **service_role** key
must NEVER appear in the watch app.

---

## 5. Login UI (what you build) — minimal contract

A SwiftUI login view that:
1. Has Email + Password fields and a "Sign in" button →
   `try await WatchAuth.signInWithEmail(email, password)`.
2. (Optional) a "Continue with Google/Apple" button →
   `try await WatchAuth.signInWithGoogle(idToken:)`.
3. On success: navigate to the main recording screen (the session is stored).
4. On `WatchAuthError.invalidCredentials`: show "Wrong email or password".
5. Shows a small line: "No account? Sign up in the SurfHub phone app." — do NOT
   implement sign-up on the watch.

App launch: if `await WatchPairingStore.shared.isPaired` is true, skip login and
go straight to recording (the stored session refreshes itself on first use).

```swift
// Example call sites
let uid = try await WatchAuth.signInWithEmail(email, password)   // → recording screen
// ...
if await WatchPairingStore.shared.isPaired { showRecording() } else { showLogin() }
// sign out:
await WatchAuth.signOut(); showLogin()
```

---

## 6. After login — what the watch uploads (recap)

Once authenticated the watch calls `watch-ingest` exactly as specified in
`WATCH_LIVE_SESSION.md` (start / ping / record / end). The server pins every
write to the JWT's UID, so the rider's own RLS applies. Summary of the data
contract (full detail in `WATCH_LIVE_SESSION.md` §4–5):

```
POST {SUPABASE_URL}/functions/v1/watch-ingest   Authorization: Bearer <watch JWT>

start  { type:'start', lat, lng, startedAt }                 → { sessId }
ping   { type:'ping', sessId, lat, lng, jmax?, jcnt? }       → { ok:true }   (~10s)
record { type:'record', sessId, jumpM?, airS?, speedKmh?, distKm? } → { broken:[...] }
end    { type:'end', sessId, durMin, windKts?, dir?, jmax, jcnt,
         airS, spdKmh, distKm, avgKmh?, stars?, track, jData } → { ok:true, broken:[...] }

JumpEvent (jData[]):  { t:sec, h:cm, a:tenths-s, s:km/h, d:dm, y:lat*1e4, x:lng*1e4 }
TrackPoint (track[]): [lat*1e4, lng*1e4]
```

---

## 7. Security checklist

- ✅ Anon key in the binary — fine (public). **service_role key — never.**
- ✅ Tokens live only in the watch Keychain; sent only to Supabase over TLS.
- ✅ Login only; sign-up is phone-only. Same UID across phone + watch.
- ✅ RLS on `sessions` / `live_pings` / `personal_records` pins writes to
  `auth.uid()` — the watch can only write for the signed-in rider.
- ✅ Never log tokens. Never send them anywhere except Supabase.

---

## 8. Test plan

1. Register a new account in the **phone app**; confirm email if required.
2. On the watch, open the SurfHub app → **sign in** with that email/password.
   Verify `WatchPairingStore.shared.isPaired == true` and the UID matches.
3. Record a session → confirm rows appear in `sessions` / `live_pings` under the
   right UID, followers get the live + record pushes, and the session shows on
   the rider's phone profile (see `WATCH_LIVE_SESSION.md` §8).
4. Sign out on the watch → next launch shows the login screen again.
5. Let the access token age past ~1 h mid-use → confirm it refreshes silently
   (no re-login needed) and uploads keep working.
```
