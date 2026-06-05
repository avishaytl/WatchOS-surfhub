# 🚀 How to Run the iSurf Watch App on Your Mac

## Quick Answer

You can test the **UI and logic** on the watchOS Simulator, but **GPS and IMU sensors require a real Apple Watch**. Here's how to do both:

---

## Option 1: watchOS Simulator (Mac Only) ⚡ FASTEST

### What Works:
- ✅ UI/UX testing
- ✅ Navigation flows
- ✅ State management
- ✅ Mock data display
- ❌ No GPS (location will be simulated/fixed)
- ❌ No IMU sensors (no jump detection)
- ❌ No HealthKit workouts

### Steps:

#### 1. Create Xcode Project (First Time Only)

```bash
cd /Users/avishay/Desktop/isurf/apps/watchos

# Read the setup instructions
./setup-xcode-project.sh
```

Follow the printed instructions to create the Xcode project manually:

1. Open **Xcode**
2. **File → New → Project**
3. Select **watchOS → App**
4. Configure:
   - Product Name: `iSurf-Watch`
   - Team: Your Apple Developer Team
   - Organization Identifier: `com.isurf`
   - Bundle Identifier: `com.isurf.watch`
   - Interface: **SwiftUI**
   - Language: **Swift**
5. Save to: `/Users/avishay/Desktop/isurf/apps/watchos/`

#### 2. Add Source Files to Xcode

1. In Xcode, **delete** the auto-generated files:
   - `ContentView.swift`
   - `iSurf_WatchApp.swift` (or similar)

2. **Right-click** the project in navigator → **Add Files to "iSurf-Watch"...**

3. Select the **entire `iSurf-Watch` folder** from Finder

4. In the dialog:
   - ✅ Check "Copy items if needed"
   - ✅ Create groups (not folder references)
   - ✅ Add to targets: iSurf-Watch
   - Click **Add**

5. Your project navigator should now show:
   ```
   iSurf-Watch
   ├── iSurfApp.swift
   ├── Info.plist
   ├── Models/
   ├── Services/
   ├── Storage/
   └── Views/
   ```

#### 3. Configure Capabilities

1. Select the **project** (top of navigator)
2. Select the **iSurf-Watch target**
3. Go to **Signing & Capabilities** tab
4. Click **+ Capability** button
5. Add:
   - **HealthKit**
   - **Background Modes**
     - Enable: ✅ Location updates
     - Enable: ✅ Workout processing

#### 4. Replace Info.plist (Important!)

The auto-generated Info.plist is missing permissions. Replace it:

1. In Xcode navigator, **delete** the auto-generated `Info.plist`
2. The one we created already has all permissions configured
3. Xcode will use our `Info.plist` automatically

#### 5. Build & Run on Simulator

1. Select a watchOS Simulator target (top toolbar):
   - **Apple Watch Series 9 (45mm)** or
   - **Apple Watch Ultra 2 (49mm)**

2. Click **Run** button (▶️) or press **⌘R**

3. Wait for build (~30 seconds first time)

4. App should launch in the Watch Simulator! 🎉

### Testing in Simulator

**What to Test:**
```bash
✅ App launches without crashes
✅ Home screen shows "Start Session" button
✅ Tap "Start Session" → Sport selection appears
✅ Select a sport (e.g., Kiteboarding)
✅ Permission alerts appear (Location, Motion, HealthKit)
✅ Active session view shows (after permissions)
✅ Swipe between 3 tabs (Metrics, Jumps, Controls)
✅ Tap "Pause" → session pauses
✅ Tap "Resume" → session resumes
✅ Tap "End Session" → confirmation alert
✅ Confirm end → returns to home screen
✅ Session appears in "Recent" list
✅ Tap session → detail view shows
```

**Simulate Location (Optional):**
1. In Simulator menu: **Features → Location**
2. Select: **Custom Location...**
3. Enter coordinates (e.g., lat: 37.7749, lng: -122.4194)
4. GPS will now return this fixed location

**Limitations:**
- ⚠️ GPS doesn't update (fixed location)
- ⚠️ IMU returns zeros (no jump detection)
- ⚠️ HealthKit workouts may fail (simulator limitation)
- ⚠️ No background execution testing

---

## Option 2: Real Apple Watch (Device) 🎯 FULL TESTING

### What Works:
- ✅ **Everything!** Full app functionality
- ✅ Real GPS tracking
- ✅ Real IMU sensors (50Hz)
- ✅ Jump detection algorithm
- ✅ HealthKit workouts
- ✅ Background execution
- ✅ Battery testing

### Requirements:
- Apple Watch (Series 4 or later recommended)
- iPhone paired with the Watch
- Both connected to your Mac
- Apple Developer Account (free tier OK for testing)

### Steps:

#### 1. Pair Apple Watch to iPhone

1. Make sure Apple Watch is paired with your iPhone
2. Open **Watch app** on iPhone
3. Verify pairing is active

#### 2. Connect iPhone to Mac

1. Connect iPhone via **USB cable** or **WiFi**
2. Trust computer if prompted
3. In Xcode, the device should appear in target dropdown

#### 3. Update Xcode Target

1. In Xcode top toolbar, click the device dropdown
2. You should see:
   ```
   iPhone (your iPhone name)
   └── Apple Watch (your watch name)
   ```
3. Select the **Apple Watch** device

#### 4. Configure Signing

1. Select project → **Signing & Capabilities**
2. Under **Signing**:
   - Team: Select your Apple Developer team
   - Signing Certificate: Automatically managed
3. Xcode will create a provisioning profile

#### 5. Build & Run on Device

1. Make sure Apple Watch is **unlocked** and on your wrist
2. iPhone should be **unlocked** and nearby
3. Click **Run** (▶️) or press **⌘R**
4. First time: Xcode will install the app (~1-2 minutes)
5. App icon appears on Watch home screen
6. App launches automatically

### Field Testing (The Real Deal!)

#### Indoor Testing (Limited)
```bash
1. Launch app
2. Start a Kiteboarding session
3. Grant all permissions
4. Walk around indoors
   - GPS may be weak/inaccurate
   - IMU will work
5. Shake watch vigorously
   - May trigger false jump detections
   - Good for testing the algorithm!
6. Check Console logs in Xcode
   - Look for: "🚀 Takeoff", "✈️ Airborne", "🛬 Landing"
```

#### Outdoor Testing (Recommended!)
```bash
1. Go outside (clear sky for GPS)
2. Start a session
3. Walk/run for 5 minutes
   - Verify GPS accuracy
   - Check speed calculations
4. Do some jumps (or simulate):
   - Jump from a curb
   - Do a box jump
   - Actual kiteboarding/surfing!
5. End session
6. Review jump data
   - Height should be reasonable (0.5-2m for test jumps)
   - Airtime should match reality
7. Check battery drain
   - Note start/end battery %
```

### Debugging on Device

**View Console Logs:**
1. In Xcode, open **Debug Area** (⌘⇧Y)
2. Select **Console** tab (right side)
3. Run app and watch logs in real-time:
   ```
   📍 Location tracking started
   🎯 Motion tracking started at 50.0Hz
   🏃 Workout started: Kiteboarding
   🚀 Potential takeoff detected
   ✈️ Airborne confirmed
   🛬 Landing detected
   🎉 JUMP DETECTED! Height: 1.23m, Airtime: 0.87s
   ```

**Common Issues:**

| Issue | Solution |
|-------|----------|
| "Developer mode required" | Settings → Privacy & Security → Developer Mode → Enable |
| "Untrusted Developer" | Settings → General → VPN & Device Management → Trust developer |
| GPS not acquiring | Go outside, wait 30-60 seconds |
| No IMU data | Check Motion permission in Watch Settings |
| HealthKit errors | Settings → Health → Data Access → iSurf → Enable all |
| App crashes on launch | Check Xcode Console for error messages |

---

## Option 3: Quick Test Without Xcode Project 🔧

If you just want to verify the code compiles without creating a full Xcode project:

### Using `swiftc` (Swift Compiler)

```bash
cd /Users/avishay/Desktop/isurf/apps/watchos/iSurf-Watch

# Try to compile (will show errors if any)
swiftc -parse Models/Session.swift
swiftc -parse Services/LocationManager.swift
swiftc -parse Services/MotionManager.swift
# etc.
```

**Note**: This only checks syntax, doesn't run the app.

---

## 🎯 Recommended Testing Flow

### For You Right Now:

1. **Start with Simulator** (30 minutes)
   - Create Xcode project
   - Add source files
   - Build & run on simulator
   - Test UI flows
   - Verify no crashes

2. **Test on Device** (if you have Apple Watch)
   - Connect watch + iPhone
   - Build to device
   - Go outside
   - Do 5-minute walk/run
   - Verify GPS/IMU working

3. **Field Test** (when ready)
   - Go kiteboarding/surfing
   - Record full session
   - Analyze jump detection
   - Tune algorithm thresholds

---

## 📝 Quick Start Commands

```bash
# 1. Navigate to project
cd /Users/avishay/Desktop/isurf/apps/watchos

# 2. Verify all files present
./verify-project.sh

# 3. Read setup instructions
./setup-xcode-project.sh

# 4. Open Xcode and create project manually
# (Follow steps in "Option 1" above)

# 5. Build in Xcode:
#    - Select watchOS Simulator
#    - Press ⌘R
```

---

## 🐛 Troubleshooting

### Build Errors

**"Cannot find 'CLLocationManager' in scope"**
- Missing `import CoreLocation`
- Should already be in LocationManager.swift

**"Cannot find 'CMMotionManager' in scope"**
- Missing `import CoreMotion`
- Should already be in MotionManager.swift

**"No such module 'HealthKit'"**
- HealthKit capability not enabled
- Add in Signing & Capabilities tab

### Runtime Errors

**App crashes on launch**
- Check Console logs
- Likely missing Info.plist permissions
- Make sure you replaced the auto-generated Info.plist

**"Location services denied"**
- Simulator: Always works (simulated)
- Device: Settings → Privacy → Location → iSurf → While Using

**No jump detection**
- Normal in simulator (no IMU)
- On device: Check Motion permission
- Try walking/jumping vigorously

---

## 💡 Pro Tips

1. **Use Simulator for UI Development**
   - Faster iteration
   - No device needed
   - Good for layout/design

2. **Use Device for Algorithm Testing**
   - Real sensors required
   - Outdoor testing best
   - Check battery impact

3. **Check Logs Constantly**
   - Xcode Console shows all `print()` statements
   - Look for emoji prefixes: 📍🎯🏃🚀✈️🛬
   - Helps debug jump detection

4. **Test Permissions Flow**
   - First launch always triggers permission dialogs
   - Grant all for full functionality
   - Can reset: Settings → General → Reset → Reset Location & Privacy

5. **Monitor Battery**
   - Settings → Battery
   - Watch battery drain during session
   - Should last 4-6 hours

---

## ✅ Success Checklist

After setup, you should see:

- [ ] Xcode project compiles without errors
- [ ] App launches in simulator
- [ ] Can select sport and start session
- [ ] Active session shows live timer
- [ ] Can pause/resume/end session
- [ ] Session saves to history
- [ ] (Device only) GPS acquires location
- [ ] (Device only) Jump detection works
- [ ] (Device only) HealthKit workout saves

---

## 🎓 What You'll Learn

By running and testing this app, you'll experience:
- watchOS development workflow
- SwiftUI on small screens
- Real-time sensor data processing
- Background execution
- HealthKit integration
- Jump detection algorithm in action!

---

## 🚀 Ready to Run?

**Choose your path:**

**Path A: Quick UI Test (15 minutes)**
```bash
1. Create Xcode project
2. Add files
3. Run on simulator
4. Test UI flows
```

**Path B: Full Sensor Test (30 minutes + outdoor time)**
```bash
1. Create Xcode project
2. Add files
3. Run on real Apple Watch
4. Go outside
5. Test GPS and jump detection
```

**I recommend starting with Path A (simulator) to verify everything builds, then moving to Path B for real testing!**

---

Need help with any step? Let me know! 🙋‍♂️
