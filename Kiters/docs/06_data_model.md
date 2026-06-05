# 06 - Data Model

## Overview

The data model defines how sessions, jumps, GPS tracks, and IMU data are stored and transmitted across the system. The model must be:

1. **Efficient**: Minimize storage and bandwidth
2. **Portable**: JSON-serializable for cross-platform compatibility
3. **Versioned**: Support schema evolution
4. **Queryable**: Enable fast filtering and aggregation

## Core Entities

### Session

The top-level container for a single water sports session.

```typescript
// packages/shared-types/src/session.ts

export interface Session {
  // Identity
  id: string;                    // UUID v4
  userId?: string;               // User ID (if synced to backend)
  
  // Metadata
  sport: Sport;
  startTime: string;             // ISO 8601 datetime
  endTime: string;               // ISO 8601 datetime
  timezone?: string;             // IANA timezone (e.g., "America/Los_Angeles")
  
  // Summary statistics
  summary: SessionSummary;
  
  // Data collections
  jumps: Jump[];
  gpsTrack: GPSPoint[];          // Can be large - see compression strategy
  
  // System metadata
  metadata: SessionMetadata;
  
  // Optional fields
  notes?: string;                // User notes
  weather?: WeatherConditions;   // Future: weather at session time
  location?: string;             // Named location (e.g., "Crissy Field")
}

export enum Sport {
  Kiteboarding = 'kiteboarding',
  Windsurfing = 'windsurfing',
  Wingfoiling = 'wingfoiling',
  Surfing = 'surfing'
}

export interface SessionSummary {
  distance: number;              // Total distance in km
  duration: number;              // Total duration in seconds
  maxSpeed: number;              // Max speed in km/h
  avgSpeed: number;              // Average speed in km/h (while moving)
  jumpCount: number;             // Total jumps detected
  maxJumpHeight: number;         // Highest jump in meters
  totalAirtime: number;          // Total airtime in seconds
  calories?: number;             // Estimated calories (future)
}

export interface SessionMetadata {
  version: string;               // Data schema version (e.g., "1.0")
  watchType: 'apple' | 'wearos'; // Source device
  appVersion: string;            // App version that recorded session
  synced: boolean;               // Has been uploaded to backend
  syncedAt?: string;             // ISO 8601 datetime of last sync
  deviceId?: string;             // Anonymized device identifier
}
```

### Jump

Individual jump event within a session.

```typescript
// packages/shared-types/src/jump.ts

export interface Jump {
  // Identity
  id: string;                    // Unique ID within session
  
  // Timing
  startTime: string;             // ISO 8601 (takeoff)
  endTime: string;               // ISO 8601 (landing)
  airtime: number;               // Airtime in seconds
  
  // Metrics
  height: number;                // Estimated height in meters
  maxVerticalVelocity: number;   // Peak vertical velocity in m/s
  distance?: number;             // Horizontal distance in meters (future)
  
  // Context
  takeoffSpeed: number;          // Speed at takeoff in km/h
  landingSpeed: number;          // Speed at landing in km/h
  takeoffLocation?: GPSPoint;    // GPS at takeoff (optional)
  landingLocation?: GPSPoint;    // GPS at landing (optional)
  
  // Classification
  confidence: number;            // Confidence score 0-100
  rotationDetected: boolean;     // Was rotation detected
  rotationType?: RotationType;   // Type of rotation (future)
  
  // Raw data (optional, for analysis)
  rawIMU?: IMUSample[];          // IMU samples during jump
}

export enum RotationType {
  None = 'none',
  Frontroll = 'frontroll',
  Backroll = 'backroll',
  Handle pass = 'handlepass',
  Unknown = 'unknown'
}
```

### GPS Point

Location sample from GPS.

```typescript
// packages/shared-types/src/gps.ts

export interface GPSPoint {
  timestamp: string;             // ISO 8601 datetime
  latitude: number;              // Decimal degrees
  longitude: number;             // Decimal degrees
  altitude: number;              // Meters above sea level
  speed: number;                 // Speed in m/s
  course: number;                // Heading in degrees (0-360)
  horizontalAccuracy: number;    // Accuracy in meters
  verticalAccuracy: number;      // Accuracy in meters
}

// Compressed format for storage (optional optimization)
export interface GPSTrackCompressed {
  startTime: string;             // ISO 8601 of first point
  interval: number;              // Seconds between samples (usually 1.0)
  
  // Delta-encoded arrays (differences from previous point)
  latDeltas: number[];           // Latitude deltas * 1e7 (integer compression)
  lonDeltas: number[];           // Longitude deltas * 1e7
  altDeltas: number[];           // Altitude deltas * 10 (decimeter precision)
  speeds: number[];              // Speed * 10 (0.1 m/s precision)
  courses: number[];             // Course in degrees (integer)
}
```

### IMU Sample

Inertial measurement unit data (accelerometer + gyroscope).

```typescript
// packages/shared-types/src/imu.ts

export interface IMUSample {
  timestamp: string;             // ISO 8601 datetime
  
  // Accelerometer (m/s², gravity removed)
  accelerationX: number;         // Lateral (left/right)
  accelerationY: number;         // Longitudinal (forward/back)
  accelerationZ: number;         // Vertical (up/down)
  
  // Gyroscope (rad/s)
  rotationX: number;             // Pitch rate
  rotationY: number;             // Roll rate
  rotationZ: number;             // Yaw rate
  
  // Orientation (rad)
  pitch: number;                 // Pitch angle
  roll: number;                  // Roll angle
  yaw: number;                   // Yaw angle (heading)
}

// Note: IMU data is typically NOT stored for entire session
// Only saved during detected jumps (rawIMU field in Jump)
```

### User

User account information (backend only).

```typescript
// packages/shared-types/src/user.ts

export interface User {
  id: string;                    // UUID v4
  email: string;
  username: string;
  
  // Profile
  firstName?: string;
  lastName?: string;
  avatarUrl?: string;
  bio?: string;
  
  // Preferences
  preferredSport?: Sport;
  units: 'metric' | 'imperial';
  
  // Privacy
  profilePublic: boolean;
  sessionsPublic: boolean;
  
  // Stats (cached)
  totalSessions: number;
  totalDistance: number;         // km
  totalJumps: number;
  bestJumpHeight: number;        // meters
  
  // System
  createdAt: string;             // ISO 8601
  lastLoginAt?: string;
}
```

## Storage Formats

### Local Storage (Watch)

**Format**: SQLite or file-based JSON

**Strategy**:
- Active session: In-memory buffer + periodic flush to disk
- Completed sessions: Compressed JSON files
- Retention: Last 10 sessions (auto-delete older)

**Example File Structure**:
```
/sessions/
  ├── session_2026-02-22_10-00-00.json     (3.2 MB)
  ├── session_2026-02-21_14-30-00.json     (1.8 MB)
  └── ...
```

### Local Storage (Phone)

**Format**: Realm or WatermelonDB (embedded database)

**Schema**:
```typescript
// Realm schema example
class SessionSchema {
  _id: string;
  sport: string;
  startTime: Date;
  endTime: Date;
  summaryJson: string;           // Serialized SessionSummary
  jumpCount: number;             // Denormalized for queries
  maxSpeed: number;              // Denormalized for queries
  synced: boolean;
  
  // Relationships
  jumps: Jump[];                 // One-to-many
  gpsPoints: GPSPoint[];         // One-to-many (can be huge!)
}
```

**Indexes**:
```typescript
// For fast queries
indexes: [
  'startTime',                   // Sort by date
  'sport',                       // Filter by sport
  'synced',                      // Find unsynced sessions
  ['userId', 'startTime']        // Multi-column for user timeline
]
```

### Backend Storage (PostgreSQL)

**Tables**:

```sql
-- sessions table (metadata only)
CREATE TABLE sessions (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sport VARCHAR(20) NOT NULL,
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ NOT NULL,
  
  -- Summary (denormalized for fast queries)
  distance_km DECIMAL(10, 2),
  duration_sec INTEGER,
  max_speed_kmh DECIMAL(6, 2),
  avg_speed_kmh DECIMAL(6, 2),
  jump_count INTEGER,
  max_jump_height_m DECIMAL(6, 2),
  total_airtime_sec DECIMAL(10, 2),
  
  -- Metadata
  version VARCHAR(10),
  watch_type VARCHAR(10),
  app_version VARCHAR(20),
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Indexes
  INDEX idx_user_start (user_id, start_time DESC),
  INDEX idx_sport (sport),
  INDEX idx_start_time (start_time DESC)
);

-- jumps table
CREATE TABLE jumps (
  id UUID PRIMARY KEY,
  session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ NOT NULL,
  airtime DECIMAL(6, 3),
  height_m DECIMAL(6, 2),
  
  takeoff_speed_kmh DECIMAL(6, 2),
  landing_speed_kmh DECIMAL(6, 2),
  
  confidence INTEGER,
  rotation_detected BOOLEAN,
  
  -- Indexes
  INDEX idx_session (session_id),
  INDEX idx_height (height_m DESC)
);

-- gps_tracks table (bulk storage)
CREATE TABLE gps_tracks (
  id UUID PRIMARY KEY,
  session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  
  -- Compressed data (JSONB or binary)
  track_data JSONB NOT NULL,    -- Array of GPSPoint
  
  -- Or use PostGIS for spatial queries (advanced)
  -- track_geom GEOMETRY(LineString, 4326),
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- imu_data table (optional, for jump analysis)
CREATE TABLE imu_data (
  id UUID PRIMARY KEY,
  jump_id UUID NOT NULL REFERENCES jumps(id) ON DELETE CASCADE,
  
  samples JSONB NOT NULL,        -- Array of IMUSample
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

## Compression Strategies

### GPS Track Compression

**Problem**: 2-hour session at 1Hz GPS = 7,200 points × ~100 bytes = ~700 KB

**Solutions**:

1. **Delta Encoding** (Reduces ~40%):
```typescript
function compressGPSTrack(points: GPSPoint[]): GPSTrackCompressed {
  const compressed: GPSTrackCompressed = {
    startTime: points[0].timestamp,
    interval: 1.0,
    latDeltas: [],
    lonDeltas: [],
    altDeltas: [],
    speeds: [],
    courses: []
  };
  
  let prevLat = points[0].latitude;
  let prevLon = points[0].longitude;
  let prevAlt = points[0].altitude;
  
  for (let i = 1; i < points.length; i++) {
    const p = points[i];
    
    // Multiply by 1e7 to preserve precision in integer
    compressed.latDeltas.push(Math.round((p.latitude - prevLat) * 1e7));
    compressed.lonDeltas.push(Math.round((p.longitude - prevLon) * 1e7));
    compressed.altDeltas.push(Math.round((p.altitude - prevAlt) * 10));
    compressed.speeds.push(Math.round(p.speed * 10));
    compressed.courses.push(Math.round(p.course));
    
    prevLat = p.latitude;
    prevLon = p.longitude;
    prevAlt = p.altitude;
  }
  
  return compressed;
}
```

2. **Douglas-Peucker Simplification** (Reduces ~60%, lossy):
```typescript
// Remove GPS points that don't significantly change the route shape
function simplifyTrack(points: GPSPoint[], tolerance: number = 5): GPSPoint[] {
  // Use Ramer-Douglas-Peucker algorithm
  // Keep points where deviation > tolerance (meters)
  return douglasPeucker(points, tolerance);
}
```

3. **gzip Compression** (Additional ~70% reduction):
```typescript
// Apply gzip to JSON before storage
const json = JSON.stringify(gpsTrack);
const compressed = gzip(json);
```

**Recommendation**: Use delta encoding + gzip for MVP. Add Douglas-Peucker as optional "archive" mode.

### IMU Data Compression

**Strategy**: Only store IMU during detected jumps (not entire session).

```typescript
interface JumpWithIMU {
  jump: Jump;
  imuSamples: IMUSample[];  // Typically 50-150 samples (1-3 seconds at 50Hz)
}

// Storage: ~100 samples × 60 bytes = ~6 KB per jump
// 15 jumps per session = ~90 KB (acceptable)
```

## Data Versioning

### Schema Version

Every `Session` includes `metadata.version` for backward compatibility.

```typescript
export const CURRENT_SCHEMA_VERSION = '1.0';

// Future: Schema migration
function migrateSession(session: any): Session {
  const version = session.metadata?.version || '0.9';
  
  switch (version) {
    case '0.9':
      // Migrate from beta format
      session = migrateBeta(session);
      // Fall through to 1.0
    case '1.0':
      return session as Session;
    default:
      throw new Error(`Unknown schema version: ${version}`);
  }
}
```

## API Data Transfer

### Upload Session

**Request**:
```http
POST /api/v1/sessions
Content-Type: application/json
Authorization: Bearer <jwt_token>

{
  "session": {
    "id": "uuid",
    "sport": "kiteboarding",
    "startTime": "2026-02-22T10:00:00Z",
    "endTime": "2026-02-22T12:30:00Z",
    "summary": { ... },
    "metadata": { ... }
  },
  "jumps": [ ... ],
  "gpsTrack": { ... }  // Compressed format
}
```

**Response**:
```json
{
  "success": true,
  "sessionId": "uuid",
  "syncedAt": "2026-02-22T12:35:00Z"
}
```

### Download Session

**Request**:
```http
GET /api/v1/sessions/:id
Authorization: Bearer <jwt_token>
```

**Response**:
```json
{
  "session": { ... },
  "jumps": [ ... ],
  "gpsTrack": { ... }
}
```

## Example Session JSON

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "userId": "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d",
  "sport": "kiteboarding",
  "startTime": "2026-02-22T10:00:00-08:00",
  "endTime": "2026-02-22T12:30:00-08:00",
  "timezone": "America/Los_Angeles",
  
  "summary": {
    "distance": 25.3,
    "duration": 9000,
    "maxSpeed": 42.5,
    "avgSpeed": 18.2,
    "jumpCount": 15,
    "maxJumpHeight": 8.5,
    "totalAirtime": 45.2
  },
  
  "jumps": [
    {
      "id": "jump_1",
      "startTime": "2026-02-22T10:15:32-08:00",
      "endTime": "2026-02-22T10:15:35-08:00",
      "airtime": 2.8,
      "height": 8.5,
      "maxVerticalVelocity": 6.2,
      "takeoffSpeed": 38.5,
      "landingSpeed": 35.2,
      "confidence": 95,
      "rotationDetected": true
    }
  ],
  
  "gpsTrack": [
    {
      "timestamp": "2026-02-22T10:00:00-08:00",
      "latitude": 37.8044,
      "longitude": -122.4656,
      "altitude": 2.5,
      "speed": 0.0,
      "course": 0,
      "horizontalAccuracy": 5.0,
      "verticalAccuracy": 10.0
    }
  ],
  
  "metadata": {
    "version": "1.0",
    "watchType": "apple",
    "appVersion": "1.0.0",
    "synced": true,
    "syncedAt": "2026-02-22T12:35:00Z",
    "deviceId": "hashed_device_id"
  },
  
  "notes": "Perfect conditions at Crissy Field!",
  "location": "Crissy Field, San Francisco"
}
```

## Development Checklist

### Type Definitions
- [ ] Create `packages/shared-types` package
- [ ] Define all TypeScript interfaces
- [ ] Add JSDoc comments
- [ ] Export types for all platforms

### Watch Storage
- [ ] Implement session file writer (JSON)
- [ ] Add compression for GPS tracks
- [ ] Test storage limits (max 10 sessions)
- [ ] Add auto-cleanup of old sessions

### Phone Storage
- [ ] Set up Realm or WatermelonDB
- [ ] Define database schema
- [ ] Add indexes for queries
- [ ] Implement migration strategy

### Backend Storage
- [ ] Create PostgreSQL schema
- [ ] Add database indexes
- [ ] Test query performance (>100K sessions)
- [ ] Implement archival strategy (old GPS tracks to S3)

### Compression
- [ ] Implement delta encoding for GPS
- [ ] Add gzip compression
- [ ] Test compression ratios
- [ ] Benchmark decompression speed

### API
- [ ] Define API request/response formats
- [ ] Add validation schemas (Zod or Joi)
- [ ] Document all endpoints (OpenAPI)
- [ ] Test with large sessions (>10K GPS points)

---

**Next Steps**: Build the React Native mobile app (`07_mobile_app.md`) to display and manage sessions.
