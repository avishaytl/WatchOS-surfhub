# 08 - Backend API

## Overview

The backend API provides user authentication, session storage, and multi-device sync. Built with Node.js and NestJS, it follows REST principles with JWT authentication.

## Tech Stack

- **Framework**: NestJS 10+ (opinionated, production-ready)
- **Database**: PostgreSQL 15+
- **ORM**: TypeORM
- **Authentication**: Passport + JWT
- **Validation**: class-validator
- **Documentation**: Swagger/OpenAPI
- **Cache**: Redis (optional, for rate limiting)
- **Deployment**: Docker

## Project Setup

### Initialize NestJS Project

```bash
cd services
npx @nestjs/cli new api
cd api

# Install dependencies
npm install --save \
  @nestjs/typeorm typeorm pg \
  @nestjs/passport passport passport-jwt \
  @nestjs/jwt \
  @nestjs/config \
  @nestjs/swagger \
  class-validator class-transformer \
  bcrypt \
  compression \
  helmet

npm install --save-dev \
  @types/passport-jwt \
  @types/bcrypt
```

### Project Structure

```
services/api/
├── src/
│   ├── main.ts
│   ├── app.module.ts
│   │
│   ├── modules/
│   │   ├── auth/
│   │   │   ├── auth.controller.ts
│   │   │   ├── auth.service.ts
│   │   │   ├── auth.module.ts
│   │   │   ├── jwt.strategy.ts
│   │   │   ├── dto/
│   │   │   │   ├── login.dto.ts
│   │   │   │   └── register.dto.ts
│   │   │   └── guards/
│   │   │       └── jwt-auth.guard.ts
│   │   │
│   │   ├── users/
│   │   │   ├── users.controller.ts
│   │   │   ├── users.service.ts
│   │   │   ├── users.module.ts
│   │   │   ├── entities/
│   │   │   │   └── user.entity.ts
│   │   │   └── dto/
│   │   │       └── update-user.dto.ts
│   │   │
│   │   └── sessions/
│   │       ├── sessions.controller.ts
│   │       ├── sessions.service.ts
│   │       ├── sessions.module.ts
│   │       ├── entities/
│   │       │   ├── session.entity.ts
│   │       │   ├── jump.entity.ts
│   │       │   └── gps-track.entity.ts
│   │       └── dto/
│   │           ├── create-session.dto.ts
│   │           └── update-session.dto.ts
│   │
│   ├── common/
│   │   ├── guards/
│   │   ├── interceptors/
│   │   ├── filters/
│   │   └── decorators/
│   │       └── current-user.decorator.ts
│   │
│   ├── config/
│   │   ├── database.config.ts
│   │   └── jwt.config.ts
│   │
│   └── utils/
│       └── compression.util.ts
│
├── test/
├── migrations/
├── .env.example
├── Dockerfile
├── docker-compose.yml
└── package.json
```

## Configuration

### Environment Variables

```bash
# .env.example
NODE_ENV=development
PORT=3000

# Database
DB_HOST=localhost
DB_PORT=5432
DB_USERNAME=spoteq
DB_PASSWORD=your_secure_password
DB_DATABASE=spoteq

# JWT
JWT_SECRET=your_jwt_secret_key_change_in_production
JWT_EXPIRATION=7d
JWT_REFRESH_SECRET=your_refresh_token_secret
JWT_REFRESH_EXPIRATION=30d

# CORS
CORS_ORIGIN=http://localhost:3000,spoteq://

# Rate Limiting
RATE_LIMIT_TTL=60
RATE_LIMIT_MAX=100

# Redis (optional)
REDIS_HOST=localhost
REDIS_PORT=6379
```

### Main Application

```typescript
// src/main.ts
import { NestFactory } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import { SwaggerModule, DocumentBuilder } from '@nestjs/swagger';
import helmet from 'helmet';
import * as compression from 'compression';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  
  // Security
  app.use(helmet());
  app.enableCors({
    origin: process.env.CORS_ORIGIN?.split(',') || '*',
    credentials: true,
  });
  
  // Compression
  app.use(compression());
  
  // Global validation pipe
  app.useGlobalPipes(new ValidationPipe({
    whitelist: true,
    forbidNonWhitelisted: true,
    transform: true,
  }));
  
  // API prefix
  app.setGlobalPrefix('api/v1');
  
  // Swagger documentation
  const config = new DocumentBuilder()
    .setTitle('SPOTEQ API')
    .setDescription('Wind sports tracker API')
    .setVersion('1.0')
    .addBearerAuth()
    .build();
  const document = SwaggerModule.createDocument(app, config);
  SwaggerModule.setup('api/docs', app, document);
  
  const port = process.env.PORT || 3000;
  await app.listen(port);
  console.log(`🚀 Server running on http://localhost:${port}`);
  console.log(`📚 API docs available at http://localhost:${port}/api/docs`);
}

bootstrap();
```

## Database Entities

### User Entity

```typescript
// src/modules/users/entities/user.entity.ts
import { Entity, PrimaryGeneratedColumn, Column, OneToMany, CreateDateColumn, UpdateDateColumn } from 'typeorm';
import { Exclude } from 'class-transformer';
import { Session } from '../../sessions/entities/session.entity';

@Entity('users')
export class User {
  @PrimaryGeneratedColumn('uuid')
  id: string;
  
  @Column({ unique: true })
  email: string;
  
  @Column({ unique: true })
  username: string;
  
  @Column()
  @Exclude() // Don't expose password in API responses
  password: string;
  
  @Column({ nullable: true })
  firstName?: string;
  
  @Column({ nullable: true })
  lastName?: string;
  
  @Column({ nullable: true })
  avatarUrl?: string;
  
  @Column({ nullable: true })
  bio?: string;
  
  @Column({ type: 'enum', enum: ['metric', 'imperial'], default: 'metric' })
  units: string;
  
  @Column({ default: false })
  profilePublic: boolean;
  
  @Column({ default: false })
  sessionsPublic: boolean;
  
  // Cached stats (updated via triggers or batch jobs)
  @Column({ default: 0 })
  totalSessions: number;
  
  @Column({ type: 'decimal', precision: 10, scale: 2, default: 0 })
  totalDistance: number;
  
  @Column({ default: 0 })
  totalJumps: number;
  
  @Column({ type: 'decimal', precision: 6, scale: 2, default: 0 })
  bestJumpHeight: number;
  
  @CreateDateColumn()
  createdAt: Date;
  
  @UpdateDateColumn()
  updatedAt: Date;
  
  @Column({ nullable: true })
  lastLoginAt?: Date;
  
  @OneToMany(() => Session, session => session.user)
  sessions: Session[];
}
```

### Session Entity

```typescript
// src/modules/sessions/entities/session.entity.ts
import { Entity, PrimaryGeneratedColumn, Column, ManyToOne, OneToMany, CreateDateColumn, UpdateDateColumn, Index } from 'typeorm';
import { User } from '../../users/entities/user.entity';
import { Jump } from './jump.entity';
import { GPSTrack } from './gps-track.entity';

@Entity('sessions')
@Index(['userId', 'startTime'])
@Index(['sport'])
export class Session {
  @PrimaryGeneratedColumn('uuid')
  id: string;
  
  @Column('uuid')
  userId: string;
  
  @ManyToOne(() => User, user => user.sessions, { onDelete: 'CASCADE' })
  user: User;
  
  @Column({ type: 'varchar', length: 20 })
  sport: string;
  
  @Column({ type: 'timestamptz' })
  startTime: Date;
  
  @Column({ type: 'timestamptz' })
  endTime: Date;
  
  // Summary (denormalized for fast queries)
  @Column({ type: 'decimal', precision: 10, scale: 2 })
  distanceKm: number;
  
  @Column({ type: 'integer' })
  durationSec: number;
  
  @Column({ type: 'decimal', precision: 6, scale: 2 })
  maxSpeedKmh: number;
  
  @Column({ type: 'decimal', precision: 6, scale: 2 })
  avgSpeedKmh: number;
  
  @Column({ type: 'integer', default: 0 })
  jumpCount: number;
  
  @Column({ type: 'decimal', precision: 6, scale: 2, default: 0 })
  maxJumpHeightM: number;
  
  @Column({ type: 'decimal', precision: 10, scale: 2, default: 0 })
  totalAirtimeSec: number;
  
  // Metadata
  @Column({ default: '1.0' })
  version: string;
  
  @Column({ type: 'varchar', length: 10 })
  watchType: string;
  
  @Column({ type: 'varchar', length: 20 })
  appVersion: string;
  
  @Column({ nullable: true })
  timezone?: string;
  
  @Column({ nullable: true, type: 'text' })
  notes?: string;
  
  @Column({ nullable: true })
  location?: string;
  
  @CreateDateColumn()
  createdAt: Date;
  
  @UpdateDateColumn()
  updatedAt: Date;
  
  @OneToMany(() => Jump, jump => jump.session, { cascade: true })
  jumps: Jump[];
  
  @OneToMany(() => GPSTrack, track => track.session, { cascade: true })
  gpsTracks: GPSTrack[];
}
```

### Jump Entity

```typescript
// src/modules/sessions/entities/jump.entity.ts
import { Entity, PrimaryGeneratedColumn, Column, ManyToOne, Index } from 'typeorm';
import { Session } from './session.entity';

@Entity('jumps')
@Index(['sessionId'])
export class Jump {
  @PrimaryGeneratedColumn('uuid')
  id: string;
  
  @Column('uuid')
  sessionId: string;
  
  @ManyToOne(() => Session, session => session.jumps, { onDelete: 'CASCADE' })
  session: Session;
  
  @Column({ type: 'timestamptz' })
  startTime: Date;
  
  @Column({ type: 'timestamptz' })
  endTime: Date;
  
  @Column({ type: 'decimal', precision: 6, scale: 3 })
  airtime: number;
  
  @Column({ type: 'decimal', precision: 6, scale: 2 })
  heightM: number;
  
  @Column({ type: 'decimal', precision: 6, scale: 2 })
  maxVerticalVelocity: number;
  
  @Column({ type: 'decimal', precision: 6, scale: 2 })
  takeoffSpeedKmh: number;
  
  @Column({ type: 'decimal', precision: 6, scale: 2 })
  landingSpeedKmh: number;
  
  @Column({ type: 'integer' })
  confidence: number;
  
  @Column({ type: 'boolean', default: false })
  rotationDetected: boolean;
  
  @Column({ type: 'jsonb', nullable: true })
  takeoffLocation?: object;
  
  @Column({ type: 'jsonb', nullable: true })
  landingLocation?: object;
}
```

## Authentication Module

### JWT Strategy

```typescript
// src/modules/auth/jwt.strategy.ts
import { Injectable, UnauthorizedException } from '@nestjs/common';
import { PassportStrategy } from '@nestjs/passport';
import { ExtractJwt, Strategy } from 'passport-jwt';
import { ConfigService } from '@nestjs/config';
import { UsersService } from '../users/users.service';

@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy) {
  constructor(
    private configService: ConfigService,
    private usersService: UsersService,
  ) {
    super({
      jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(),
      ignoreExpiration: false,
      secretOrKey: configService.get<string>('JWT_SECRET'),
    });
  }
  
  async validate(payload: any) {
    const user = await this.usersService.findById(payload.sub);
    if (!user) {
      throw new UnauthorizedException();
    }
    return user; // Attached to request.user
  }
}
```

### Auth Service

```typescript
// src/modules/auth/auth.service.ts
import { Injectable, UnauthorizedException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { ConfigService } from '@nestjs/config';
import * as bcrypt from 'bcrypt';
import { UsersService } from '../users/users.service';
import { RegisterDto } from './dto/register.dto';
import { LoginDto } from './dto/login.dto';

@Injectable()
export class AuthService {
  constructor(
    private usersService: UsersService,
    private jwtService: JwtService,
    private configService: ConfigService,
  ) {}
  
  async register(registerDto: RegisterDto) {
    const hashedPassword = await bcrypt.hash(registerDto.password, 10);
    
    const user = await this.usersService.create({
      ...registerDto,
      password: hashedPassword,
    });
    
    const tokens = await this.generateTokens(user.id);
    
    return {
      user,
      ...tokens,
    };
  }
  
  async login(loginDto: LoginDto) {
    const user = await this.usersService.findByEmail(loginDto.email);
    
    if (!user || !(await bcrypt.compare(loginDto.password, user.password))) {
      throw new UnauthorizedException('Invalid credentials');
    }
    
    // Update last login
    await this.usersService.updateLastLogin(user.id);
    
    const tokens = await this.generateTokens(user.id);
    
    return {
      user,
      ...tokens,
    };
  }
  
  async refreshToken(refreshToken: string) {
    try {
      const payload = this.jwtService.verify(refreshToken, {
        secret: this.configService.get<string>('JWT_REFRESH_SECRET'),
      });
      
      return this.generateTokens(payload.sub);
    } catch (error) {
      throw new UnauthorizedException('Invalid refresh token');
    }
  }
  
  private async generateTokens(userId: string) {
    const [accessToken, refreshToken] = await Promise.all([
      this.jwtService.signAsync(
        { sub: userId },
        {
          secret: this.configService.get<string>('JWT_SECRET'),
          expiresIn: this.configService.get<string>('JWT_EXPIRATION'),
        },
      ),
      this.jwtService.signAsync(
        { sub: userId },
        {
          secret: this.configService.get<string>('JWT_REFRESH_SECRET'),
          expiresIn: this.configService.get<string>('JWT_REFRESH_EXPIRATION'),
        },
      ),
    ]);
    
    return {
      accessToken,
      refreshToken,
    };
  }
}
```

### Auth Controller

```typescript
// src/modules/auth/auth.controller.ts
import { Controller, Post, Body, HttpCode, HttpStatus } from '@nestjs/common';
import { ApiTags, ApiOperation } from '@nestjs/swagger';
import { AuthService } from './auth.service';
import { RegisterDto } from './dto/register.dto';
import { LoginDto } from './dto/login.dto';
import { RefreshTokenDto } from './dto/refresh-token.dto';

@ApiTags('auth')
@Controller('auth')
export class AuthController {
  constructor(private authService: AuthService) {}
  
  @Post('register')
  @ApiOperation({ summary: 'Register a new user' })
  async register(@Body() registerDto: RegisterDto) {
    return this.authService.register(registerDto);
  }
  
  @Post('login')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Login with email and password' })
  async login(@Body() loginDto: LoginDto) {
    return this.authService.login(loginDto);
  }
  
  @Post('refresh')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Refresh access token' })
  async refresh(@Body() refreshTokenDto: RefreshTokenDto) {
    return this.authService.refreshToken(refreshTokenDto.refreshToken);
  }
}
```

## Sessions Module

### Sessions Service

```typescript
// src/modules/sessions/sessions.service.ts
import { Injectable, NotFoundException, ForbiddenException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { Session } from './entities/session.entity';
import { CreateSessionDto } from './dto/create-session.dto';
import { User } from '../users/entities/user.entity';

@Injectable()
export class SessionsService {
  constructor(
    @InjectRepository(Session)
    private sessionsRepository: Repository<Session>,
  ) {}
  
  async create(userId: string, createSessionDto: CreateSessionDto): Promise<Session> {
    const session = this.sessionsRepository.create({
      ...createSessionDto,
      userId,
    });
    
    return this.sessionsRepository.save(session);
  }
  
  async findAll(userId: string, options?: { sport?: string; limit?: number }): Promise<Session[]> {
    const query = this.sessionsRepository
      .createQueryBuilder('session')
      .where('session.userId = :userId', { userId })
      .orderBy('session.startTime', 'DESC');
    
    if (options?.sport) {
      query.andWhere('session.sport = :sport', { sport: options.sport });
    }
    
    if (options?.limit) {
      query.limit(options.limit);
    }
    
    return query.getMany();
  }
  
  async findOne(id: string, userId: string): Promise<Session> {
    const session = await this.sessionsRepository.findOne({
      where: { id },
      relations: ['jumps', 'gpsTracks'],
    });
    
    if (!session) {
      throw new NotFoundException(`Session ${id} not found`);
    }
    
    // Check ownership
    if (session.userId !== userId && !session.user?.sessionsPublic) {
      throw new ForbiddenException('Access denied');
    }
    
    return session;
  }
  
  async update(id: string, userId: string, updateData: Partial<Session>): Promise<Session> {
    const session = await this.findOne(id, userId);
    
    if (session.userId !== userId) {
      throw new ForbiddenException('Access denied');
    }
    
    Object.assign(session, updateData);
    return this.sessionsRepository.save(session);
  }
  
  async delete(id: string, userId: string): Promise<void> {
    const session = await this.findOne(id, userId);
    
    if (session.userId !== userId) {
      throw new ForbiddenException('Access denied');
    }
    
    await this.sessionsRepository.remove(session);
  }
  
  async getStats(userId: string) {
    const stats = await this.sessionsRepository
      .createQueryBuilder('session')
      .select('COUNT(*)', 'totalSessions')
      .addSelect('SUM(session.distanceKm)', 'totalDistance')
      .addSelect('SUM(session.jumpCount)', 'totalJumps')
      .addSelect('MAX(session.maxJumpHeightM)', 'bestJumpHeight')
      .addSelect('MAX(session.maxSpeedKmh)', 'maxSpeed')
      .where('session.userId = :userId', { userId })
      .getRawOne();
    
    return {
      totalSessions: parseInt(stats.totalSessions) || 0,
      totalDistance: parseFloat(stats.totalDistance) || 0,
      totalJumps: parseInt(stats.totalJumps) || 0,
      bestJumpHeight: parseFloat(stats.bestJumpHeight) || 0,
      maxSpeed: parseFloat(stats.maxSpeed) || 0,
    };
  }
}
```

### Sessions Controller

```typescript
// src/modules/sessions/sessions.controller.ts
import { Controller, Get, Post, Put, Delete, Body, Param, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiTags, ApiOperation } from '@nestjs/swagger';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { User } from '../users/entities/user.entity';
import { SessionsService } from './sessions.service';
import { CreateSessionDto } from './dto/create-session.dto';
import { UpdateSessionDto } from './dto/update-session.dto';

@ApiTags('sessions')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller('sessions')
export class SessionsController {
  constructor(private sessionsService: SessionsService) {}
  
  @Post()
  @ApiOperation({ summary: 'Create a new session' })
  create(@CurrentUser() user: User, @Body() createSessionDto: CreateSessionDto) {
    return this.sessionsService.create(user.id, createSessionDto);
  }
  
  @Get()
  @ApiOperation({ summary: 'Get all sessions for current user' })
  findAll(
    @CurrentUser() user: User,
    @Query('sport') sport?: string,
    @Query('limit') limit?: number,
  ) {
    return this.sessionsService.findAll(user.id, { sport, limit });
  }
  
  @Get('stats')
  @ApiOperation({ summary: 'Get user statistics' })
  getStats(@CurrentUser() user: User) {
    return this.sessionsService.getStats(user.id);
  }
  
  @Get(':id')
  @ApiOperation({ summary: 'Get a specific session' })
  findOne(@CurrentUser() user: User, @Param('id') id: string) {
    return this.sessionsService.findOne(id, user.id);
  }
  
  @Put(':id')
  @ApiOperation({ summary: 'Update a session' })
  update(
    @CurrentUser() user: User,
    @Param('id') id: string,
    @Body() updateSessionDto: UpdateSessionDto,
  ) {
    return this.sessionsService.update(id, user.id, updateSessionDto);
  }
  
  @Delete(':id')
  @ApiOperation({ summary: 'Delete a session' })
  delete(@CurrentUser() user: User, @Param('id') id: string) {
    return this.sessionsService.delete(id, user.id);
  }
}
```

## Database Migrations

```bash
# Generate migration
npm run migration:generate -- -n InitialSchema

# Run migrations
npm run migration:run

# Revert migration
npm run migration:revert
```

## Development Checklist

### Project Setup
- [ ] Initialize NestJS project
- [ ] Install all dependencies
- [ ] Configure environment variables
- [ ] Set up TypeORM with PostgreSQL

### Authentication
- [ ] Implement JWT strategy
- [ ] Create auth service (register, login, refresh)
- [ ] Add password hashing with bcrypt
- [ ] Create auth controller
- [ ] Add JWT guard

### Users Module
- [ ] Create User entity
- [ ] Implement users service
- [ ] Create users controller
- [ ] Add profile endpoints

### Sessions Module
- [ ] Create Session, Jump, GPSTrack entities
- [ ] Implement sessions service
- [ ] Create sessions controller
- [ ] Add CRUD endpoints
- [ ] Implement stats aggregation

### Security
- [ ] Add helmet middleware
- [ ] Configure CORS
- [ ] Add rate limiting (optional)
- [ ] Implement request validation

### Documentation
- [ ] Set up Swagger/OpenAPI
- [ ] Document all endpoints
- [ ] Add example requests/responses
- [ ] Generate API documentation

### Testing
- [ ] Write unit tests for services
- [ ] Write e2e tests for controllers
- [ ] Test authentication flow
- [ ] Test session CRUD operations

---

**Next Steps**: Set up Docker and deployment (`09_docker_devops.md`).
