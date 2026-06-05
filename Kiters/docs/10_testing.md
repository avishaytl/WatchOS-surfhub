# 10 - Testing Strategy

## Overview

Comprehensive testing ensures the reliability of jump detection, session tracking, and data sync. This document covers unit tests, integration tests, sensor replay, and e2e testing.

## Testing Pyramid

```
                    /\
                   /  \        E2E Tests (5%)
                  /    \       - Full user flows
                 /------\      - Mobile app integration
                /        \     
               /  Int.    \    Integration Tests (25%)
              /   Tests    \   - API endpoints
             /              \  - Database operations
            /----------------\ 
           /                  \
          /    Unit Tests      \ Unit Tests (70%)
         /                      \ - Jump detection
        /________________________\ - Business logic
```

## Test Stack

### Watch Apps (Swift/Kotlin)
- **Swift**: XCTest
- **Kotlin**: JUnit 5 + MockK

### Mobile App (React Native)
- **Unit**: Jest
- **Component**: React Native Testing Library
- **E2E**: Detox

### Backend (NestJS)
- **Unit**: Jest
- **E2E**: Supertest
- **Database**: In-memory SQLite or test PostgreSQL

## Unit Tests

### Jump Detection Algorithm (TypeScript)

```typescript
// packages/jump-detection/tests/detector.test.ts
import { JumpDetector } from '../src/detector';
import { IMUSample } from '../src/types';
import { loadTestRecording } from './fixtures/recordings';

describe('JumpDetector', () => {
  let detector: JumpDetector;
  
  beforeEach(() => {
    detector = new JumpDetector();
    detector.updateSpeed(10); // 10 m/s (36 km/h)
  });
  
  describe('Jump Detection', () => {
    it('should detect a valid jump from real sensor data', async () => {
      const recording = await loadTestRecording('real-jump-2.8s.json');
      
      for (const sample of recording.samples) {
        detector.processSample(sample);
      }
      
      const jumps = detector.getDetectedJumps();
      
      expect(jumps).toHaveLength(1);
      expect(jumps[0].airtime).toBeCloseTo(2.8, 1); // ±0.1s
      expect(jumps[0].height).toBeGreaterThan(3.0);
      expect(jumps[0].confidence).toBeGreaterThan(80);
    });
    
    it('should not detect jumps when speed is too low', () => {
      detector.updateSpeed(2); // 2 m/s - too slow
      
      const sample: IMUSample = {
        timestamp: new Date(),
        accelerationX: 0,
        accelerationY: 0,
        accelerationZ: 3.0, // Strong upward acceleration
        rotationX: 0,
        rotationY: 0,
        rotationZ: 0,
        pitch: 0,
        roll: 0,
        yaw: 0,
      };
      
      detector.processSample(sample);
      
      expect(detector.getDetectedJumps()).toHaveLength(0);
    });
    
    it('should filter out false positives from choppy water', async () {
      const recording = await loadTestRecording('choppy-water-no-jumps.json');
      
      for (const sample of recording.samples) {
        detector.processSample(sample);
      }
      
      const jumps = detector.getDetectedJumps();
      
      // Should detect 0 jumps (or very low confidence ones)
      const highConfidenceJumps = jumps.filter(j => j.confidence > 70);
      expect(highConfidenceJumps).toHaveLength(0);
    });
    
    it('should detect multiple jumps in a session', async () => {
      const recording = await loadTestRecording('session-5-jumps.json');
      
      for (const sample of recording.samples) {
        detector.processSample(sample);
      }
      
      const jumps = detector.getDetectedJumps();
      
      expect(jumps.length).toBeGreaterThanOrEqual(4); // Allow 1 miss
      expect(jumps.length).toBeLessThanOrEqual(6);    // Allow 1 false positive
    });
  });
  
  describe('Height Estimation', () => {
    it('should estimate height within acceptable error margin', () => {
      // Test case: 2.5s airtime should give ~7.6m height
      // h = 0.5 * g * (t/2)^2 = 0.5 * 9.81 * 1.25^2 = 7.66m
      
      const airtime = 2.5;
      const expectedHeight = 7.66;
      
      const estimator = new HeightEstimator();
      const height = estimator.estimateFromAirtime(airtime);
      
      expect(height).toBeCloseTo(expectedHeight, 1); // ±0.1m
    });
  });
  
  describe('Rotation Detection', () => {
    it('should detect rotation when gyro values exceed threshold', async () => {
      const recording = await loadTestRecording('frontloop-jump.json');
      
      for (const sample of recording.samples) {
        detector.processSample(sample);
      }
      
      const jumps = detector.getDetectedJumps();
      
      expect(jumps).toHaveLength(1);
      expect(jumps[0].rotationDetected).toBe(true);
    });
  });
});
```

### watchOS Unit Tests (Swift)

```swift
// apps/watchos/Tests/JumpDetectorTests.swift
import XCTest
@testable import iSurf_Watch

class JumpDetectorTests: XCTestCase {
    var detector: JumpDetector!
    
    override func setUp() {
        super.setUp()
        detector = JumpDetector()
        detector.currentSpeed = 10.0 // 10 m/s
    }
    
    func testJumpDetectionWithRealData() throws {
        // Load test recording
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: "real-jump-2.8s", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let recording = try JSONDecoder().decode(IMURecording.self, from: data)
        
        // Process samples
        for sample in recording.samples {
            detector.processSample(sample)
        }
        
        // Verify jump detected
        XCTAssertEqual(detector.detectedJumps.count, 1)
        XCTAssertEqual(detector.detectedJumps[0].airtime, 2.8, accuracy: 0.1)
        XCTAssertGreaterThan(detector.detectedJumps[0].height, 3.0)
    }
    
    func testNoJumpWhenStationary() {
        detector.currentSpeed = 1.0 // Too slow
        
        let sample = IMUSample(
            timestamp: Date(),
            accelerationZ: 2.0, // Strong acceleration
            // ... other fields
        )
        
        detector.processSample(sample)
        
        XCTAssertEqual(detector.detectedJumps.count, 0)
    }
}
```

### Backend Unit Tests (NestJS)

```typescript
// services/api/src/modules/sessions/sessions.service.spec.ts
import { Test, TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { SessionsService } from './sessions.service';
import { Session } from './entities/session.entity';

describe('SessionsService', () => {
  let service: SessionsService;
  let mockRepository: any;
  
  beforeEach(async () => {
    mockRepository = {
      create: jest.fn(),
      save: jest.fn(),
      findOne: jest.fn(),
      createQueryBuilder: jest.fn(() => ({
        where: jest.fn().mockReturnThis(),
        orderBy: jest.fn().mockReturnThis(),
        getMany: jest.fn(),
        getRawOne: jest.fn(),
      })),
    };
    
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        SessionsService,
        {
          provide: getRepositoryToken(Session),
          useValue: mockRepository,
        },
      ],
    }).compile();
    
    service = module.get<SessionsService>(SessionsService);
  });
  
  describe('create', () => {
    it('should create a new session', async () => {
      const userId = 'user-123';
      const createDto = {
        sport: 'kiteboarding',
        startTime: new Date('2026-02-22T10:00:00Z'),
        endTime: new Date('2026-02-22T12:00:00Z'),
        // ... other fields
      };
      
      const savedSession = { id: 'session-456', ...createDto, userId };
      mockRepository.save.mockResolvedValue(savedSession);
      
      const result = await service.create(userId, createDto);
      
      expect(mockRepository.create).toHaveBeenCalledWith({
        ...createDto,
        userId,
      });
      expect(mockRepository.save).toHaveBeenCalled();
      expect(result).toEqual(savedSession);
    });
  });
  
  describe('getStats', () => {
    it('should calculate user statistics', async () => {
      const userId = 'user-123';
      const mockStats = {
        totalSessions: '25',
        totalDistance: '250.5',
        totalJumps: '150',
        bestJumpHeight: '12.5',
        maxSpeed: '45.2',
      };
      
      const queryBuilder = mockRepository.createQueryBuilder();
      queryBuilder.getRawOne.mockResolvedValue(mockStats);
      
      const result = await service.getStats(userId);
      
      expect(result).toEqual({
        totalSessions: 25,
        totalDistance: 250.5,
        totalJumps: 150,
        bestJumpHeight: 12.5,
        maxSpeed: 45.2,
      });
    });
  });
});
```

## Integration Tests

### Backend E2E Tests

```typescript
// services/api/test/sessions.e2e-spec.ts
import { Test } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';

describe('Sessions (e2e)', () => {
  let app: INestApplication;
  let authToken: string;
  
  beforeAll(async () => {
    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();
    
    app = moduleFixture.createNestApplication();
    app.useGlobalPipes(new ValidationPipe());
    await app.init();
    
    // Register test user and get token
    const registerResponse = await request(app.getHttpServer())
      .post('/api/v1/auth/register')
      .send({
        email: 'test@example.com',
        username: 'testuser',
        password: 'TestPassword123!',
      });
    
    authToken = registerResponse.body.accessToken;
  });
  
  afterAll(async () => {
    await app.close();
  });
  
  describe('POST /sessions', () => {
    it('should create a new session', () => {
      return request(app.getHttpServer())
        .post('/api/v1/sessions')
        .set('Authorization', `Bearer ${authToken}`)
        .send({
          sport: 'kiteboarding',
          startTime: '2026-02-22T10:00:00Z',
          endTime: '2026-02-22T12:00:00Z',
          distanceKm: 25.3,
          durationSec: 7200,
          maxSpeedKmh: 42.5,
          avgSpeedKmh: 18.2,
          jumpCount: 15,
          maxJumpHeightM: 8.5,
          totalAirtimeSec: 45.2,
          version: '1.0',
          watchType: 'apple',
          appVersion: '1.0.0',
        })
        .expect(201)
        .expect((res) => {
          expect(res.body).toHaveProperty('id');
          expect(res.body.sport).toBe('kiteboarding');
          expect(res.body.jumpCount).toBe(15);
        });
    });
    
    it('should reject invalid session data', () => {
      return request(app.getHttpServer())
        .post('/api/v1/sessions')
        .set('Authorization', `Bearer ${authToken}`)
        .send({
          sport: 'invalid_sport', // Invalid enum value
          startTime: 'not-a-date',
        })
        .expect(400);
    });
    
    it('should require authentication', () => {
      return request(app.getHttpServer())
        .post('/api/v1/sessions')
        .send({ /* valid data */ })
        .expect(401);
    });
  });
  
  describe('GET /sessions', () => {
    it('should return user sessions', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/v1/sessions')
        .set('Authorization', `Bearer ${authToken}`)
        .expect(200);
      
      expect(Array.isArray(response.body)).toBe(true);
    });
  });
});
```

## Sensor Replay Testing

### Recording Test Data

```typescript
// tools/sensor-replay/src/recorder.ts
import { IMUSample } from '@isurf/shared-types';

export interface RecordingMetadata {
  sport: string;
  duration: number;
  sampleRate: number;
  notes: string;
  knownJumps?: number;
  knownFalsePositives?: number;
}

export interface IMURecording {
  metadata: RecordingMetadata;
  samples: IMUSample[];
}

export class SensorRecorder {
  private samples: IMUSample[] = [];
  private startTime: Date | null = null;
  
  start(): void {
    this.startTime = new Date();
    this.samples = [];
    console.log('📹 Recording started...');
  }
  
  recordSample(sample: IMUSample): void {
    this.samples.push(sample);
  }
  
  stop(metadata: Partial<RecordingMetadata>): IMURecording {
    const duration = this.startTime 
      ? (Date.now() - this.startTime.getTime()) / 1000 
      : 0;
    
    const recording: IMURecording = {
      metadata: {
        sport: metadata.sport || 'kiteboarding',
        duration,
        sampleRate: this.samples.length / duration,
        notes: metadata.notes || '',
        knownJumps: metadata.knownJumps,
        knownFalsePositives: metadata.knownFalsePositives,
      },
      samples: this.samples,
    };
    
    console.log(`✅ Recording stopped. ${this.samples.length} samples captured.`);
    return recording;
  }
  
  export(filename: string, recording: IMURecording): void {
    const json = JSON.stringify(recording, null, 2);
    // Write to file (implementation depends on environment)
    console.log(`💾 Exported to ${filename}`);
  }
}
```

### Replay and Validation

```typescript
// tools/sensor-replay/src/player.ts
import { JumpDetector } from '@isurf/jump-detection';
import { IMURecording } from './recorder';

export interface ValidationResult {
  detectedJumps: number;
  expectedJumps: number;
  precision: number;      // True positives / (True positives + False positives)
  recall: number;         // True positives / (True positives + False negatives)
  f1Score: number;
  errors: string[];
}

export class SensorPlayer {
  async replay(recording: IMURecording): Promise<ValidationResult> {
    const detector = new JumpDetector();
    detector.updateSpeed(10); // Default speed
    
    console.log(`▶️  Replaying ${recording.samples.length} samples...`);
    
    for (let i = 0; i < recording.samples.length; i++) {
      const sample = recording.samples[i];
      detector.processSample(sample);
      
      // Simulate real-time with slight delay
      if (i % 100 === 0) {
        await this.sleep(1);
      }
    }
    
    const detectedJumps = detector.getDetectedJumps();
    const expectedJumps = recording.metadata.knownJumps || 0;
    
    // Calculate metrics
    const truePositives = Math.min(detectedJumps.length, expectedJumps);
    const falsePositives = Math.max(0, detectedJumps.length - expectedJumps);
    const falseNegatives = Math.max(0, expectedJumps - detectedJumps.length);
    
    const precision = truePositives / (truePositives + falsePositives) || 0;
    const recall = truePositives / (truePositives + falseNegatives) || 0;
    const f1Score = (2 * precision * recall) / (precision + recall) || 0;
    
    const result: ValidationResult = {
      detectedJumps: detectedJumps.length,
      expectedJumps,
      precision,
      recall,
      f1Score,
      errors: [],
    };
    
    if (precision < 0.9) {
      result.errors.push(`Low precision: ${(precision * 100).toFixed(1)}%`);
    }
    if (recall < 0.85) {
      result.errors.push(`Low recall: ${(recall * 100).toFixed(1)}%`);
    }
    
    return result;
  }
  
  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
  
  printResults(result: ValidationResult): void {
    console.log('\n📊 Validation Results:');
    console.log(`   Detected: ${result.detectedJumps}`);
    console.log(`   Expected: ${result.expectedJumps}`);
    console.log(`   Precision: ${(result.precision * 100).toFixed(1)}%`);
    console.log(`   Recall: ${(result.recall * 100).toFixed(1)}%`);
    console.log(`   F1 Score: ${(result.f1Score * 100).toFixed(1)}%`);
    
    if (result.errors.length > 0) {
      console.log('\n⚠️  Issues:');
      result.errors.forEach(err => console.log(`   - ${err}`));
    } else {
      console.log('\n✅ All metrics passed!');
    }
  }
}
```

## Mobile App E2E Tests (Detox)

```typescript
// apps/mobile/e2e/session-flow.e2e.ts
describe('Session Flow', () => {
  beforeAll(async () => {
    await device.launchApp();
  });
  
  beforeEach(async () => {
    await device.reloadReactNative();
  });
  
  it('should display session list', async () => {
    await element(by.id('sessions-tab')).tap();
    await expect(element(by.id('session-list'))).toBeVisible();
  });
  
  it('should show session details when tapped', async () => {
    await element(by.id('sessions-tab')).tap();
    await element(by.id('session-0')).tap();
    
    await expect(element(by.id('session-detail'))).toBeVisible();
    await expect(element(by.id('session-map'))).toBeVisible();
    await expect(element(by.id('jump-list'))).toBeVisible();
  });
  
  it('should display correct stats', async () => {
    await element(by.id('sessions-tab')).tap();
    await element(by.id('session-0')).tap();
    
    await expect(element(by.id('stat-distance'))).toHaveText('25.3 km');
    await expect(element(by.id('stat-jumps'))).toHaveText('15');
  });
});
```

## Test Data Fixtures

### Example Session Fixture

```json
// packages/shared-types/fixtures/session-example.json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "sport": "kiteboarding",
  "startTime": "2026-02-22T10:00:00Z",
  "endTime": "2026-02-22T12:00:00Z",
  "summary": {
    "distance": 25.3,
    "duration": 7200,
    "maxSpeed": 42.5,
    "avgSpeed": 18.2,
    "jumpCount": 3,
    "maxJumpHeight": 8.5,
    "totalAirtime": 12.5
  },
  "jumps": [
    {
      "id": "jump-1",
      "startTime": "2026-02-22T10:15:00Z",
      "endTime": "2026-02-22T10:15:02.8Z",
      "airtime": 2.8,
      "height": 8.5,
      "confidence": 95,
      "rotationDetected": true
    }
  ],
  "metadata": {
    "version": "1.0",
    "watchType": "apple",
    "appVersion": "1.0.0",
    "synced": false
  }
}
```

## Development Checklist

### Unit Tests
- [ ] Write jump detection tests with fixtures
- [ ] Test height estimation accuracy
- [ ] Test false positive filtering
- [ ] Test rotation detection
- [ ] Achieve >80% code coverage

### Integration Tests
- [ ] Write backend API tests
- [ ] Test database operations
- [ ] Test authentication flow
- [ ] Test session CRUD operations

### Sensor Replay
- [ ] Implement SensorRecorder
- [ ] Implement SensorPlayer
- [ ] Record 10+ test sessions
- [ ] Validate algorithm performance

### E2E Tests
- [ ] Set up Detox for mobile app
- [ ] Write session list tests
- [ ] Write session detail tests
- [ ] Test offline sync

### CI/CD
- [ ] Add test step to GitHub Actions
- [ ] Run tests on every PR
- [ ] Enforce minimum coverage (80%)
- [ ] Block merge if tests fail

---

**Next Steps**: Review security and privacy considerations (`11_security_privacy.md`).
