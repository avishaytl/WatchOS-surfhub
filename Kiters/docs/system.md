You are my senior mobile + wearable architect. I want you to generate a complete set of Markdown instruction files (docs/*.md) that explain how to build a“Surfr-like” wind sports tracker:

Goal (high level)
- A Watch App for iOS + Android watches that tracks a surf/kite session and detects:
  - speed (GPS)
  - jumps (from IMU accelerometer + gyroscope)
  - airtime and estimated jump height
  - session timeline (events list)
  - route map (GPS track)
- A React Native mobile app (iOS/Android) that:
  - pairs with the watch app
  - displays live metrics while riding (when possible) + full post-session analytics
  - syncs sessions to backend and supports offline-first
- A backend API in Node.js running in Docker:
  - user accounts + auth
  - session storage + analytics summaries
  - optional leaderboard (future)
  - upload/download of sessions
  - versioned API

Important constraints
- Must be cross-platform: Apple Watch + Wear OS.
- Use React Native for the phone app.
- Watch apps can be native (recommended): watchOS (Swift/SwiftUI) and Wear OS (Kotlin/Compose), because React Native cannot directly run on Apple Watch.
- Communication:
  - Phone <-> Apple Watch: WatchConnectivity
  - Phone <-> Wear OS: Data Layer API (Google Play Services)
- Sensor usage:
  - GPS + IMU sampled efficiently (battery)
  - Water sports constraints: intermittent connectivity, motion noise, saltwater, vibrations
- No dangerous instructions; focus on software design, sensors, algorithms, testing.

Deliverables (create these Markdown files)
1) docs/00_overview.md
   - product scope, supported sports, feature list (like Surfr/WOO: jumps, speed, airtime, route)
   - data ownership, privacy, offline model
2) docs/01_architecture.md
   - full system diagram: watch app, phone app, backend
   - event/data flow and sync strategy
3) docs/02_repo_structure.md
   - monorepo layout (apps/mobile, apps/watchos, apps/wearos, services/api, shared/)
4) docs/03_watchos_app.md
   - watchOS app setup (SwiftUI)
   - CoreMotion + CoreLocation collection loop
   - background session considerations
   - WatchConnectivity messaging + file transfer
5) docs/04_wearos_app.md
   - Wear OS app setup (Kotlin)
   - Sensors API + FusedLocationProvider
   - Data Layer messaging + sync
6) docs/05_jump_detection.md
   - algorithm design (IMU + GPS)
   - jump segmentation, takeoff/landing detection, airtime estimation
   - height estimation approaches + calibration notes
   - smoothing/filters, false-positive reduction
   - confidence scoring per jump
7) docs/06_data_model.md
   - JSON schema for a session: samples, events, jumps, summaries
   - storage format for bulk samples (chunking/compression)
8) docs/07_mobile_app.md
   - React Native app architecture
   - screens: Home, Live Session, Session Details, Map, Jumps List, Settings
   - local DB (SQLite/Realm) + sync queue
9) docs/08_backend_api.md
   - Node.js API (suggest NestJS or Express)
   - endpoints (auth, sessions CRUD, upload, download)
   - DB choice (Postgres recommended)
   - basic rate limiting + validation
10) docs/09_docker_devops.md
   - docker-compose for api + db
   - env vars, migrations, local dev scripts
11) docs/10_testing.md
   - unit tests for detection algorithm
   - sensor replay framework (feed recorded IMU/GPS logs)
   - e2e for mobile
12) docs/11_security_privacy.md
   - minimal PII, encryption at rest/in transit
   - GDPR-ish considerations
13) docs/12_roadmap.md
   - MVP vs v1 vs v2 features (leaderboards, 3D replay, coaching, sharing)

Quality bar
- Each doc must be actionable and step-by-step.
- Include code snippets ONLY where necessary (short and focused).
- Include diagrams as ASCII or Mermaid where helpful.
- Emphasize battery/performance and offline-first.
- Provide clear “MVP first” instructions and optional enhancements.
- At the end of each doc, include a checklist.

Start by generating the full docs/ file contents in order.
```

### Quick reality-check (so you don’t get stuck later)

* A “Surfr-like” product is very doable, but the **watch apps should be native** (watchOS + Wear OS). React Native is perfect for the **phone app**, not the watch apps.
* Accuracy depends a lot on your **jump detection algorithm** + **sensor sampling strategy** (battery vs precision).

If you want, paste here what Copilot generates, and I’ll help you tighten it into a clean MVP plan (and improve the jump detection section so it’s actually practical on real water sessions).

[1]: https://www.thesurfr.app/?utm_source=chatgpt.com "Surfr. – The ultimate kiteboarding app"
[2]: https://www.woosports.com/en?utm_source=chatgpt.com "WOO Sports – Global Game for Kiteboarders & Wingers"
