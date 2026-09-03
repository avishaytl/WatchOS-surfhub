# SPOTEQ iOS + watchOS App — App Store Deployment Guide

## Branding and distribution identifiers

The project, targets, schemes, products, source entry points, and public app
name are **SPOTEQ**. The standalone project now uses brand-based identifiers:

- `com.spoteq.watch` — iOS companion bundle identifier
- `com.spoteq.watch.watchapp` — embedded watchOS bundle identifier
- `application/x-spoteq-session-log` — SPOTEQ session-log MIME type

This migration creates a new Apple distribution identity. The previous App Store
Connect record cannot accept an archive built with the new identifiers.

## Pre-Submission Checklist

### ✅ Already Done (in this project)
- [x] Privacy usage descriptions in `Info.plist` (Location, Motion, HealthKit)
- [x] Background modes configured (workout-processing, location)
- [x] HealthKit entitlements enabled
- [x] English + Hebrew localization
- [x] Automatic code signing wired to the local `SPOTEQ_TEAM_ID` setting
- [x] Privacy Manifest (`PrivacyInfo.xcprivacy`) created
- [x] `ITSAppUsesNonExemptEncryption = NO` added (no custom encryption)
- [x] Version source aligned through `Config.xcconfig` (`1.3` / Build `168`)
- [x] Launchable SPOTEQ iOS companion embeds the independent SPOTEQ watchOS app
- [x] Deprecated API usage fixed (`onChange`)
- [x] Localized `SessionDetailView` strings
- [x] Implemented `deleteAllSessions()` properly
- [x] Added `NSLocationAlwaysAndWhenInUseUsageDescription`
- [x] Created structured logging utility (`Logger.swift`)

---

## Steps to Deploy

### 1. Apple Developer Account Setup
- [ ] Ensure your **Apple Developer Program** membership ($99/year) is active at [developer.apple.com](https://developer.apple.com)
- [ ] Copy `Config.local.xcconfig.example` to `Config.local.xcconfig` and set
  `SPOTEQ_TEAM_ID` to the SPOTEQ organization's Apple Developer Team ID
- [ ] Create SPOTEQ-owned Google OAuth credentials and set
  `SPOTEQ_GOOGLE_CLIENT_ID` plus its matching
  `SPOTEQ_GOOGLE_CALLBACK_SCHEME` in the same local config file
- [ ] Register explicit App IDs for `com.spoteq.watch` and
  `com.spoteq.watch.watchapp`
- [ ] Enable HealthKit, background delivery, and the shallow-depth/pressure
  capability on the watch App ID; keep automatic signing enabled so Xcode can
  create matching provisioning profiles

### 2. App Store Connect — Create the New Standalone Record
1. Create a new iOS app record and select the explicit App ID
   `com.spoteq.watch`.
2. Assign a new unique SKU and record the generated numeric Apple ID in the
   release documentation.
3. Do not create a separate App Store Connect record for the embedded watch app
   and do not use **Add Platform**.
4. Under **General → App Information**, set the localized app name to **SPOTEQ**.
5. Under **TestFlight → iOS**, select the build uploaded from this project.

The uploaded iOS bundle contains the companion app and embeds the independent
watchOS bundle `com.spoteq.watch.watchapp`; Apple associates both with
the same App Store Connect record.

### 3. App Icon
Both the iOS companion and the embedded watchOS app contain a referenced
1024×1024 `AppIcon.png` without alpha. Validate the asset catalogs again before
each release; no icon generation step is currently required.

### 4. App Store Metadata (in App Store Connect)
Prepare the following:

| Field | Notes |
|-------|-------|
| **App Name** | SPOTEQ |
| **Subtitle** | Kitesurfing Jump Tracker |
| **Description** | Full app description (see below) |
| **Keywords** | kitesurfing,kitesurf,jump,tracker,airtime,watch,sport |
| **Category** | Sports |
| **Privacy Policy URL** | **REQUIRED** — host a privacy policy page |
| **Support URL** | Your support website/email |
| **Screenshots** | Apple Watch screenshots (see below) |

#### Suggested App Description:
```
Track your kitesurfing sessions with precision. SPOTEQ uses Apple Watch sensors to automatically detect jumps, measure airtime, and calculate jump height in real-time.

Features:
• Real-time jump detection with height and airtime measurement
• GPS speed and distance tracking
• Heart rate monitoring via HealthKit
• Session history with detailed statistics
• Adjustable jump detection sensitivity (Conservative/Standard/Aggressive)
• Works completely offline — no phone needed
• English and Hebrew language support
• Customizable themes

Built for riders who want accurate data on every jump.
```

### 5. Screenshots
The companion release requires both iPhone and Apple Watch screenshots. Capture:
- iPhone screenshots showing the SPOTEQ companion screen
- **38mm, 40mm, 41mm, 44mm, 45mm** (at minimum: one small + one large)
- Recommended scenes:
  1. Home screen (Start Session button)
  2. Active session (metrics view)
  3. Jump stats view
  4. Session detail view
  5. Settings view

Use Xcode Simulator or take them from a real Apple Watch.

### 6. Privacy Policy
**Apple requires a Privacy Policy URL**. Your policy should cover:
- Location data is collected only during active sessions
- Health data (heart rate) is read via HealthKit and stays on device
- Motion data is processed on-device for jump detection
- Session data is stored locally on the watch
- No data is shared with third parties
- No analytics or tracking
- User can delete all data from Settings

Host this as a simple webpage (GitHub Pages, Notion public page, etc.)

### 7. Build & Archive for Submission

In **Xcode**:
1. Select the **SPOTEQ** scheme (not "SPOTEQ Watch App")
2. Set destination to **Any iOS Device (arm64)**. The iOS companion embeds the
   independent watchOS app; archiving the watch target alone does not create an
   uploadable App Store archive.
3. Menu → **Product** → **Archive**
4. In the Organizer, click **Distribute App**
5. Choose **App Store Connect** → **Upload**
6. Follow the prompts (Xcode will validate automatically)

Equivalent command-line flow from the repository root:

```bash
mkdir -p .release
xcodebuild \
  -project SPOTEQ/SPOTEQ.xcodeproj \
  -scheme SPOTEQ \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$PWD/.release/SPOTEQ-1.3-168.xcarchive" \
  -allowProvisioningUpdates \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$PWD/.release/SPOTEQ-1.3-168.xcarchive" \
  -exportPath "$PWD/.release/TestFlight-168" \
  -exportOptionsPlist "$PWD/SPOTEQ/ExportOptions-TestFlight.plist" \
  -allowProvisioningUpdates
```

`ExportOptions-TestFlight.plist` uses `destination=upload`, so the export step
uploads the archive directly to App Store Connect.

### 8. Review Readiness Checklist

| # | Item | Status |
|---|------|--------|
| 1 | App Icon (1024×1024) | ✅ Present for both targets |
| 2 | Privacy Manifest | ✅ Created |
| 3 | Info.plist usage descriptions | ✅ Complete |
| 4 | HealthKit entitlements | ✅ Configured |
| 5 | Background modes | ✅ Configured |
| 6 | Privacy Policy URL | ⚠️ **YOU NEED TO CREATE & HOST** |
| 7 | App Store screenshots | ⚠️ **YOU NEED TO CAPTURE** |
| 8 | App description & metadata | ⚠️ **YOU NEED TO FILL IN ASC** |
| 9 | Code signing | ✅ Automatic |
| 10 | Export compliance (`ITSAppUsesNonExemptEncryption`) | ✅ Set to NO |
| 11 | Version/Build numbers | ✅ Sourced from `Config.xcconfig` (1.3 / 168) |
| 12 | Localization | ✅ English + Hebrew |
| 13 | Deprecated APIs | ✅ Fixed |
| 14 | Debug print statements | ⚠️ Consider replacing with `AppLogger` |
| 15 | Test on physical iPhone + Apple Watch | ⚠️ **CRITICAL before submission** |

### 9. Common Rejection Reasons to Avoid
1. **Missing privacy policy** — must be a live URL
2. **Missing app icon** — must include the 1024×1024 icon
3. **HealthKit not justified** — ensure your review notes explain why you read heart rate
4. **Background location not justified** — explain workout tracking in review notes
5. **Crash on launch** — test on real hardware, not just simulator
6. **Placeholder/TODO content** — make sure all UI text is finalized

### 10. App Review Notes
When submitting, add review notes like:
```
SPOTEQ includes a launchable iPhone companion and an independent Apple Watch app.
The watch app tracks kitesurfing sessions and requires:

- Location: To track GPS speed, distance, and route during sessions
- HealthKit: To display real-time heart rate and save workouts
- Motion: To detect jumps using accelerometer/gyroscope data
- Background Location: To continue tracking when the watch screen is off during a session

To test: Tap "Start Session" → Select "Kitesurfing" → The session view will show live metrics. On a real watch with movement, jumps will be detected automatically.
```

---

## Post-Submission

- Apple review typically takes **24–48 hours**
- If rejected, address the specific issues and resubmit
- For subsequent updates, increment `CURRENT_PROJECT_VERSION` (Build number) in project settings
- `MARKETING_VERSION` is currently `1.3`; change it only for a marketing release

## Version Numbering Strategy
- **Marketing Version** (`CFBundleShortVersionString`): `1.0`, `1.1`, `2.0` etc.
- **Build Number** (`CFBundleVersion`): Increment for every upload: `1`, `2`, `3`...
- Each upload to App Store Connect must have a unique build number


SKU: 2D7LFZS835
