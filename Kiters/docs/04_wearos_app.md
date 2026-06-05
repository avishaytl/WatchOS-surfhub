# 04 - Wear OS App Implementation

## Overview

The Wear OS app provides the same functionality as the watchOS app but for Android watches. Built with Kotlin and Jetpack Compose for Wear OS, it tracks sessions using Android Sensors API and FusedLocationProvider.

## Project Setup

### Create Android Studio Project

1. Open Android Studio → New Project
2. Select **Wear OS** → **Empty Activity**
3. Name: `isurf-wearos`
4. Package: `com.isurf.wearos`
5. Language: **Kotlin**
6. Minimum SDK: **API 30 (Wear OS 3.0)**

### Configure Dependencies

**app/build.gradle.kts**:
```kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("kotlin-kapt")
}

android {
    namespace = "com.isurf.wearos"
    compileSdk = 34
    
    defaultConfig {
        applicationId = "com.isurf.wearos"
        minSdk = 30
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }
    
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    
    kotlinOptions {
        jvmTarget = "17"
    }
    
    buildFeatures {
        compose = true
    }
    
    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.3"
    }
}

dependencies {
    // Wear OS Compose
    implementation("androidx.wear.compose:compose-material:1.2.1")
    implementation("androidx.wear.compose:compose-foundation:1.2.1")
    implementation("androidx.wear.compose:compose-navigation:1.2.1")
    
    // Compose UI
    implementation("androidx.compose.ui:ui:1.5.4")
    implementation("androidx.compose.ui:ui-tooling-preview:1.5.4")
    implementation("androidx.activity:activity-compose:1.8.1")
    
    // Location Services
    implementation("com.google.android.gms:play-services-location:21.0.1")
    implementation("com.google.android.gms:play-services-wearable:18.1.0")
    
    // Health Services (for workout sessions)
    implementation("androidx.health:health-services-client:1.0.0-beta03")
    
    // Room Database
    implementation("androidx.room:room-runtime:2.6.0")
    implementation("androidx.room:room-ktx:2.6.0")
    kapt("androidx.room:room-compiler:2.6.0")
    
    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.7.3")
    
    // Lifecycle
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.6.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.6.2")
    
    // Serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.0")
}
```

### Configure Permissions

**AndroidManifest.xml**:
```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    
    <!-- Permissions -->
    <uses-permission android:name="android.permission.BODY_SENSORS" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_HEALTH" />
    
    <!-- Wear OS features -->
    <uses-feature android:name="android.hardware.type.watch" />
    <uses-feature android:name="android.hardware.sensor.accelerometer" android:required="true" />
    <uses-feature android:name="android.hardware.sensor.gyroscope" android:required="true" />
    <uses-feature android:name="android.hardware.location.gps" android:required="true" />
    
    <application
        android:name=".WearApp"
        android:allowBackup="true"
        android:icon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:theme="@android:style/Theme.DeviceDefault">
        
        <uses-library
            android:name="com.google.android.wearable"
            android:required="true" />
        
        <meta-data
            android:name="com.google.android.wearable.standalone"
            android:value="true" />
        
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:label="@string/app_name"
            android:theme="@android:style/Theme.DeviceDefault">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        
        <service
            android:name=".services.SessionService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="location|health" />
        
        <service
            android:name=".services.DataLayerListenerService"
            android:exported="true">
            <intent-filter>
                <action android:name="com.google.android.gms.wearable.DATA_CHANGED" />
                <action android:name="com.google.android.gms.wearable.MESSAGE_RECEIVED" />
                <data android:scheme="wear" android:host="*" />
            </intent-filter>
        </service>
    </application>
</manifest>
```

## Core Architecture

### Application Class

```kotlin
// WearApp.kt
package com.isurf.wearos

import android.app.Application
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class WearApp : Application() {
    val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    
    override fun onCreate() {
        super.onCreate()
        instance = this
    }
    
    companion object {
        lateinit var instance: WearApp
            private set
    }
}
```

### Main Activity

```kotlin
// MainActivity.kt
package com.isurf.wearos

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import com.isurf.wearos.ui.screens.SessionScreen
import com.isurf.wearos.ui.screens.StartScreen
import com.isurf.wearos.ui.screens.SummaryScreen
import com.isurf.wearos.ui.theme.ISurfTheme
import com.isurf.wearos.viewmodels.SessionViewModel

class MainActivity : ComponentActivity() {
    
    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val allGranted = permissions.values.all { it }
        if (!allGranted) {
            // Handle permission denial
        }
    }
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        requestPermissionsIfNeeded()
        
        setContent {
            ISurfTheme {
                WearApp()
            }
        }
    }
    
    private fun requestPermissionsIfNeeded() {
        val requiredPermissions = arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.BODY_SENSORS,
            Manifest.permission.ACTIVITY_RECOGNITION
        )
        
        val missingPermissions = requiredPermissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        
        if (missingPermissions.isNotEmpty()) {
            permissionLauncher.launch(missingPermissions.toTypedArray())
        }
    }
}

@Composable
fun WearApp() {
    val navController = rememberSwipeDismissableNavController()
    val sessionViewModel: SessionViewModel = viewModel()
    
    SwipeDismissableNavHost(
        navController = navController,
        startDestination = "start"
    ) {
        composable("start") {
            StartScreen(
                onStartSession = {
                    sessionViewModel.startSession()
                    navController.navigate("session")
                }
            )
        }
        
        composable("session") {
            SessionScreen(
                viewModel = sessionViewModel,
                onEndSession = {
                    navController.navigate("summary") {
                        popUpTo("start")
                    }
                }
            )
        }
        
        composable("summary") {
            SummaryScreen(
                session = sessionViewModel.lastSession,
                onDismiss = {
                    navController.navigate("start") {
                        popUpTo("start") { inclusive = true }
                    }
                }
            )
        }
    }
}
```

## Location Service

### FusedLocationProvider Implementation

```kotlin
// services/LocationService.kt
package com.isurf.wearos.services

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.os.Looper
import com.google.android.gms.location.*
import com.isurf.wearos.models.GPSPoint
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import java.util.*

class LocationService(private val context: Context) {
    
    private val fusedLocationClient: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(context)
    
    private val locationRequest = LocationRequest.Builder(
        Priority.PRIORITY_HIGH_ACCURACY,
        1000L // 1 second interval
    ).apply {
        setMinUpdateIntervalMillis(500L)
        setMaxUpdateDelayMillis(1000L)
        setWaitForAccurateLocation(false)
    }.build()
    
    @SuppressLint("MissingPermission")
    fun getLocationUpdates(): Flow<GPSPoint> = callbackFlow {
        val callback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.locations.forEach { location ->
                    val gpsPoint = location.toGPSPoint()
                    trySend(gpsPoint)
                }
            }
        }
        
        fusedLocationClient.requestLocationUpdates(
            locationRequest,
            callback,
            Looper.getMainLooper()
        )
        
        awaitClose {
            fusedLocationClient.removeLocationUpdates(callback)
        }
    }
    
    private fun Location.toGPSPoint() = GPSPoint(
        timestamp = Date(time),
        latitude = latitude,
        longitude = longitude,
        altitude = altitude,
        speed = if (hasSpeed()) speed.toDouble() else 0.0,
        course = if (hasBearing()) bearing.toDouble() else 0.0,
        horizontalAccuracy = if (hasAccuracy()) accuracy.toDouble() else 0.0,
        verticalAccuracy = if (hasVerticalAccuracy()) verticalAccuracyMeters.toDouble() else 0.0
    )
}
```

## Sensor Service

### IMU Data Collection

```kotlin
// services/SensorService.kt
package com.isurf.wearos.services

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import com.isurf.wearos.models.IMUSample
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import java.util.*

class SensorService(context: Context) {
    
    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    
    private val accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val gyroscope = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val rotationVector = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    
    private val samplingPeriodUs = 20_000 // 50Hz = 20ms = 20,000 microseconds
    
    fun getIMUUpdates(): Flow<IMUSample> = callbackFlow {
        var latestAccel: FloatArray? = null
        var latestGyro: FloatArray? = null
        var latestRotation: FloatArray? = null
        
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                when (event.sensor.type) {
                    Sensor.TYPE_ACCELEROMETER -> {
                        latestAccel = event.values.clone()
                    }
                    Sensor.TYPE_GYROSCOPE -> {
                        latestGyro = event.values.clone()
                    }
                    Sensor.TYPE_ROTATION_VECTOR -> {
                        latestRotation = event.values.clone()
                        
                        // Send combined sample when rotation updates (slowest sensor)
                        val accel = latestAccel
                        val gyro = latestGyro
                        val rotation = latestRotation
                        
                        if (accel != null && gyro != null && rotation != null) {
                            val sample = createIMUSample(accel, gyro, rotation)
                            trySend(sample)
                        }
                    }
                }
            }
            
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
                // Handle accuracy changes if needed
            }
        }
        
        // Register listeners
        accelerometer?.let {
            sensorManager.registerListener(listener, it, samplingPeriodUs)
        }
        gyroscope?.let {
            sensorManager.registerListener(listener, it, samplingPeriodUs)
        }
        rotationVector?.let {
            sensorManager.registerListener(listener, it, samplingPeriodUs)
        }
        
        awaitClose {
            sensorManager.unregisterListener(listener)
        }
    }
    
    private fun createIMUSample(
        accel: FloatArray,
        gyro: FloatArray,
        rotation: FloatArray
    ): IMUSample {
        // Calculate orientation from rotation vector
        val rotationMatrix = FloatArray(9)
        val orientation = FloatArray(3)
        SensorManager.getRotationMatrixFromVector(rotationMatrix, rotation)
        SensorManager.getOrientation(rotationMatrix, orientation)
        
        return IMUSample(
            timestamp = Date(),
            accelerationX = accel[0].toDouble(),
            accelerationY = accel[1].toDouble(),
            accelerationZ = accel[2].toDouble(),
            rotationX = gyro[0].toDouble(),
            rotationY = gyro[1].toDouble(),
            rotationZ = gyro[2].toDouble(),
            pitch = orientation[1].toDouble(),
            roll = orientation[2].toDouble(),
            yaw = orientation[0].toDouble()
        )
    }
}
```

## Session Service (Foreground Service)

### Background Session Recording

```kotlin
// services/SessionService.kt
package com.isurf.wearos.services

import android.app.*
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.isurf.wearos.MainActivity
import com.isurf.wearos.R
import com.isurf.wearos.data.SessionRepository
import com.isurf.wearos.models.Session
import com.isurf.wearos.models.Sport
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.*

class SessionService : Service() {
    
    private val binder = SessionBinder()
    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    
    private lateinit var locationService: LocationService
    private lateinit var sensorService: SensorService
    private lateinit var jumpDetector: JumpDetector
    private lateinit var sessionRepository: SessionRepository
    
    private var currentSession: Session? = null
    private val _sessionState = MutableStateFlow<SessionState>(SessionState.Idle)
    val sessionState: StateFlow<SessionState> = _sessionState.asStateFlow()
    
    override fun onCreate() {
        super.onCreate()
        
        locationService = LocationService(this)
        sensorService = SensorService(this)
        jumpDetector = JumpDetector()
        sessionRepository = SessionRepository(this)
        
        createNotificationChannel()
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = createNotification("Session recording...")
        startForeground(NOTIFICATION_ID, notification)
        return START_STICKY
    }
    
    override fun onBind(intent: Intent?): IBinder = binder
    
    fun startSession(sport: Sport) {
        if (currentSession != null) return
        
        val session = Session(
            id = UUID.randomUUID().toString(),
            sport = sport,
            startTime = Date()
        )
        currentSession = session
        
        serviceScope.launch {
            // Collect location updates
            launch {
                locationService.getLocationUpdates()
                    .collect { gpsPoint ->
                        sessionRepository.addGPSPoint(session.id, gpsPoint)
                        _sessionState.update { state ->
                            if (state is SessionState.Active) {
                                state.copy(
                                    currentSpeed = gpsPoint.speed,
                                    distance = state.distance + calculateIncrement(gpsPoint)
                                )
                            } else {
                                SessionState.Active(
                                    sessionId = session.id,
                                    currentSpeed = gpsPoint.speed,
                                    distance = 0.0,
                                    jumpCount = 0
                                )
                            }
                        }
                    }
            }
            
            // Collect IMU updates
            launch {
                sensorService.getIMUUpdates()
                    .collect { imuSample ->
                        jumpDetector.processSample(imuSample)
                        
                        // Only save IMU during jumps to conserve storage
                        if (jumpDetector.isJumpActive) {
                            sessionRepository.addIMUSample(session.id, imuSample)
                        }
                    }
            }
            
            // Collect detected jumps
            launch {
                jumpDetector.jumpsFlow
                    .collect { jump ->
                        sessionRepository.addJump(session.id, jump)
                        _sessionState.update { state ->
                            if (state is SessionState.Active) {
                                state.copy(jumpCount = state.jumpCount + 1)
                            } else state
                        }
                    }
            }
        }
        
        updateNotification("Recording session...")
    }
    
    suspend fun stopSession(): Session? {
        val session = currentSession ?: return null
        
        // Stop collecting data (cancel coroutines handled by scope)
        session.endTime = Date()
        
        // Calculate summary
        val summary = sessionRepository.calculateSummary(session.id)
        session.summary = summary
        
        // Save final session
        sessionRepository.saveSession(session)
        
        // Transfer to phone
        DataLayerService(this).sendSession(session)
        
        currentSession = null
        _sessionState.value = SessionState.Idle
        
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        
        return session
    }
    
    private fun calculateIncrement(gpsPoint: com.isurf.wearos.models.GPSPoint): Double {
        // Calculate distance increment from previous point
        // Simplified - should use Haversine formula
        return 0.0 // TODO: Implement
    }
    
    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Session Recording",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Ongoing session recording notifications"
        }
        
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }
    
    private fun createNotification(contentText: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_IMMUTABLE
        )
        
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("iSurf Session")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }
    
    private fun updateNotification(text: String) {
        val notification = createNotification(text)
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification)
    }
    
    override fun onDestroy() {
        serviceScope.cancel()
        super.onDestroy()
    }
    
    inner class SessionBinder : Binder() {
        fun getService(): SessionService = this@SessionService
    }
    
    companion object {
        private const val CHANNEL_ID = "session_recording"
        private const val NOTIFICATION_ID = 1
    }
}

sealed class SessionState {
    object Idle : SessionState()
    data class Active(
        val sessionId: String,
        val currentSpeed: Double,
        val distance: Double,
        val jumpCount: Int
    ) : SessionState()
}
```

## Data Layer Communication

### Syncing with Phone

```kotlin
// services/DataLayerService.kt
package com.isurf.wearos.services

import android.content.Context
import com.google.android.gms.wearable.*
import com.isurf.wearos.models.Session
import kotlinx.coroutines.tasks.await
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class DataLayerService(private val context: Context) {
    
    private val dataClient: DataClient = Wearable.getDataClient(context)
    private val messageClient: MessageClient = Wearable.getMessageClient(context)
    private val nodeClient: NodeClient = Wearable.getNodeClient(context)
    
    // Send live updates during session
    suspend fun sendLiveUpdate(sessionId: String, speed: Double, jumpCount: Int) {
        val nodes = nodeClient.connectedNodes.await()
        
        val message = Json.encodeToString(
            mapOf(
                "type" to "live_update",
                "sessionId" to sessionId,
                "speed" to speed,
                "jumpCount" to jumpCount,
                "timestamp" to System.currentTimeMillis()
            )
        ).toByteArray()
        
        nodes.forEach { node ->
            try {
                messageClient.sendMessage(node.id, "/live_update", message).await()
            } catch (e: Exception) {
                // Phone not reachable, continue
            }
        }
    }
    
    // Send completed session
    suspend fun sendSession(session: Session) {
        val sessionJson = Json.encodeToString(session)
        
        val putDataReq = PutDataMapRequest.create("/session/${session.id}").apply {
            dataMap.putString("sessionId", session.id)
            dataMap.putString("data", sessionJson)
            dataMap.putLong("timestamp", System.currentTimeMillis())
        }.asPutDataRequest().setUrgent()
        
        try {
            dataClient.putDataItem(putDataReq).await()
        } catch (e: Exception) {
            // Queue for retry
        }
    }
}

// Listener for messages from phone
class DataLayerListenerService : WearableListenerService() {
    
    override fun onMessageReceived(messageEvent: MessageEvent) {
        when (messageEvent.path) {
            "/settings_update" -> {
                // Handle settings sync from phone
                val settingsJson = String(messageEvent.data)
                // Update local settings
            }
        }
    }
    
    override fun onDataChanged(dataEvents: DataEventBuffer) {
        dataEvents.forEach { event ->
            if (event.type == DataEvent.TYPE_CHANGED) {
                // Handle data changes from phone
            }
        }
    }
}
```

## UI Screens

### Session Screen (Compose for Wear)

```kotlin
// ui/screens/SessionScreen.kt
package com.isurf.wearos.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material.*
import com.isurf.wearos.viewmodels.SessionViewModel

@Composable
fun SessionScreen(
    viewModel: SessionViewModel,
    onEndSession: () -> Unit
) {
    val state by viewModel.sessionState.collectAsState()
    
    Scaffold(
        timeText = { TimeText() }
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            // Speed display
            Text(
                text = "${(state.currentSpeed * 3.6).toInt()}",
                style = MaterialTheme.typography.display1,
                textAlign = TextAlign.Center
            )
            Text(
                text = "km/h",
                style = MaterialTheme.typography.caption1
            )
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // Stats
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                StatColumn("Jumps", state.jumpCount.toString())
                StatColumn("Dist", "%.1f km".format(state.distance / 1000))
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // Controls
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Button(
                    onClick = { /* Pause */ },
                    colors = ButtonDefaults.secondaryButtonColors()
                ) {
                    Icon(
                        painter = painterResource(R.drawable.ic_pause),
                        contentDescription = "Pause"
                    )
                }
                
                Button(
                    onClick = {
                        viewModel.stopSession()
                        onEndSession()
                    },
                    colors = ButtonDefaults.primaryButtonColors()
                ) {
                    Icon(
                        painter = painterResource(R.drawable.ic_stop),
                        contentDescription = "Stop"
                    )
                }
            }
        }
    }
}

@Composable
fun StatColumn(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(text = value, style = MaterialTheme.typography.title2)
        Text(text = label, style = MaterialTheme.typography.caption2)
    }
}
```

## Development Checklist

### Project Setup
- [ ] Create Wear OS project in Android Studio
- [ ] Add all required dependencies
- [ ] Configure AndroidManifest with permissions
- [ ] Set up Data Layer services

### Core Services
- [ ] Implement LocationService with FusedLocationProvider
- [ ] Implement SensorService for IMU data
- [ ] Create SessionService (foreground service)
- [ ] Set up DataLayerService for phone communication

### Jump Detection
- [ ] Port JumpDetector from Swift to Kotlin
- [ ] Test with real sensor data
- [ ] Tune thresholds for Android sensors

### Data Persistence
- [ ] Set up Room database
- [ ] Create SessionRepository
- [ ] Implement session storage and retrieval

### UI
- [ ] Build SessionScreen with Compose for Wear
- [ ] Create SummaryScreen
- [ ] Add StartScreen with sport selection

### Testing
- [ ] Test on physical Wear OS watch
- [ ] Test battery consumption
- [ ] Test Data Layer sync with phone
- [ ] Verify permissions flow

---

**Next Steps**: Implement the jump detection algorithm (`05_jump_detection.md`) that will be shared across both watch platforms.
