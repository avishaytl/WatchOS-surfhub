# 11 - Security & Privacy

## Overview

iSurf handles sensitive user data (location, activity patterns) and must prioritize security and privacy. This document covers data protection, authentication security, and privacy best practices.

## Privacy Principles

### 1. Data Minimization
**Collect only what's necessary for the core functionality.**

✅ **What we collect**:
- GPS location (only during active sessions)
- IMU sensor data (only during detected jumps)
- User email and password (hashed)
- Session statistics

❌ **What we DON'T collect**:
- Background location tracking
- Contacts or photos
- Browsing history
- Third-party analytics (without consent)
- Advertising IDs

### 2. User Control
**Users own and control their data.**

- **Local-First**: All sessions stored locally before cloud sync
- **Optional Sync**: Cloud backup is opt-in
- **Export**: Users can export all data (JSON, GPX)
- **Delete**: Account deletion removes all data permanently
- **Privacy Settings**: Control session visibility (public/private)

### 3. Transparency
**Clear communication about data usage.**

- **Privacy Policy**: Plain language, no legalese
- **Data Map**: Show what data is stored where
- **Permissions**: Explain why each permission is needed
- **Changes**: Notify users of privacy policy updates

## Authentication Security

### Password Security

#### Requirements
```typescript
// Minimum password requirements
const PASSWORD_RULES = {
  minLength: 8,
  requireUppercase: true,
  requireLowercase: true,
  requireNumber: true,
  requireSpecialChar: false, // Optional for better UX
};

function validatePassword(password: string): boolean {
  if (password.length < PASSWORD_RULES.minLength) return false;
  if (PASSWORD_RULES.requireUppercase && !/[A-Z]/.test(password)) return false;
  if (PASSWORD_RULES.requireLowercase && !/[a-z]/.test(password)) return false;
  if (PASSWORD_RULES.requireNumber && !/[0-9]/.test(password)) return false;
  return true;
}
```

#### Hashing (bcrypt)
```typescript
// services/api/src/modules/auth/auth.service.ts
import * as bcrypt from 'bcrypt';

const SALT_ROUNDS = 10; // Balance between security and performance

async function hashPassword(password: string): Promise<string> {
  return bcrypt.hash(password, SALT_ROUNDS);
}

async function comparePassword(password: string, hash: string): Promise<boolean> {
  return bcrypt.compare(password, hash);
}
```

### JWT Token Security

#### Access Token (Short-lived)
```typescript
// services/api/src/modules/auth/jwt.config.ts
export const jwtConfig = {
  secret: process.env.JWT_SECRET, // Min 64 characters, random
  expiresIn: '7d',                // 7 days
  algorithm: 'HS256',
};

// Payload structure (minimal data)
interface JwtPayload {
  sub: string;      // User ID
  iat: number;      // Issued at
  exp: number;      // Expiration
  // DO NOT include sensitive data (email, password, etc.)
}
```

#### Refresh Token (Long-lived)
```typescript
export const refreshTokenConfig = {
  secret: process.env.JWT_REFRESH_SECRET, // Different from access secret
  expiresIn: '30d',                       // 30 days
  algorithm: 'HS256',
};

// Store refresh tokens in database for revocation
@Entity('refresh_tokens')
export class RefreshToken {
  @PrimaryGeneratedColumn('uuid')
  id: string;
  
  @Column('uuid')
  userId: string;
  
  @Column()
  token: string; // Hashed
  
  @Column()
  expiresAt: Date;
  
  @Column({ default: false })
  revoked: boolean;
  
  @CreateDateColumn()
  createdAt: Date;
}
```

### Secure Token Storage (Mobile)

#### iOS (Keychain)
```swift
// apps/mobile/ios/iSurf/KeychainManager.swift
import Security

class KeychainManager {
    static func saveToken(_ token: String, forKey key: String) -> Bool {
        let data = token.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        SecItemDelete(query as CFDictionary) // Delete existing
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    static func loadToken(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return token
    }
}
```

#### Android (EncryptedSharedPreferences)
```kotlin
// apps/mobile/android/app/src/main/java/.../ SecureStorage.kt
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class SecureStorage(context: Context) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()
    
    private val sharedPreferences = EncryptedSharedPreferences.create(
        context,
        "isurf_secure_prefs",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )
    
    fun saveToken(key: String, token: String) {
        sharedPreferences.edit().putString(key, token).apply()
    }
    
    fun loadToken(key: String): String? {
        return sharedPreferences.getString(key, null)
    }
}
```

## Data Encryption

### In Transit (HTTPS)

#### API Configuration
```typescript
// services/api/src/main.ts
import * as helmet from 'helmet';

// Force HTTPS in production
if (process.env.NODE_ENV === 'production') {
  app.use((req, res, next) => {
    if (req.header('x-forwarded-proto') !== 'https') {
      res.redirect(`https://${req.header('host')}${req.url}`);
    } else {
      next();
    }
  });
}

// Security headers
app.use(helmet({
  hsts: {
    maxAge: 31536000, // 1 year
    includeSubDomains: true,
    preload: true,
  },
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
    },
  },
}));
```

### At Rest (Database)

#### PostgreSQL Encryption
```sql
-- Enable transparent data encryption (TDE)
-- Note: Implementation varies by hosting provider

-- AWS RDS: Enable encryption when creating instance
-- Or for existing database:
-- 1. Create encrypted snapshot
-- 2. Restore from encrypted snapshot

-- Encrypt sensitive columns (optional additional layer)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Example: Encrypt user email (if required by regulations)
ALTER TABLE users 
  ADD COLUMN email_encrypted BYTEA;

UPDATE users 
  SET email_encrypted = pgp_sym_encrypt(email, 'encryption_key');
```

#### Mobile Database (Realm/WatermelonDB)
```typescript
// apps/mobile/src/services/database/database.ts
import { Database } from '@nozbe/watermelondb';
import SQLiteAdapter from '@nozbe/watermelondb/adapters/sqlite';

const adapter = new SQLiteAdapter({
  schema,
  dbName: 'isurf',
  // Enable encryption (iOS: SQLCipher, Android: net.sqlcipher)
  jsi: true,
  // Android only:
  // dbPass: 'encryption_key_from_keystore',
});
```

## API Security

### Rate Limiting

```typescript
// services/api/src/common/guards/rate-limit.guard.ts
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';

// Module configuration
ThrottlerModule.forRoot({
  ttl: 60,        // Time window in seconds
  limit: 100,     // Max requests per ttl
}),

// Apply to sensitive endpoints
@Controller('auth')
@UseGuards(ThrottlerGuard)
export class AuthController {
  @Post('login')
  @Throttle(5, 60) // Max 5 login attempts per minute
  async login(@Body() loginDto: LoginDto) {
    // ...
  }
}
```

### Input Validation

```typescript
// services/api/src/modules/sessions/dto/create-session.dto.ts
import { IsString, IsEnum, IsNumber, IsDateString, Min, Max, IsOptional } from 'class-validator';
import { Sport } from '@isurf/shared-types';

export class CreateSessionDto {
  @IsEnum(Sport)
  sport: Sport;
  
  @IsDateString()
  startTime: string;
  
  @IsDateString()
  endTime: string;
  
  @IsNumber()
  @Min(0)
  @Max(1000) // Sanity check
  distanceKm: number;
  
  @IsNumber()
  @Min(0)
  @Max(86400) // Max 24 hours
  durationSec: number;
  
  @IsString()
  @IsOptional()
  notes?: string;
}
```

### SQL Injection Prevention

```typescript
// GOOD: TypeORM parameterized queries (safe)
const sessions = await this.sessionsRepository
  .createQueryBuilder('session')
  .where('session.userId = :userId', { userId }) // Parameterized
  .andWhere('session.sport = :sport', { sport })
  .getMany();

// BAD: String concatenation (vulnerable)
// const query = `SELECT * FROM sessions WHERE userId = '${userId}'`; // NEVER DO THIS
```

### CORS Configuration

```typescript
// services/api/src/main.ts
app.enableCors({
  origin: process.env.CORS_ORIGIN?.split(',') || [
    'http://localhost:3000',
    'https://isurf.app',
  ],
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'],
  allowedHeaders: ['Content-Type', 'Authorization'],
});
```

## Privacy Compliance

### GDPR (EU Users)

#### Right to Access
```typescript
// GET /api/v1/users/me/export
async exportUserData(userId: string): Promise<any> {
  const user = await this.usersService.findById(userId);
  const sessions = await this.sessionsService.findAll(userId);
  const jumps = await this.jumpsService.findByUserId(userId);
  
  return {
    user: {
      email: user.email,
      username: user.username,
      createdAt: user.createdAt,
    },
    sessions: sessions.map(s => ({
      id: s.id,
      sport: s.sport,
      startTime: s.startTime,
      summary: s.summary,
      // Include all session data
    })),
    // Export as JSON (or offer GPX format)
  };
}
```

#### Right to Erasure (Right to be Forgotten)
```typescript
// DELETE /api/v1/users/me
async deleteAccount(userId: string): Promise<void> {
  // Cascade delete handles sessions, jumps, etc.
  await this.usersService.delete(userId);
  
  // Also invalidate all tokens
  await this.refreshTokensService.revokeAllForUser(userId);
  
  // Log deletion for audit (but don't store PII)
  await this.auditLog.log({
    action: 'account_deleted',
    userId: hashUserId(userId), // Anonymous hash
    timestamp: new Date(),
  });
}
```

#### Data Retention Policy
```typescript
// Auto-delete inactive accounts after 2 years (optional)
@Cron('0 0 * * *') // Daily at midnight
async cleanupInactiveAccounts() {
  const twoYearsAgo = new Date();
  twoYearsAgo.setFullYear(twoYearsAgo.getFullYear() - 2);
  
  const inactiveUsers = await this.usersService.findInactiveUsers(twoYearsAgo);
  
  for (const user of inactiveUsers) {
    // Send warning email first (30 days before deletion)
    // Then delete if still inactive
  }
}
```

### CCPA (California Users)

Similar requirements to GDPR:
- Right to know what data is collected
- Right to delete
- Right to opt-out of data "sale" (N/A for iSurf - we don't sell data)

### Privacy Policy Template

```markdown
# iSurf Privacy Policy

**Last Updated**: February 22, 2026

## What Data We Collect

- **Location Data**: Only during active surf sessions
- **Sensor Data**: Accelerometer and gyroscope during jumps
- **Account Data**: Email, username, password (encrypted)
- **Session Data**: Statistics from your sessions

## How We Use Your Data

- Display your session analytics
- Sync across your devices
- Improve jump detection accuracy (anonymized)

## What We DON'T Do

- ❌ Track your location outside of sessions
- ❌ Sell your data to third parties
- ❌ Show ads based on your activity
- ❌ Share your data without permission

## Your Rights

- **Access**: Export all your data (JSON or GPX)
- **Delete**: Permanently delete your account and all data
- **Control**: Make sessions public or private

## Data Storage

- **Your Phone**: Primary storage (encrypted)
- **Our Servers**: Optional backup (encrypted in transit and at rest)
- **Retention**: Data kept until you delete it or your account

## Contact

Questions? Email: privacy@isurf.app
```

## Security Best Practices

### Checklist

#### Authentication
- [ ] Passwords hashed with bcrypt (min 10 rounds)
- [ ] JWT tokens stored securely (Keychain/Keystore)
- [ ] Refresh tokens revokable in database
- [ ] Rate limiting on login endpoint (5 attempts/minute)
- [ ] Account lockout after 5 failed attempts

#### Data Protection
- [ ] HTTPS enforced in production
- [ ] Database encryption enabled
- [ ] Sensitive data never logged
- [ ] Secrets stored in environment variables (never in code)
- [ ] API keys rotated regularly

#### Mobile App
- [ ] Certificate pinning (optional, advanced)
- [ ] Root/jailbreak detection (optional)
- [ ] Biometric authentication option
- [ ] Session timeout after inactivity

#### Backend
- [ ] SQL injection protection (parameterized queries)
- [ ] XSS protection (helmet middleware)
- [ ] CSRF protection (for web, N/A for API-only)
- [ ] Input validation on all endpoints
- [ ] Error messages don't leak sensitive info

#### Privacy
- [ ] Privacy policy published and accessible
- [ ] Consent for data collection (during onboarding)
- [ ] Data export functionality
- [ ] Account deletion functionality
- [ ] Minimal data collection

## Incident Response Plan

### Data Breach Protocol

1. **Detection**: Monitor for unusual activity (failed logins, mass data access)
2. **Containment**: Immediately revoke affected tokens, reset passwords
3. **Assessment**: Determine scope (how many users, what data)
4. **Notification**: Inform affected users within 72 hours (GDPR requirement)
5. **Remediation**: Fix vulnerability, enhance monitoring
6. **Documentation**: Write post-mortem, update security measures

### Security Contact

Create `security.txt` (RFC 9116):
```
# /.well-known/security.txt
Contact: mailto:security@isurf.app
Expires: 2027-12-31T23:59:59Z
Preferred-Languages: en
```

## Development Checklist

### Authentication & Authorization
- [ ] Implement bcrypt password hashing
- [ ] Set up JWT with refresh tokens
- [ ] Add token revocation in database
- [ ] Implement rate limiting
- [ ] Add secure token storage (mobile)

### Data Encryption
- [ ] Enable HTTPS in production
- [ ] Configure database encryption
- [ ] Encrypt mobile database (optional)
- [ ] Use secure secrets management

### API Security
- [ ] Add input validation on all endpoints
- [ ] Implement rate limiting
- [ ] Set up CORS properly
- [ ] Add helmet middleware
- [ ] Test for common vulnerabilities (OWASP Top 10)

### Privacy Compliance
- [ ] Write privacy policy
- [ ] Implement data export
- [ ] Implement account deletion
- [ ] Add consent flow during onboarding
- [ ] Document data retention policy

### Monitoring
- [ ] Set up error tracking (Sentry)
- [ ] Monitor failed login attempts
- [ ] Alert on unusual API activity
- [ ] Regular security audits

---

**Next Steps**: Review the product roadmap (`12_roadmap.md`) to plan MVP and future features.
