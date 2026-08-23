# 09 - Docker & DevOps

## Overview

This document covers local development setup with Docker, deployment strategies, and DevOps best practices for the SPOTEQ backend.

## Docker Setup

### Docker Compose for Local Development

```yaml
# docker-compose.yml
version: '3.8'

services:
  # PostgreSQL Database
  postgres:
    image: postgres:15-alpine
    container_name: spoteq-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: spoteq
      POSTGRES_PASSWORD: dev_password_change_in_prod
      POSTGRES_DB: spoteq
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./migrations/init.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U spoteq"]
      interval: 10s
      timeout: 5s
      retries: 5
  
  # Redis (optional, for caching and rate limiting)
  redis:
    image: redis:7-alpine
    container_name: spoteq-redis
    restart: unless-stopped
    ports:
      - "6379:6379"
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5
  
  # API Service
  api:
    build:
      context: ./services/api
      dockerfile: Dockerfile
      target: development
    container_name: spoteq-api
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      NODE_ENV: development
      DB_HOST: postgres
      DB_PORT: 5432
      DB_USERNAME: spoteq
      DB_PASSWORD: dev_password_change_in_prod
      DB_DATABASE: spoteq
      REDIS_HOST: redis
      REDIS_PORT: 6379
      JWT_SECRET: dev_jwt_secret_change_in_production
      JWT_REFRESH_SECRET: dev_refresh_secret_change_in_production
    volumes:
      - ./services/api/src:/app/src
      - ./services/api/node_modules:/app/node_modules
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    command: npm run start:dev

volumes:
  postgres_data:
  redis_data:

networks:
  default:
    name: spoteq-network
```

### API Dockerfile

```dockerfile
# services/api/Dockerfile

# ---- Base Stage ----
FROM node:20-alpine AS base
WORKDIR /app
RUN apk add --no-cache dumb-init

# ---- Dependencies Stage ----
FROM base AS dependencies
COPY package*.json ./
RUN npm ci --only=production && \
    npm cache clean --force
# Copy production node_modules aside
RUN cp -R node_modules /tmp/node_modules
# Install all dependencies (including dev)
RUN npm ci

# ---- Build Stage ----
FROM dependencies AS build
COPY . .
RUN npm run build

# ---- Development Stage ----
FROM base AS development
COPY package*.json ./
RUN npm install
COPY . .
EXPOSE 3000
CMD ["npm", "run", "start:dev"]

# ---- Production Stage ----
FROM base AS production
ENV NODE_ENV=production
COPY --from=build /app/dist ./dist
COPY --from=dependencies /tmp/node_modules ./node_modules
COPY package*.json ./

EXPOSE 3000
USER node
CMD ["dumb-init", "node", "dist/main.js"]
```

### .dockerignore

```
# services/api/.dockerignore
node_modules
npm-debug.log
dist
.git
.env
.env.local
.env.*.local
coverage
.vscode
.idea
*.md
Dockerfile
docker-compose.yml
```

## Environment Management

### Development Environment (.env.development)

```bash
NODE_ENV=development
PORT=3000

DB_HOST=localhost
DB_PORT=5432
DB_USERNAME=spoteq
DB_PASSWORD=dev_password
DB_DATABASE=spoteq
DB_SYNCHRONIZE=true  # Auto-sync schema (dev only!)
DB_LOGGING=true

JWT_SECRET=dev_jwt_secret_min_32_characters_long
JWT_EXPIRATION=7d
JWT_REFRESH_SECRET=dev_refresh_secret_min_32_characters
JWT_REFRESH_EXPIRATION=30d

CORS_ORIGIN=http://localhost:3000,spoteq://

LOG_LEVEL=debug
```

### Production Environment (.env.production - example)

```bash
NODE_ENV=production
PORT=3000

DB_HOST=your-rds-endpoint.region.rds.amazonaws.com
DB_PORT=5432
DB_USERNAME=spoteq_prod
DB_PASSWORD=<SECURE_PASSWORD_FROM_SECRETS_MANAGER>
DB_DATABASE=spoteq_prod
DB_SYNCHRONIZE=false  # NEVER true in production!
DB_LOGGING=false
DB_SSL=true

JWT_SECRET=<SECURE_RANDOM_STRING_MIN_64_CHARS>
JWT_EXPIRATION=7d
JWT_REFRESH_SECRET=<DIFFERENT_SECURE_RANDOM_STRING>
JWT_REFRESH_EXPIRATION=30d

CORS_ORIGIN=https://spoteq.app,spoteq://

REDIS_HOST=your-redis-endpoint.cache.amazonaws.com
REDIS_PORT=6379
REDIS_TLS=true

LOG_LEVEL=info

# Optional: Sentry for error tracking
SENTRY_DSN=https://...@sentry.io/...
```

## Development Scripts

### Start Development Environment

```bash
#!/bin/bash
# scripts/dev-start.sh

echo "🚀 Starting SPOTEQ development environment..."

# Check Docker is running
if ! docker info > /dev/null 2>&1; then
  echo "❌ Docker is not running. Please start Docker Desktop."
  exit 1
fi

# Start services
docker-compose up -d

# Wait for API to be healthy
echo "⏳ Waiting for API to be ready..."
until curl -sf http://localhost:3000/api/v1/health > /dev/null; do
  sleep 2
done

echo "✅ Development environment is ready!"
echo "📚 API docs: http://localhost:3000/api/docs"
echo "🗄️  PostgreSQL: localhost:5432"
echo "🔴 Redis: localhost:6379"
```

### Database Reset Script

```bash
#!/bin/bash
# scripts/db-reset.sh

echo "⚠️  This will delete all data in the database!"
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

# Stop API to prevent connections
docker-compose stop api

# Drop and recreate database
docker-compose exec postgres psql -U spoteq -c "DROP DATABASE IF EXISTS spoteq;"
docker-compose exec postgres psql -U spoteq -c "CREATE DATABASE spoteq;"

# Run migrations
cd services/api
npm run migration:run

echo "✅ Database reset complete!"

# Restart API
docker-compose start api
```

## Database Migrations

### Migration Scripts

```json
// services/api/package.json
{
  "scripts": {
    "migration:create": "typeorm migration:create",
    "migration:generate": "typeorm migration:generate -d src/config/typeorm.config.ts",
    "migration:run": "typeorm migration:run -d src/config/typeorm.config.ts",
    "migration:revert": "typeorm migration:revert -d src/config/typeorm.config.ts",
    "schema:sync": "typeorm schema:sync -d src/config/typeorm.config.ts",
    "schema:drop": "typeorm schema:drop -d src/config/typeorm.config.ts"
  }
}
```

### Initial Migration Example

```typescript
// services/api/migrations/1708617600000-InitialSchema.ts
import { MigrationInterface, QueryRunner } from 'typeorm';

export class InitialSchema1708617600000 implements MigrationInterface {
  name = 'InitialSchema1708617600000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    // Create users table
    await queryRunner.query(`
      CREATE TABLE "users" (
        "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        "email" varchar UNIQUE NOT NULL,
        "username" varchar UNIQUE NOT NULL,
        "password" varchar NOT NULL,
        "first_name" varchar,
        "last_name" varchar,
        "avatar_url" varchar,
        "bio" text,
        "units" varchar(10) DEFAULT 'metric',
        "profile_public" boolean DEFAULT false,
        "sessions_public" boolean DEFAULT false,
        "total_sessions" integer DEFAULT 0,
        "total_distance" decimal(10,2) DEFAULT 0,
        "total_jumps" integer DEFAULT 0,
        "best_jump_height" decimal(6,2) DEFAULT 0,
        "created_at" timestamptz DEFAULT now(),
        "updated_at" timestamptz DEFAULT now(),
        "last_login_at" timestamptz
      )
    `);

    // Create sessions table
    await queryRunner.query(`
      CREATE TABLE "sessions" (
        "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        "user_id" uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        "sport" varchar(20) NOT NULL,
        "start_time" timestamptz NOT NULL,
        "end_time" timestamptz NOT NULL,
        "distance_km" decimal(10,2),
        "duration_sec" integer,
        "max_speed_kmh" decimal(6,2),
        "avg_speed_kmh" decimal(6,2),
        "jump_count" integer DEFAULT 0,
        "max_jump_height_m" decimal(6,2) DEFAULT 0,
        "total_airtime_sec" decimal(10,2) DEFAULT 0,
        "version" varchar(10) DEFAULT '1.0',
        "watch_type" varchar(10),
        "app_version" varchar(20),
        "timezone" varchar(50),
        "notes" text,
        "location" varchar,
        "created_at" timestamptz DEFAULT now(),
        "updated_at" timestamptz DEFAULT now()
      )
    `);

    // Create indexes
    await queryRunner.query(`
      CREATE INDEX "idx_sessions_user_start" ON "sessions" ("user_id", "start_time" DESC)
    `);
    await queryRunner.query(`
      CREATE INDEX "idx_sessions_sport" ON "sessions" ("sport")
    `);

    // Create jumps table
    await queryRunner.query(`
      CREATE TABLE "jumps" (
        "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        "session_id" uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        "start_time" timestamptz NOT NULL,
        "end_time" timestamptz NOT NULL,
        "airtime" decimal(6,3),
        "height_m" decimal(6,2),
        "max_vertical_velocity" decimal(6,2),
        "takeoff_speed_kmh" decimal(6,2),
        "landing_speed_kmh" decimal(6,2),
        "confidence" integer,
        "rotation_detected" boolean DEFAULT false,
        "takeoff_location" jsonb,
        "landing_location" jsonb
      )
    `);

    await queryRunner.query(`
      CREATE INDEX "idx_jumps_session" ON "jumps" ("session_id")
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE "jumps"`);
    await queryRunner.query(`DROP TABLE "sessions"`);
    await queryRunner.query(`DROP TABLE "users"`);
  }
}
```

## Health Check Endpoint

```typescript
// src/modules/health/health.controller.ts
import { Controller, Get } from '@nestjs/common';
import { HealthCheck, HealthCheckService, TypeOrmHealthIndicator } from '@nestjs/terminus';

@Controller('health')
export class HealthController {
  constructor(
    private health: HealthCheckService,
    private db: TypeOrmHealthIndicator,
  ) {}

  @Get()
  @HealthCheck()
  check() {
    return this.health.check([
      () => this.db.pingCheck('database'),
    ]);
  }
}
```

## Production Deployment

### AWS ECS Deployment (Example)

**Task Definition** (simplified):
```json
{
  "family": "spoteq-api",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "containerDefinitions": [
    {
      "name": "api",
      "image": "<AWS_ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/spoteq-api:latest",
      "portMappings": [
        {
          "containerPort": 3000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "NODE_ENV",
          "value": "production"
        }
      ],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:region:account:secret:spoteq/db/password"
        },
        {
          "name": "JWT_SECRET",
          "valueFrom": "arn:aws:secretsmanager:region:account:secret:spoteq/jwt/secret"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/spoteq-api",
          "awslogs-region": "us-west-2",
          "awslogs-stream-prefix": "api"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
```

### CI/CD Pipeline (GitHub Actions)

```yaml
# .github/workflows/deploy-api.yml
name: Deploy API

on:
  push:
    branches: [main]
    paths:
      - 'services/api/**'

env:
  AWS_REGION: us-west-2
  ECR_REPOSITORY: spoteq-api
  ECS_SERVICE: spoteq-api-service
  ECS_CLUSTER: spoteq-cluster

jobs:
  deploy:
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
      
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}
      
      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v1
      
      - name: Build and push Docker image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          cd services/api
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
                       -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
                       --target production .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest
      
      - name: Run database migrations
        env:
          DB_HOST: ${{ secrets.PROD_DB_HOST }}
          DB_PASSWORD: ${{ secrets.PROD_DB_PASSWORD }}
        run: |
          cd services/api
          npm ci
          npm run migration:run
      
      - name: Deploy to ECS
        run: |
          aws ecs update-service \
            --cluster $ECS_CLUSTER \
            --service $ECS_SERVICE \
            --force-new-deployment
```

## Monitoring & Logging

### Logging Configuration

```typescript
// src/config/logger.config.ts
import { WinstonModule } from 'nest-winston';
import * as winston from 'winston';

export const loggerConfig = WinstonModule.createLogger({
  transports: [
    new winston.transports.Console({
      format: winston.format.combine(
        winston.format.timestamp(),
        winston.format.colorize(),
        winston.format.printf(({ timestamp, level, message, context, trace }) => {
          return `${timestamp} [${context}] ${level}: ${message}${trace ? `\n${trace}` : ''}`;
        }),
      ),
    }),
    new winston.transports.File({
      filename: 'logs/error.log',
      level: 'error',
      format: winston.format.combine(
        winston.format.timestamp(),
        winston.format.json(),
      ),
    }),
    new winston.transports.File({
      filename: 'logs/combined.log',
      format: winston.format.combine(
        winston.format.timestamp(),
        winston.format.json(),
      ),
    }),
  ],
});
```

### Error Tracking (Sentry)

```typescript
// src/main.ts
import * as Sentry from '@sentry/node';

if (process.env.NODE_ENV === 'production') {
  Sentry.init({
    dsn: process.env.SENTRY_DSN,
    environment: process.env.NODE_ENV,
    tracesSampleRate: 0.1,
  });
}
```

## Backup Strategy

### Automated PostgreSQL Backups

```bash
#!/bin/bash
# scripts/backup-db.sh

BACKUP_DIR="/backups/postgres"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/spoteq_$TIMESTAMP.sql.gz"

# Create backup
docker-compose exec -T postgres pg_dump -U spoteq spoteq | gzip > "$BACKUP_FILE"

# Delete backups older than 30 days
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +30 -delete

echo "✅ Backup created: $BACKUP_FILE"
```

**Cron job** (run daily at 2 AM):
```bash
0 2 * * * /path/to/scripts/backup-db.sh >> /var/log/spoteq-backup.log 2>&1
```

## Development Checklist

### Docker Setup
- [ ] Create docker-compose.yml
- [ ] Create Dockerfile for API
- [ ] Add .dockerignore
- [ ] Test local development environment

### Database
- [ ] Set up PostgreSQL in Docker
- [ ] Create initial migration
- [ ] Add migration scripts to package.json
- [ ] Test migration rollback

### Environment Configuration
- [ ] Create .env.example
- [ ] Set up environment-specific configs
- [ ] Add validation for required env vars
- [ ] Document all environment variables

### Scripts
- [ ] Create dev-start.sh
- [ ] Create db-reset.sh
- [ ] Create backup-db.sh
- [ ] Add script permissions (chmod +x)

### Deployment
- [ ] Set up ECR repository (if using AWS)
- [ ] Create ECS task definition
- [ ] Configure CI/CD pipeline
- [ ] Test production build locally

### Monitoring
- [ ] Add health check endpoint
- [ ] Configure logging
- [ ] Set up error tracking (Sentry)
- [ ] Add performance monitoring (optional)

---

**Next Steps**: Set up testing infrastructure (`10_testing.md`).
