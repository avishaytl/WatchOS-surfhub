# SPOTEQ — Agent Deployment Guide

**Read this before changing anything that ships.** SPOTEQ is one product built
from **two separate git repositories**. A release is only complete when both
sides are consistent and both TestFlight builds are up.

> **The public name is always `SPOTEQ`** — app name, display name, scheme,
> target, product, screenshots, and store metadata. Historical identifiers may
> remain only where compatibility or immutable research evidence requires them;
> they must never be shown to users.

---

## 1. The two repositories

| | Watch lab repo | Product repo |
|---|---|---|
| **Path** | `~/Documents/Projects/WatchOS-surfhub` | `~/Documents/Projects/SurfHub` |
| **Remote** | Move to the SPOTEQ GitHub organization | Move to the SPOTEQ GitHub organization |
| **Contains** | Native Xcode project `SPOTEQ/SPOTEQ.xcodeproj` (watchOS app + thin iOS companion), jump engines, replay tooling, logs, algorithm docs | Expo/React Native app `surfhub-app` (iOS + Android) with the watchOS app embedded as an Apple target |
| **Role** | Where watch/engine development and offline replay happen | Where the shipping consumer app is built and submitted |

They are **not** linked by symlinks or submodules. The watch Swift sources exist
as **two physical copies** that must be synced by hand — see §3.

---

## 2. App Store identities — do not mix them up

Two distinct distribution identities are configured. The September 2026 bundle-ID
migration intentionally requires new App Store Connect records; the former records
cannot accept builds signed with these identifiers. Both new records must be ready
before the next release.

### A. SPOTEQ (phone app + embedded watch) — the main product
- Repo: `SurfHub/surfhub-app`
- iOS bundle: `com.spoteq.app`
- Watch bundle: `com.spoteq.app.watchkitapp`
- ASC App ID: **create the new record, then add its numeric ID to `eas.json`**
- Android package: `com.spoteq.app`
- Apple Team: configure `SPOTEQ_TEAM_ID` locally; no personal Team ID is committed
- Build system: **EAS Build** (Continuous Native Generation — `/ios` and
  `/android` are `.easignore`d and regenerated on every build)

### B. SPOTEQ (native Xcode watch project) — legacy standalone record
- Repo: `WatchOS-surfhub/SPOTEQ`
- iOS bundle: `com.spoteq.watch`
- Watch bundle: `com.spoteq.watch.watchapp`
- Wear OS package: `com.spoteq.wear`
- ASC App ID / SKU: **create a new standalone record before upload**
- Build system: **`xcodebuild` archive + export**

<a name="permanent-identifiers"></a>
### Permanent identifiers after the migration
- `com.spoteq.watch` / `com.spoteq.watch.watchapp`
- `com.spoteq.app` / `com.spoteq.app.watchkitapp`
- Expo `slug: "spoteq"` and `scheme: "spoteq"` in `app.json`
- `application/x-spoteq-session-log` — MIME type used for SPOTEQ session logs.

---

## 3. Watch source sync — the one thing that silently breaks releases

The shipping watch app is the copy inside the Expo project, **not** the one in
the Xcode project:

```
WatchOS-surfhub/SPOTEQ/SPOTEQ Watch App/     ← development / replay lab
SurfHub/surfhub-app/targets/watch/           ← what actually ships to users
```

There is **no automated sync**. If you change a Swift file in the watch lab and
do not mirror it, the change never reaches users.

**Deliberate differences — preserve these when syncing:**

| File / dir | Watch lab repo | `targets/watch` |
|---|---|---|
| `expo-target.config.js` | absent | **required** — declares target name `SPOTEQWatchApp`, display name `SPOTEQ`, bundle suffix `.watchkitapp`, frameworks, entitlements |
| `EngineV16/` | absent — referenced by the Xcode project from `../engines/engine_v16/` | physical copy of `engines/engine_v16/{JumpEngineV16,JumpDetectorV16,V16SettingsView}.swift` |
| `SPOTEQ_Watch_App.entitlements` | present | absent — entitlements come from `expo-target.config.js` |
| `Info.plist` → `WKCompanionAppBundleIdentifier` | `com.spoteq.watch` | `com.spoteq.app` |
| `Info.plist` → cloud/auth/OAuth settings | present (fed by `Config.xcconfig` + ignored `Config.local.xcconfig`) | absent |
| `Assets.xcassets/AppIcon.appiconset` | `AppIcon.png` | `App-Icon-1024x1024@1x.png` (Expo-generated) |
| `KitesurfJumpEngine_old.swift` | present (dead code) | absent — do not copy |

**Sync command** (lab → shipping; run from the watch repo root):

```bash
rsync -av --delete \
  --exclude='.DS_Store' \
  --exclude='SPOTEQ_Watch_App.entitlements' \
  --exclude='KitesurfJumpEngine_old.swift' \
  --exclude='Info.plist' \
  --exclude='Assets.xcassets/' \
  --exclude='expo-target.config.js' \
  --exclude='EngineV16/' \
  "SPOTEQ/SPOTEQ Watch App/" \
  ~/Documents/Projects/SurfHub/surfhub-app/targets/watch/

# Engine V16 lives outside the watch target in the lab repo — copy it separately.
cp engines/engine_v16/{JumpEngineV16,JumpDetectorV16,V16SettingsView}.swift \
  ~/Documents/Projects/SurfHub/surfhub-app/targets/watch/EngineV16/
```

Then verify and hand-merge the excluded files if they changed:

```bash
diff -rq "SPOTEQ/SPOTEQ Watch App" ~/Documents/Projects/SurfHub/surfhub-app/targets/watch
```

The output should list **only** the deliberate differences in the table above.

---

## 4. Release procedure

Deploy **both** apps. Do not ship one without the other when watch code changed.

### Step 0 — Sync and verify
1. Run the §3 sync, then the `diff -rq` check.
2. Confirm no user-facing string says anything other than SPOTEQ.
3. `cd SurfHub/surfhub-app && npm test`

### Step 1 — SPOTEQ product app (`SurfHub/surfhub-app`) → TestFlight

Versioning: `app.json` → `expo.version` (marketing) and `expo.ios.buildNumber`.
`eas.json` sets `appVersionSource: "local"` with `autoIncrement: true`, so the
build number increments automatically; bump `expo.version` by hand for a
marketing release. `scripts/release.js` can bump the patch version and write
`CHANGELOG.md`, but it is **not currently wired to any npm/EAS hook** — run it
manually (`node scripts/release.js`) if you want the changelog entry.

```bash
cd ~/Documents/Projects/SurfHub/surfhub-app

# iOS → TestFlight
eas build --platform ios --profile testflight
eas submit --platform ios --profile testflight     # requires the new SPOTEQ App Store record

# Android (same release train) — produces an AAB, uploaded to Play manually
eas build --platform android --profile production
```

`eas-build-post-install` runs `scripts/verify-watch-embedding.js`, which fails
the build unless the phone target embeds and depends on `SPOTEQWatchApp` with an
`Embed Watch Content` phase pointing at `$(CONTENTS_FOLDER_PATH)/Watch`. **If
that script throws, the watch app would have shipped missing — fix it, never
bypass it.**

`SENTRY_AUTH_TOKEN` must come from an EAS sensitive env var; never commit it or
let `.env*` into the archive (already handled by `.easignore`).

### Step 2 — SPOTEQ native watch project (`WatchOS-surfhub`) → TestFlight

Version source of truth is `SPOTEQ/Config.xcconfig` — edit nothing else.

```bash
cd ~/Documents/Projects/WatchOS-surfhub/SPOTEQ
./bump-version.sh --bump-build          # or: ./bump-version.sh 1.4 170
```

Before archiving, copy `Config.local.xcconfig.example` to
`Config.local.xcconfig` and set `SPOTEQ_TEAM_ID`,
`SPOTEQ_GOOGLE_CLIENT_ID`, `SPOTEQ_GOOGLE_CALLBACK_SCHEME`, and
`SPOTEQ_SUPABASE_ANON_KEY`. The local file is ignored; committed configuration
contains no personal signing or OAuth identity.

```bash
cd ~/Documents/Projects/WatchOS-surfhub
V=$(grep '^MARKETING_VERSION' SPOTEQ/Config.xcconfig | sed 's/.*= *//')
B=$(grep '^CURRENT_PROJECT_VERSION' SPOTEQ/Config.xcconfig | sed 's/.*= *//')
mkdir -p .release

xcodebuild -project SPOTEQ/SPOTEQ.xcodeproj -scheme SPOTEQ \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$PWD/.release/SPOTEQ-$V-$B.xcarchive" \
  -allowProvisioningUpdates archive

xcodebuild -exportArchive \
  -archivePath "$PWD/.release/SPOTEQ-$V-$B.xcarchive" \
  -exportPath "$PWD/.release/TestFlight-$B" \
  -exportOptionsPlist "$PWD/SPOTEQ/ExportOptions-TestFlight.plist" \
  -allowProvisioningUpdates
```

Archive the **`SPOTEQ` iOS scheme**, not `SPOTEQ Watch App` — the iOS companion
embeds the independent watch app, and archiving the watch target alone produces
nothing uploadable. `ExportOptions-TestFlight.plist` uses `destination=upload`,
so the export step uploads to App Store Connect directly.

### Step 3 — After both uploads
- App Store Connect → each record → TestFlight → confirm the build finished
  processing and export compliance is clear (`ITSAppUsesNonExemptEncryption` is
  already `false` in both projects).
- Both records must display the app name **SPOTEQ**.
- Tag and push both repos so the two histories stay correlated.

Full store-submission detail (metadata, screenshots, review notes, rejection
reasons) lives in [SPOTEQ/APP_STORE_DEPLOYMENT.md](SPOTEQ/APP_STORE_DEPLOYMENT.md).
Play Store specifics are in `SurfHub/surfhub-app/PLAY_STORE_RELEASE.md`.
The one-time external setup required by the new identities is tracked in
`SurfHub/surfhub-app/BUNDLE_ID_MIGRATION.md`.

---

## 5. Rules for agents

1. **Keep the post-migration bundle identifiers above synchronized.** Any future
   bundle-ID change creates another distribution identity. Keep the Expo slug
   and scheme aligned on `spoteq`.
2. **Never edit `targets/watch/` as the primary copy.** Change the watch lab
   first, then sync — otherwise the next sync silently reverts your work.
3. **Never bump versions in `project.pbxproj` or Xcode UI.** Watch project
   versions come from `Config.xcconfig` via `bump-version.sh`; app versions come
   from `app.json`.
4. **Never commit real account configuration.** Signing, OAuth, and the anon key
   belong in ignored `Config.local.xcconfig`; EAS secrets stay in EAS.
5. **A watch-code change is not released until the Expo build ships it.** The
   `WatchOS-surfhub` TestFlight build alone does not update the product app's
   users.
6. Both repos are on `main` with different remotes — verify you are pushing to
   the right one.
