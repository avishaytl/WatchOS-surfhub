# 07 - Mobile App (React Native)

## Overview

The React Native mobile app is the **primary user interface** for SPOTEQ. It receives sessions from the watch, displays analytics, manages user accounts, and orchestrates sync with the backend.

## Tech Stack

- **Framework**: React Native 0.73+
- **Language**: TypeScript
- **Navigation**: React Navigation 6
- **State Management**: Zustand (lightweight, simple)
- **Database**: WatermelonDB (offline-first, fast)
- **Maps**: React Native Maps
- **Charts**: Victory Native or react-native-chart-kit
- **Storage**: AsyncStorage + WatermelonDB

## Project Setup

### Initialize Project

```bash
npx react-native@latest init SPOTEQMobile \
  --template react-native-template-typescript \
  --directory apps/mobile

cd apps/mobile
```

### Install Dependencies

```bash
npm install --save \
  @react-navigation/native \
  @react-navigation/stack \
  @react-navigation/bottom-tabs \
  zustand \
  @nozbe/watermelondb \
  @nozbe/with-observables \
  react-native-maps \
  victory-native \
  date-fns \
  axios \
  @react-native-async-storage/async-storage \
  react-native-keychain
  
npm install --save-dev \
  @types/react-native-maps
```

## Architecture

### App Structure

```
apps/mobile/src/
├── screens/              # Screen components
├── components/           # Reusable UI components
├── navigation/           # Navigation configuration
├── services/             # Business logic
│   ├── watch/           # Watch communication
│   ├── database/        # WatermelonDB setup
│   ├── sync/            # Backend sync
│   └── api/             # API client
├── store/               # Zustand stores
├── models/              # WatermelonDB models
├── utils/               # Helper functions
├── hooks/               # Custom React hooks
├── types/               # TypeScript types
└── theme/               # Design system (colors, fonts)
```

## Database Setup (WatermelonDB)

### Schema Definition

```typescript
// src/models/schema.ts
import { appSchema, tableSchema } from '@nozbe/watermelondb';

export const schema = appSchema({
  version: 1,
  tables: [
    tableSchema({
      name: 'sessions',
      columns: [
        { name: 'session_id', type: 'string', isIndexed: true },
        { name: 'user_id', type: 'string', isOptional: true },
        { name: 'sport', type: 'string', isIndexed: true },
        { name: 'start_time', type: 'number', isIndexed: true },
        { name: 'end_time', type: 'number' },
        { name: 'summary_json', type: 'string' },
        { name: 'metadata_json', type: 'string' },
        { name: 'synced', type: 'boolean', isIndexed: true },
        { name: 'synced_at', type: 'number', isOptional: true },
        { name: 'created_at', type: 'number' },
        { name: 'updated_at', type: 'number' },
      ],
    }),
    
    tableSchema({
      name: 'jumps',
      columns: [
        { name: 'session_id', type: 'string', isIndexed: true },
        { name: 'jump_id', type: 'string' },
        { name: 'start_time', type: 'number' },
        { name: 'end_time', type: 'number' },
        { name: 'airtime', type: 'number' },
        { name: 'height', type: 'number' },
        { name: 'takeoff_speed', type: 'number' },
        { name: 'landing_speed', type: 'number' },
        { name: 'confidence', type: 'number' },
        { name: 'rotation_detected', type: 'boolean' },
      ],
    }),
    
    tableSchema({
      name: 'gps_points',
      columns: [
        { name: 'session_id', type: 'string', isIndexed: true },
        { name: 'timestamp', type: 'number' },
        { name: 'latitude', type: 'number' },
        { name: 'longitude', type: 'number' },
        { name: 'altitude', type: 'number' },
        { name: 'speed', type: 'number' },
        { name: 'course', type: 'number' },
      ],
    }),
    
    tableSchema({
      name: 'sync_queue',
      columns: [
        { name: 'session_id', type: 'string', isIndexed: true },
        { name: 'operation', type: 'string' },
        { name: 'priority', type: 'number' },
        { name: 'retry_count', type: 'number' },
        { name: 'max_retries', type: 'number' },
        { name: 'error', type: 'string', isOptional: true },
        { name: 'created_at', type: 'number' },
        { name: 'last_attempt', type: 'number', isOptional: true },
      ],
    }),
  ],
});
```

### Model Classes

```typescript
// src/models/Session.ts
import { Model } from '@nozbe/watermelondb';
import { field, children, date, readonly } from '@nozbe/watermelondb/decorators';
import { SessionSummary, SessionMetadata } from '@spoteq/shared-types';

export class Session extends Model {
  static table = 'sessions';
  static associations = {
    jumps: { type: 'has_many', foreignKey: 'session_id' },
    gps_points: { type: 'has_many', foreignKey: 'session_id' },
  };
  
  @field('session_id') sessionId!: string;
  @field('user_id') userId?: string;
  @field('sport') sport!: string;
  @date('start_time') startTime!: Date;
  @date('end_time') endTime!: Date;
  @field('summary_json') summaryJson!: string;
  @field('metadata_json') metadataJson!: string;
  @field('synced') synced!: boolean;
  @date('synced_at') syncedAt?: Date;
  @readonly @date('created_at') createdAt!: Date;
  @readonly @date('updated_at') updatedAt!: Date;
  
  @children('jumps') jumps!: any;
  @children('gps_points') gpsPoints!: any;
  
  // Computed properties
  get summary(): SessionSummary {
    return JSON.parse(this.summaryJson);
  }
  
  get metadata(): SessionMetadata {
    return JSON.parse(this.metadataJson);
  }
  
  get duration(): number {
    return (this.endTime.getTime() - this.startTime.getTime()) / 1000;
  }
}
```

### Database Setup

```typescript
// src/services/database/database.ts
import { Database } from '@nozbe/watermelondb';
import SQLiteAdapter from '@nozbe/watermelondb/adapters/sqlite';
import { schema } from '../../models/schema';
import { Session, Jump, GPSPoint, SyncQueueItem } from '../../models';

const adapter = new SQLiteAdapter({
  schema,
  dbName: 'spoteq',
  jsi: true, // Use JSI for better performance
});

export const database = new Database({
  adapter,
  modelClasses: [Session, Jump, GPSPoint, SyncQueueItem],
});
```

## Navigation

### Navigation Structure

```typescript
// src/navigation/RootNavigator.tsx
import React from 'react';
import { NavigationContainer } from '@react-navigation/native';
import { createStackNavigator } from '@react-navigation/stack';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import Icon from 'react-native-vector-icons/Ionicons';

import HomeScreen from '../screens/HomeScreen';
import SessionListScreen from '../screens/SessionListScreen';
import SessionDetailScreen from '../screens/SessionDetailScreen';
import LiveSessionScreen from '../screens/LiveSessionScreen';
import MapScreen from '../screens/MapScreen';
import SettingsScreen from '../screens/SettingsScreen';

const Tab = createBottomTabNavigator();
const Stack = createStackNavigator();

function SessionStack() {
  return (
    <Stack.Navigator>
      <Stack.Screen name="SessionList" component={SessionListScreen} />
      <Stack.Screen name="SessionDetail" component={SessionDetailScreen} />
      <Stack.Screen name="Map" component={MapScreen} />
    </Stack.Navigator>
  );
}

export default function RootNavigator() {
  return (
    <NavigationContainer>
      <Tab.Navigator
        screenOptions={({ route }) => ({
          tabBarIcon: ({ focused, color, size }) => {
            let iconName = 'home';
            if (route.name === 'Home') iconName = 'home';
            else if (route.name === 'Sessions') iconName = 'list';
            else if (route.name === 'Live') iconName = 'play-circle';
            else if (route.name === 'Settings') iconName = 'settings';
            
            return <Icon name={iconName} size={size} color={color} />;
          },
        })}
      >
        <Tab.Screen name="Home" component={HomeScreen} />
        <Tab.Screen name="Sessions" component={SessionStack} />
        <Tab.Screen name="Live" component={LiveSessionScreen} />
        <Tab.Screen name="Settings" component={SettingsScreen} />
      </Tab.Navigator>
    </NavigationContainer>
  );
}
```

## State Management (Zustand)

### Session Store

```typescript
// src/store/sessionStore.ts
import { create } from 'zustand';
import { Session } from '@spoteq/shared-types';

interface SessionStore {
  // State
  sessions: Session[];
  selectedSession: Session | null;
  loading: boolean;
  error: string | null;
  
  // Actions
  loadSessions: () => Promise<void>;
  getSession: (id: string) => Promise<void>;
  deleteSession: (id: string) => Promise<void>;
  setSelectedSession: (session: Session | null) => void;
}

export const useSessionStore = create<SessionStore>((set, get) => ({
  sessions: [],
  selectedSession: null,
  loading: false,
  error: null,
  
  loadSessions: async () => {
    set({ loading: true, error: null });
    try {
      // Load from WatermelonDB
      const sessions = await sessionRepository.getAll();
      set({ sessions, loading: false });
    } catch (error) {
      set({ error: error.message, loading: false });
    }
  },
  
  getSession: async (id: string) => {
    set({ loading: true, error: null });
    try {
      const session = await sessionRepository.getById(id);
      set({ selectedSession: session, loading: false });
    } catch (error) {
      set({ error: error.message, loading: false });
    }
  },
  
  deleteSession: async (id: string) => {
    try {
      await sessionRepository.delete(id);
      const sessions = get().sessions.filter(s => s.id !== id);
      set({ sessions });
    } catch (error) {
      set({ error: error.message });
    }
  },
  
  setSelectedSession: (session) => set({ selectedSession: session }),
}));
```

### Auth Store

```typescript
// src/store/authStore.ts
import { create } from 'zustand';
import { User } from '@spoteq/shared-types';

interface AuthStore {
  user: User | null;
  token: string | null;
  isAuthenticated: boolean;
  loading: boolean;
  
  login: (email: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  register: (email: string, password: string, username: string) => Promise<void>;
  loadUser: () => Promise<void>;
}

export const useAuthStore = create<AuthStore>((set) => ({
  user: null,
  token: null,
  isAuthenticated: false,
  loading: false,
  
  login: async (email, password) => {
    set({ loading: true });
    try {
      const response = await apiClient.login(email, password);
      await saveTokenSecurely(response.token);
      set({ 
        user: response.user, 
        token: response.token, 
        isAuthenticated: true,
        loading: false 
      });
    } catch (error) {
      set({ loading: false });
      throw error;
    }
  },
  
  logout: async () => {
    await clearTokens();
    set({ user: null, token: null, isAuthenticated: false });
  },
  
  register: async (email, password, username) => {
    // Implementation
  },
  
  loadUser: async () => {
    const token = await loadTokenSecurely();
    if (token) {
      // Verify token and load user
    }
  },
}));
```

## Watch Communication

### iOS WatchConnectivity Bridge

```typescript
// src/services/watch/WatchConnectivityService.ts
import { NativeModules, NativeEventEmitter } from 'react-native';
import { Session } from '@spoteq/shared-types';

const { WatchConnectivity } = NativeModules;
const watchEmitter = new NativeEventEmitter(WatchConnectivity);

export class WatchConnectivityService {
  private static instance: WatchConnectivityService;
  
  static getInstance(): WatchConnectivityService {
    if (!WatchConnectivityService.instance) {
      WatchConnectivityService.instance = new WatchConnectivityService();
    }
    return WatchConnectivityService.instance;
  }
  
  constructor() {
    this.setupListeners();
  }
  
  private setupListeners(): void {
    // Listen for file transfers from watch
    watchEmitter.addListener('didReceiveFile', async (event) => {
      const { fileUrl, metadata } = event;
      await this.handleSessionFile(fileUrl, metadata);
    });
    
    // Listen for live updates
    watchEmitter.addListener('didReceiveMessage', (message) => {
      if (message.type === 'live_update') {
        this.handleLiveUpdate(message);
      }
    });
    
    // Listen for reachability changes
    watchEmitter.addListener('reachabilityChanged', (isReachable) => {
      console.log('Watch reachable:', isReachable);
    });
  }
  
  private async handleSessionFile(fileUrl: string, metadata: any): Promise<void> {
    try {
      // Read session file
      const sessionJson = await RNFS.readFile(fileUrl, 'utf8');
      const session: Session = JSON.parse(sessionJson);
      
      // Save to database
      await sessionRepository.create(session);
      
      // Add to sync queue
      await syncQueue.add(session.id, 'upload');
      
      // Trigger sync if WiFi available
      if (await isWiFiConnected()) {
        syncEngine.sync();
      }
      
      // Delete temporary file
      await RNFS.unlink(fileUrl);
      
    } catch (error) {
      console.error('Error handling session file:', error);
    }
  }
  
  private handleLiveUpdate(message: any): void {
    // Update live session store
    liveSessionStore.update({
      speed: message.speed,
      jumpCount: message.jumpCount,
      distance: message.distance,
    });
  }
  
  sendMessage(message: any): void {
    WatchConnectivity.sendMessage(message);
  }
  
  isReachable(): Promise<boolean> {
    return WatchConnectivity.isReachable();
  }
}
```

### Native Module (iOS)

```objc
// ios/SPOTEQ/WatchConnectivity/WatchConnectivityBridge.m
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(WatchConnectivity, RCTEventEmitter)

RCT_EXTERN_METHOD(sendMessage:(NSDictionary *)message)
RCT_EXTERN_METHOD(isReachable:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
```

```swift
// ios/SPOTEQ/WatchConnectivity/WatchConnectivityBridge.swift
import Foundation
import WatchConnectivity

@objc(WatchConnectivity)
class WatchConnectivityBridge: RCTEventEmitter {
  
  override init() {
    super.init()
    if WCSession.isSupported() {
      let session = WCSession.default
      session.delegate = self
      session.activate()
    }
  }
  
  override func supportedEvents() -> [String]! {
    return ["didReceiveFile", "didReceiveMessage", "reachabilityChanged"]
  }
  
  @objc func sendMessage(_ message: [String: Any]) {
    guard WCSession.default.isReachable else { return }
    WCSession.default.sendMessage(message, replyHandler: nil)
  }
  
  @objc func isReachable(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    resolve(WCSession.default.isReachable)
  }
}

extension WatchConnectivityBridge: WCSessionDelegate {
  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    sendEvent(withName: "didReceiveFile", body: [
      "fileUrl": file.fileURL.path,
      "metadata": file.metadata ?? [:]
    ])
  }
  
  func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
    sendEvent(withName: "didReceiveMessage", body: message)
  }
  
  func sessionReachabilityDidChange(_ session: WCSession) {
    sendEvent(withName: "reachabilityChanged", body: session.isReachable)
  }
  
  // Required delegate methods
  func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
  func sessionDidBecomeInactive(_ session: WCSession) {}
  func sessionDidDeactivate(_ session: WCSession) {}
}
```

## Screens

### Session List Screen

```typescript
// src/screens/SessionListScreen.tsx
import React, { useEffect } from 'react';
import { FlatList, StyleSheet, View, Text, TouchableOpacity } from 'react-native';
import { useSessionStore } from '../store/sessionStore';
import SessionCard from '../components/SessionCard';

export default function SessionListScreen({ navigation }) {
  const { sessions, loading, loadSessions } = useSessionStore();
  
  useEffect(() => {
    loadSessions();
  }, []);
  
  const renderSession = ({ item }) => (
    <SessionCard
      session={item}
      onPress={() => navigation.navigate('SessionDetail', { sessionId: item.id })}
    />
  );
  
  if (loading) {
    return (
      <View style={styles.center}>
        <Text>Loading sessions...</Text>
      </View>
    );
  }
  
  return (
    <FlatList
      data={sessions}
      renderItem={renderSession}
      keyExtractor={(item) => item.id}
      contentContainerStyle={styles.list}
      refreshing={loading}
      onRefresh={loadSessions}
    />
  );
}

const styles = StyleSheet.create({
  list: {
    padding: 16,
  },
  center: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
});
```

### Session Detail Screen

```typescript
// src/screens/SessionDetailScreen.tsx
import React, { useEffect, useState } from 'react';
import { ScrollView, View, Text, StyleSheet } from 'react-native';
import { useRoute } from '@react-navigation/native';
import { Session } from '@spoteq/shared-types';
import { sessionRepository } from '../services/database/repositories';
import SessionMap from '../components/SessionMap';
import JumpList from '../components/JumpList';
import StatsGrid from '../components/StatsGrid';

export default function SessionDetailScreen() {
  const route = useRoute();
  const { sessionId } = route.params;
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  
  useEffect(() => {
    loadSession();
  }, [sessionId]);
  
  const loadSession = async () => {
    const data = await sessionRepository.getById(sessionId);
    setSession(data);
    setLoading(false);
  };
  
  if (loading || !session) {
    return <View style={styles.center}><Text>Loading...</Text></View>;
  }
  
  return (
    <ScrollView style={styles.container}>
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.title}>
          {session.sport.charAt(0).toUpperCase() + session.sport.slice(1)}
        </Text>
        <Text style={styles.date}>
          {new Date(session.startTime).toLocaleDateString()}
        </Text>
      </View>
      
      {/* Stats Grid */}
      <StatsGrid summary={session.summary} />
      
      {/* Map */}
      <SessionMap gpsTrack={session.gpsTrack} jumps={session.jumps} />
      
      {/* Jump List */}
      <JumpList jumps={session.jumps} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff' },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  header: { padding: 20 },
  title: { fontSize: 28, fontWeight: 'bold' },
  date: { fontSize: 16, color: '#666', marginTop: 4 },
});
```

## Development Checklist

### Project Setup
- [ ] Initialize React Native project
- [ ] Install all dependencies
- [ ] Configure TypeScript
- [ ] Set up ESLint and Prettier

### Database
- [ ] Set up WatermelonDB
- [ ] Define schema
- [ ] Create model classes
- [ ] Implement repositories

### Navigation
- [ ] Set up React Navigation
- [ ] Create tab navigator
- [ ] Create stack navigators
- [ ] Configure deep linking

### Watch Communication
- [ ] Create native module for WatchConnectivity (iOS)
- [ ] Create native module for Data Layer (Android)
- [ ] Implement session file handling
- [ ] Test live updates

### Screens
- [ ] Build HomeScreen
- [ ] Build SessionListScreen
- [ ] Build SessionDetailScreen
- [ ] Build LiveSessionScreen
- [ ] Build MapScreen
- [ ] Build SettingsScreen

### Components
- [ ] Create SessionCard
- [ ] Create JumpCard
- [ ] Create SessionMap
- [ ] Create StatsGrid
- [ ] Create SpeedGauge

### Sync
- [ ] Implement SyncEngine (next doc)
- [ ] Create SyncQueue
- [ ] Add background sync
- [ ] Handle conflicts

---

**Next Steps**: Build the backend API (`08_backend_api.md`) to handle user accounts and session storage.
