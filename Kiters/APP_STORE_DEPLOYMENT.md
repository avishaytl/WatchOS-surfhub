# Kiters watchOS App — App Store Deployment Guide

## Pre-Submission Checklist

### ✅ Already Done (in this project)
- [x] Privacy usage descriptions in `Info.plist` (Location, Motion, HealthKit)
- [x] Background modes configured (workout-processing, location)
- [x] HealthKit entitlements enabled
- [x] English + Hebrew localization
- [x] Automatic code signing with Development Team
- [x] Privacy Manifest (`PrivacyInfo.xcprivacy`) created
- [x] `ITSAppUsesNonExemptEncryption = NO` added (no custom encryption)
- [x] Version string aligned (`1.0` / Build `1`)
- [x] Deprecated API usage fixed (`onChange`)
- [x] Localized `SessionDetailView` strings
- [x] Implemented `deleteAllSessions()` properly
- [x] Added `NSLocationAlwaysAndWhenInUseUsageDescription`
- [x] Created structured logging utility (`Logger.swift`)

---

## Steps to Deploy

### 1. Apple Developer Account Setup
- [ ] Ensure your **Apple Developer Program** membership ($99/year) is active at [developer.apple.com](https://developer.apple.com)
- [ ] Your Team ID `2D7LFZS836` is already configured in the project

### 2. App Store Connect — Create App Record
1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Click **My Apps** → **+** → **New App**
3. Fill in:
   - **Platform**: watchOS
   - **Name**: Kiters
   - **Primary Language**: English (U.S.)
   - **Bundle ID**: `com.Kiters.watchkitapp` (must match project)
   - **SKU**: `kiters-watchos-v1` (any unique string)
4. Click **Create**

### 3. App Icon (REQUIRED — currently missing!)
Your `AppIcon.appiconset/Contents.json` declares a 1024×1024 watchOS icon slot but **no image file is referenced**. You must:

1. Create a **1024×1024 px** PNG icon (no transparency, no rounded corners — Apple applies the mask)
2. Save it as `AppIcon.png` in:
   ```
   Kiters Watch App/Assets.xcassets/AppIcon.appiconset/
   ```
3. Update `Contents.json`:
   ```json
   {
     "images" : [
       {
         "filename" : "AppIcon.png",
         "idiom" : "universal",
         "platform" : "watchos",
         "size" : "1024x1024"
       }
     ],
     "info" : {
       "author" : "xcode",
       "version" : 1
     }
   }
   ```

### 4. App Store Metadata (in App Store Connect)
Prepare the following:

| Field | Notes |
|-------|-------|
| **App Name** | Kiters |
| **Subtitle** | Kitesurfing Jump Tracker |
| **Description** | Full app description (see below) |
| **Keywords** | kitesurfing,kitesurf,jump,tracker,airtime,watch,sport |
| **Category** | Sports |
| **Privacy Policy URL** | **REQUIRED** — host a privacy policy page |
| **Support URL** | Your support website/email |
| **Screenshots** | Apple Watch screenshots (see below) |

#### Suggested App Description:
```
Track your kitesurfing sessions with precision. Kiters uses Apple Watch sensors to automatically detect jumps, measure airtime, and calculate jump height in real-time.

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
Apple requires watchOS screenshots. Capture from:
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
1. Select the **Kiters** scheme (not "Kiters Watch App")
2. Set destination to **Any watchOS Device (arm64)**
3. Menu → **Product** → **Archive**
4. In the Organizer, click **Distribute App**
5. Choose **App Store Connect** → **Upload**
6. Follow the prompts (Xcode will validate automatically)

### 8. Review Readiness Checklist

| # | Item | Status |
|---|------|--------|
| 1 | App Icon (1024×1024) | ⚠️ **NEEDS IMAGE** |
| 2 | Privacy Manifest | ✅ Created |
| 3 | Info.plist usage descriptions | ✅ Complete |
| 4 | HealthKit entitlements | ✅ Configured |
| 5 | Background modes | ✅ Configured |
| 6 | Privacy Policy URL | ⚠️ **YOU NEED TO CREATE & HOST** |
| 7 | App Store screenshots | ⚠️ **YOU NEED TO CAPTURE** |
| 8 | App description & metadata | ⚠️ **YOU NEED TO FILL IN ASC** |
| 9 | Code signing | ✅ Automatic |
| 10 | Export compliance (`ITSAppUsesNonExemptEncryption`) | ✅ Set to NO |
| 11 | Version/Build numbers | ✅ Aligned (1.0 / 1) |
| 12 | Localization | ✅ English + Hebrew |
| 13 | Deprecated APIs | ✅ Fixed |
| 14 | Debug print statements | ⚠️ Consider replacing with `AppLogger` |
| 15 | Test on physical Apple Watch | ⚠️ **CRITICAL before submission** |

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
This app tracks kitesurfing sessions on Apple Watch. It requires:

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
- `MARKETING_VERSION` stays at `1.0` until you do a feature release

## Version Numbering Strategy
- **Marketing Version** (`CFBundleShortVersionString`): `1.0`, `1.1`, `2.0` etc.
- **Build Number** (`CFBundleVersion`): Increment for every upload: `1`, `2`, `3`...
- Each upload to App Store Connect must have a unique build number


SKU: 2D7LFZS835