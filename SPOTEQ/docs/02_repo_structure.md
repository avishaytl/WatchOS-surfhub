# 02 - Repository Structure

## Monorepo Layout

SPOTEQ uses a **monorepo** to share code and types across all platforms while keeping platform-specific code isolated.

```
spoteq/
├── apps/
│   ├── mobile/                 # React Native app (iOS/Android phones)
│   ├── watchos/                # Apple Watch app (Swift/SwiftUI)
│   └── wearos/                 # Wear OS app (Kotlin/Compose)
│
├── packages/                   # Shared code
│   ├── shared-types/           # TypeScript types (sessions, jumps, etc.)
│   ├── jump-detection/         # Jump algorithm (TypeScript, for testing)
│   └── api-client/             # API client library (TypeScript)
│
├── services/
│   └── api/                    # Backend API (Node.js/NestJS)
│
├── tools/
│   ├── sensor-replay/          # Tool to replay recorded sensor data
│   └── session-validator/      # Validate session JSON files
│
├── docs/                       # This documentation
│
├── scripts/                    # Build and development scripts
│   ├── setup.sh
│   ├── start-dev.sh
│   └── deploy.sh
│
├── .github/
│   └── workflows/              # CI/CD pipelines
│
├── docker-compose.yml          # Local development environment
├── package.json                # Root package.json (monorepo)
├── turbo.json                  # Turborepo config (optional)
├── .gitignore
└── README.md
```

## Detailed Directory Breakdown

### `apps/mobile/` - React Native App

```
apps/mobile/
├── ios/                        # iOS native project
│   ├── SPOTEQ.xcworkspace
│   └── SPOTEQ/
│       ├── AppDelegate.mm
│       ├── Info.plist
│       └── WatchConnectivity/  # Native module for WatchConnectivity
│
├── android/                    # Android native project
│   ├── app/
│   │   ├── src/main/
│   │   │   ├── AndroidManifest.xml
│   │   │   └── java/.../
│   │   │       └── WearableModule.kt  # Native module for Data Layer
│   │   └── build.gradle
│   └── build.gradle
│
├── src/
│   ├── screens/                # React Native screens
│   │   ├── HomeScreen.tsx
│   │   ├── LiveSessionScreen.tsx
│   │   ├── SessionDetailScreen.tsx
│   │   ├── SessionListScreen.tsx
│   │   ├── MapScreen.tsx
│   │   └── SettingsScreen.tsx
│   │
│   ├── components/             # Reusable components
│   │   ├── SessionCard.tsx
│   │   ├── JumpCard.tsx
│   │   ├── SpeedGauge.tsx
│   │   └── MapView.tsx
│   │
│   ├── navigation/             # React Navigation setup
│   │   └── RootNavigator.tsx
│   │
│   ├── services/               # Business logic
│   │   ├── watch/
│   │   │   ├── WatchConnectivityService.ts
│   │   │   └── WearOSDataLayerService.ts
│   │   ├── sync/
│   │   │   ├── SyncEngine.ts
│   │   │   └── SyncQueue.ts
│   │   ├── database/
│   │   │   ├── Database.ts
│   │   │   ├── SessionRepository.ts
│   │   │   └── migrations/
│   │   └── api/
│   │       └── ApiClient.ts
│   │
│   ├── store/                  # State management (Zustand/MobX)
│   │   ├── sessionStore.ts
│   │   ├── authStore.ts
│   │   └── syncStore.ts
│   │
│   ├── utils/                  # Helper functions
│   │   ├── gps.ts
│   │   ├── units.ts
│   │   └── dateTime.ts
│   │
│   ├── types/                  # TypeScript types (extends shared-types)
│   │   └── index.ts
│   │
│   └── App.tsx                 # Root component
│
├── package.json
├── tsconfig.json
├── metro.config.js
└── .eslintrc.js
```

### `apps/watchos/` - Apple Watch App

```
apps/watchos/
├── SPOTEQ.xcodeproj
├── SPOTEQ/
│   ├── SPOTEQApp.swift          # App entry point
│   ├── ContentView.swift       # Main SwiftUI view
│   │
│   ├── Views/
│   │   ├── SessionView.swift   # Active session UI
│   │   ├── SummaryView.swift   # Post-session summary
│   │   └── SettingsView.swift
│   │
│   ├── Services/
│   │   ├── LocationManager.swift       # CoreLocation wrapper
│   │   ├── MotionManager.swift         # CoreMotion wrapper
│   │   ├── WorkoutManager.swift        # HealthKit workout session
│   │   ├── JumpDetector.swift          # Jump detection algorithm
│   │   └── WatchConnectivityManager.swift
│   │
│   ├── Models/
│   │   ├── Session.swift
│   │   ├── Jump.swift
│   │   ├── GPSPoint.swift
│   │   └── IMUSample.swift
│   │
│   ├── Storage/
│   │   ├── SessionStore.swift  # Local persistence
│   │   └── FileManager+Session.swift
│   │
│   └── Utils/
│       ├── Filters.swift       # Signal processing
│       └── Constants.swift
│
├── Tests/
│   └── JumpDetectorTests.swift
│
└── Info.plist
```

### `apps/wearos/` - Wear OS App

```
apps/wearos/
├── app/
│   ├── src/
│   │   ├── main/
│   │   │   ├── AndroidManifest.xml
│   │   │   ├── java/com/spoteq/wearos/
│   │   │   │   ├── MainActivity.kt
│   │   │   │   │
│   │   │   │   ├── ui/
│   │   │   │   │   ├── SessionScreen.kt
│   │   │   │   │   ├── SummaryScreen.kt
│   │   │   │   │   └── theme/
│   │   │   │   │
│   │   │   │   ├── services/
│   │   │   │   │   ├── LocationService.kt
│   │   │   │   │   ├── SensorService.kt
│   │   │   │   │   ├── JumpDetector.kt
│   │   │   │   │   └── DataLayerService.kt
│   │   │   │   │
│   │   │   │   ├── models/
│   │   │   │   │   ├── Session.kt
│   │   │   │   │   ├── Jump.kt
│   │   │   │   │   └── GPSPoint.kt
│   │   │   │   │
│   │   │   │   ├── data/
│   │   │   │   │   ├── SessionDatabase.kt
│   │   │   │   │   ├── SessionDao.kt
│   │   │   │   │   └── SessionRepository.kt
│   │   │   │   │
│   │   │   │   └── utils/
│   │   │   │       ├── Filters.kt
│   │   │   │       └── Constants.kt
│   │   │   │
│   │   │   └── res/
│   │   │       ├── layout/
│   │   │       ├── values/
│   │   │       └── drawable/
│   │   │
│   │   └── test/
│   │       └── java/.../JumpDetectorTest.kt
│   │
│   └── build.gradle
│
└── build.gradle
```

### `packages/shared-types/` - Shared TypeScript Types

```
packages/shared-types/
├── src/
│   ├── session.ts
│   ├── jump.ts
│   ├── gps.ts
│   ├── imu.ts
│   ├── user.ts
│   ├── api.ts
│   └── index.ts
│
├── package.json
└── tsconfig.json
```

**Example**: `src/session.ts`
```typescript
export interface Session {
  id: string;
  userId?: string;
  sport: 'kiteboarding' | 'windsurfing' | 'wingfoiling' | 'surfing';
  startTime: string; // ISO 8601
  endTime: string;
  
  summary: SessionSummary;
  jumps: Jump[];
  gpsTrack: GPSPoint[];
  
  metadata: {
    watchType: 'apple' | 'wearos';
    appVersion: string;
    synced: boolean;
  };
}

export interface SessionSummary {
  distance: number;        // km
  duration: number;        // seconds
  maxSpeed: number;        // km/h
  avgSpeed: number;        // km/h
  jumpCount: number;
  maxJumpHeight: number;   // meters
  totalAirtime: number;    // seconds
}
```

### `packages/jump-detection/` - Jump Algorithm (TypeScript)

```
packages/jump-detection/
├── src/
│   ├── detector.ts             # Main algorithm
│   ├── filters.ts              # Signal processing
│   ├── heightEstimator.ts      # Height calculation
│   └── index.ts
│
├── tests/
│   ├── detector.test.ts
│   └── fixtures/
│       └── sample-jump-data.json
│
├── package.json
└── tsconfig.json
```

**Purpose**: Shared algorithm logic that can be tested in TypeScript and ported to Swift/Kotlin.

### `services/api/` - Backend API

```
services/api/
├── src/
│   ├── main.ts                 # Application entry
│   │
│   ├── modules/
│   │   ├── auth/
│   │   │   ├── auth.controller.ts
│   │   │   ├── auth.service.ts
│   │   │   ├── auth.module.ts
│   │   │   ├── jwt.strategy.ts
│   │   │   └── dto/
│   │   │
│   │   ├── users/
│   │   │   ├── users.controller.ts
│   │   │   ├── users.service.ts
│   │   │   ├── users.module.ts
│   │   │   └── entities/user.entity.ts
│   │   │
│   │   └── sessions/
│   │       ├── sessions.controller.ts
│   │       ├── sessions.service.ts
│   │       ├── sessions.module.ts
│   │       ├── entities/session.entity.ts
│   │       └── dto/
│   │
│   ├── common/
│   │   ├── guards/
│   │   ├── filters/
│   │   ├── pipes/
│   │   └── interceptors/
│   │
│   ├── config/
│   │   ├── database.config.ts
│   │   └── jwt.config.ts
│   │
│   └── utils/
│       └── compression.ts
│
├── test/
│   ├── auth.e2e.spec.ts
│   └── sessions.e2e.spec.ts
│
├── migrations/                 # Database migrations
│   └── 001_initial_schema.sql
│
├── Dockerfile
├── package.json
├── tsconfig.json
└── nest-cli.json
```

### `tools/sensor-replay/` - Development Tool

```
tools/sensor-replay/
├── src/
│   ├── index.ts
│   ├── player.ts               # Replay recorded sensor data
│   └── recorder.ts             # Record sensors from watch
│
├── recordings/                 # Sample IMU+GPS recordings
│   ├── jump-session-1.json
│   └── false-positive-test.json
│
└── package.json
```

**Usage**: Test jump detection algorithm with real-world sensor data.

## Package Dependencies

### Root `package.json`

```json
{
  "name": "spoteq-monorepo",
  "private": true,
  "workspaces": [
    "apps/*",
    "packages/*",
    "services/*",
    "tools/*"
  ],
  "scripts": {
    "mobile": "cd apps/mobile && npm start",
    "api": "cd services/api && npm run start:dev",
    "api:docker": "docker-compose up",
    "test": "npm run test --workspaces",
    "lint": "npm run lint --workspaces",
    "build": "npm run build --workspaces"
  },
  "devDependencies": {
    "eslint": "^8.57.0",
    "prettier": "^3.0.0",
    "typescript": "^5.3.0"
  }
}
```

### Shared Dependencies

**All TypeScript projects**:
- TypeScript 5.3+
- ESLint + Prettier
- Jest for testing

**Mobile App**:
- React Native 0.73+
- React Navigation 6+
- Realm or WatermelonDB
- React Native Maps
- Zustand (state management)

**Backend API**:
- NestJS 10+
- TypeORM or Prisma
- PostgreSQL driver
- Passport (JWT)
- class-validator

## Build & Development Scripts

### `scripts/setup.sh`

```bash
#!/bin/bash
# Initial repository setup

echo "Setting up SPOTEQ monorepo..."

# Install root dependencies
npm install

# Install all workspace dependencies
npm install --workspaces

# Setup backend database
cd services/api
docker-compose up -d postgres
npm run migration:run

echo "Setup complete!"
```

### `scripts/start-dev.sh`

```bash
#!/bin/bash
# Start all services for development

# Terminal 1: API
cd services/api && npm run start:dev &

# Terminal 2: Mobile app
cd apps/mobile && npm start &

echo "All services started. Open watch apps in Xcode/Android Studio."
```

## Git Strategy

### Branch Structure
```
main                    # Production-ready code
├── develop             # Integration branch
│   ├── feature/watchos-jump-detection
│   ├── feature/mobile-session-list
│   └── fix/sync-queue-retry
└── release/v1.0.0
```

### Commit Convention
Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(watchos): add jump height estimation
fix(mobile): sync queue retry logic
docs(api): update API documentation
test(jump-detection): add false-positive tests
```

## Development Checklist

### Repository Setup
- [ ] Create GitHub repository
- [ ] Initialize monorepo with workspaces
- [ ] Set up shared TypeScript types package
- [ ] Configure ESLint and Prettier across all packages
- [ ] Set up Git hooks (pre-commit linting)

### Mobile App
- [ ] Initialize React Native project
- [ ] Set up React Navigation
- [ ] Configure Realm/WatermelonDB
- [ ] Create native modules for watch communication

### watchOS App
- [ ] Create Xcode project
- [ ] Enable WatchKit extension
- [ ] Set up CoreMotion and CoreLocation entitlements
- [ ] Configure Info.plist for background modes

### Wear OS App
- [ ] Create Android Studio project with Wear OS module
- [ ] Configure Wear OS dependencies
- [ ] Set up permissions in AndroidManifest.xml
- [ ] Add Jetpack Compose for Wear

### Backend API
- [ ] Initialize NestJS project
- [ ] Set up PostgreSQL with Docker
- [ ] Create initial database migration
- [ ] Configure JWT authentication

### CI/CD
- [ ] Set up GitHub Actions workflows
- [ ] Add automated tests on PR
- [ ] Configure linting checks
- [ ] Set up deployment pipeline (future)

---

**Next Steps**: Start with the watchOS app implementation (`03_watchos_app.md`) or set up the mobile app (`07_mobile_app.md`) depending on your platform preference.
