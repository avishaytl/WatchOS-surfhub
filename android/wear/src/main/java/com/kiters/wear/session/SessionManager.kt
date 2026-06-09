package com.kiters.wear.session

import android.app.Application
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.kiters.wear.engine.GpsUtil
import com.kiters.wear.engine.JumpDetector
import com.kiters.wear.model.GpsPoint
import com.kiters.wear.model.GpsSignalQuality
import com.kiters.wear.model.ImuSample
import com.kiters.wear.model.Jump
import com.kiters.wear.model.JumpDetectionConfig
import com.kiters.wear.model.LocationAuthStatus
import com.kiters.wear.model.Session
import com.kiters.wear.model.Sport
import com.kiters.wear.model.SessionStatus
import com.kiters.wear.sensors.LocationManager
import com.kiters.wear.sensors.MotionManager
import com.kiters.wear.sensors.WorkoutManager
import com.kiters.wear.storage.SessionLogger
import com.kiters.wear.storage.SettingsStore
import com.kiters.wear.storage.StorageManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.Executors

/**
 * Coordinates all services and manages active-session state. Faithful port of
 * the watchOS SessionManager: smooths GPS speed before feeding the detector,
 * keeps an incremental running distance, feeds the jump detector on the sensor
 * thread first, then publishes UI state. Exposes everything as StateFlows.
 */
class SessionManager(app: Application) : AndroidViewModel(app) {

    private val settings = SettingsStore(app)
    private val locationManager = LocationManager(app)
    private val motionManager = MotionManager(app)
    private val workoutManager = WorkoutManager(app)
    private val storageManager = StorageManager(app)
    private val sessionLogger = SessionLogger.shared

    private val mainHandler = Handler(Looper.getMainLooper())
    private val analysisExecutor = Executors.newSingleThreadExecutor()

    private val jumpDetector = JumpDetector(
        synchronousAnalysis = false,
        backgroundExecutor = { block -> analysisExecutor.execute(block) },
        mainExecutor = { block -> mainHandler.post(block) },
    )

    // Published state
    private val _currentSession = MutableStateFlow<Session?>(null)
    val currentSession: StateFlow<Session?> = _currentSession.asStateFlow()
    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()
    private val _isPaused = MutableStateFlow(false)
    val isPaused: StateFlow<Boolean> = _isPaused.asStateFlow()
    private val _jumpCount = MutableStateFlow(0)
    val jumpCount: StateFlow<Int> = _jumpCount.asStateFlow()
    private val _distance = MutableStateFlow(0.0)
    val distance: StateFlow<Double> = _distance.asStateFlow()
    private val _maxSpeed = MutableStateFlow(0.0)
    val maxSpeed: StateFlow<Double> = _maxSpeed.asStateFlow()
    private val _currentSpeed = MutableStateFlow(0.0)
    val currentSpeed: StateFlow<Double> = _currentSpeed.asStateFlow()
    private val _duration = MutableStateFlow(0.0)
    val duration: StateFlow<Double> = _duration.asStateFlow()
    private val _heartRate = MutableStateFlow(0.0)
    val heartRate: StateFlow<Double> = _heartRate.asStateFlow()

    private val _gpsPointCount = MutableStateFlow(0)
    val gpsPointCount: StateFlow<Int> = _gpsPointCount.asStateFlow()
    private val _isGpsActive = MutableStateFlow(false)
    val isGpsActive: StateFlow<Boolean> = _isGpsActive.asStateFlow()
    private val _lastGpsAccuracy = MutableStateFlow(0.0)
    val lastGpsAccuracy: StateFlow<Double> = _lastGpsAccuracy.asStateFlow()
    private val _gpsSignalQuality = MutableStateFlow(GpsSignalQuality.NONE)
    val gpsSignalQuality: StateFlow<GpsSignalQuality> = _gpsSignalQuality.asStateFlow()

    private val _jumpState = MutableStateFlow(JumpDetector.JumpState.IDLE)
    val jumpState: StateFlow<JumpDetector.JumpState> = _jumpState.asStateFlow()

    private val _locationAuthStatus = MutableStateFlow(LocationAuthStatus.NOT_DETERMINED)
    val locationAuthStatus: StateFlow<LocationAuthStatus> = _locationAuthStatus.asStateFlow()

    val isLocationAuthorized: Boolean get() = locationManager.hasPermission()

    // Private session state
    private var runningDistance = 0.0
    private var lastGpsPoint: GpsPoint? = null
    private val speedSmoothingBuffer = ArrayList<Double>()
    private val speedSmoothingWindow = 5
    private var sessionStartMonotonic: Double? = null
    private var sampleLogCounter = 0

    private val detectionMode get() = settings.detectionMode

    init {
        jumpDetector.onStateChanged = { st -> mainHandler.post { _jumpState.value = st } }
        jumpDetector.onJumpDetected = { jump -> handleJumpDetected(jump) }
        jumpDetector.onHaptic = { strong -> if (settings.hapticFeedback) vibrate(strong) }

        motionManager.onImuSample = { sample -> handleImuSample(sample) }
        locationManager.onLocationUpdate = { point -> handleGpsPoint(point) }
        workoutManager.onHeartRate = { bpm -> mainHandler.post { _heartRate.value = bpm } }

        refreshLocationAuth()
    }

    // MARK: - Permissions

    fun refreshLocationAuth() {
        _locationAuthStatus.value =
            if (locationManager.hasPermission()) LocationAuthStatus.AUTHORIZED
            else LocationAuthStatus.NOT_DETERMINED
    }

    fun onPermissionResult(granted: Boolean) {
        _locationAuthStatus.value =
            if (granted) LocationAuthStatus.AUTHORIZED else LocationAuthStatus.DENIED
    }

    // MARK: - Session Control

    fun startSession(sport: Sport) {
        if (_currentSession.value != null) return

        val session = Session.create(sport)
        _currentSession.value = session
        _isRecording.value = true
        _isPaused.value = false
        _jumpCount.value = 0
        _distance.value = 0.0
        _maxSpeed.value = 0.0
        _currentSpeed.value = 0.0
        _duration.value = 0.0
        _gpsPointCount.value = 0
        _isGpsActive.value = false
        _lastGpsAccuracy.value = 0.0
        _gpsSignalQuality.value = GpsSignalQuality.NONE
        runningDistance = 0.0
        lastGpsPoint = null
        speedSmoothingBuffer.clear()
        sessionStartMonotonic = null
        sampleLogCounter = 0

        jumpDetector.sessionId = session.id
        jumpDetector.reset(detectionMode)

        startRecordingService()
        locationManager.startTracking()
        motionManager.startTracking()
        workoutManager.startWorkout()

        sessionLogger.start(session.id, detectionMode, JumpDetectionConfig.shared.devMode)

        startTimer()
    }

    fun pauseSession() {
        val s = _currentSession.value ?: return
        if (_isPaused.value) return
        locationManager.pauseTracking()
        motionManager.pauseTracking()
        workoutManager.pauseWorkout()
        _currentSession.value = s.copy().also { it.status = SessionStatus.PAUSED }
        _isPaused.value = true
    }

    fun resumeSession() {
        val s = _currentSession.value ?: return
        if (!_isPaused.value) return
        locationManager.resumeTracking()
        motionManager.resumeTracking()
        workoutManager.resumeWorkout()
        _currentSession.value = s.copy().also { it.status = SessionStatus.ACTIVE }
        _isPaused.value = false
        startTimer()
    }

    fun endSession() {
        val s = _currentSession.value ?: return
        locationManager.stopTracking()
        motionManager.stopTracking()
        workoutManager.endWorkout()
        sessionLogger.stop()
        timerJob = false

        s.endTimeMs = System.currentTimeMillis()
        s.status = SessionStatus.COMPLETED
        storageManager.saveSession(s)

        stopRecordingService()

        _currentSession.value = null
        _isRecording.value = false
        _isPaused.value = false
        _jumpCount.value = 0
        _isGpsActive.value = false
        _gpsSignalQuality.value = GpsSignalQuality.NONE
    }

    fun loadAllSessions(): List<Session> = storageManager.loadAllSessions()

    fun loadSession(id: String): Session? = storageManager.loadSession(id)

    fun clearAllSessionsPublic() = storageManager.clearAllSessions()

    /** Reactive accent color key + RTL flag, read by the UI. */
    val settingsStore: SettingsStore get() = settings

    // MARK: - Data handling

    private fun handleGpsPoint(point: GpsPoint) {
        // Smooth speed via moving average before feeding the detector.
        speedSmoothingBuffer.add(point.speed)
        if (speedSmoothingBuffer.size > speedSmoothingWindow) speedSmoothingBuffer.removeAt(0)
        val smoothed = speedSmoothingBuffer.sum() / speedSmoothingBuffer.size

        val tMono = sessionStartMonotonic?.let { point.timestampMs / 1000.0 } ?: (point.timestampMs / 1000.0)
        jumpDetector.updateGps(
            speed = smoothed,
            altitude = point.altitude,
            latitude = point.latitude,
            longitude = point.longitude,
            course = point.course,
            timestamp = tMono,
        )

        val session = _currentSession.value ?: return
        if (session.status != SessionStatus.ACTIVE) return

        session.gpsPoints.add(point)
        lastGpsPoint?.let { prev ->
            runningDistance += GpsUtil.haversine(prev.latitude, prev.longitude, point.latitude, point.longitude)
        }
        lastGpsPoint = point
        session.cachedDistance = runningDistance

        _distance.value = runningDistance
        _maxSpeed.value = maxOf(_maxSpeed.value, point.speed)
        _currentSpeed.value = point.speed
        _gpsPointCount.value = session.gpsPoints.size
        _isGpsActive.value = true
        _lastGpsAccuracy.value = point.horizontalAccuracy
        _gpsSignalQuality.value = GpsSignalQuality.from(point.horizontalAccuracy)
    }

    private fun handleImuSample(sample: ImuSample) {
        // Feed the detector first (most latency-sensitive), on the sensor thread.
        jumpDetector.processSample(sample)

        // CSV log: full rate when active, throttled to ~10 Hz during IDLE.
        if (sessionStartMonotonic == null) sessionStartMonotonic = sample.timestamp
        sampleLogCounter += 1
        val state = jumpDetector.state
        if (state != JumpDetector.JumpState.IDLE || sampleLogCounter % 5 == 0) {
            val t = sample.timestamp - (sessionStartMonotonic ?: sample.timestamp)
            sessionLogger.logSample(sample, t, _currentSpeed.value, state.rawValue)
        }
    }

    private fun handleJumpDetected(jump: Jump) {
        mainHandler.post {
            val session = _currentSession.value ?: return@post
            jump.sessionId = session.id
            session.jumps.add(jump)
            _currentSession.value = session.copy(jumps = ArrayList(session.jumps))
            _jumpCount.value = session.jumps.size
        }
    }

    // MARK: - Timer

    @Volatile private var timerJob = false

    private fun startTimer() {
        if (timerJob) return
        timerJob = true
        viewModelScope.launch {
            while (timerJob) {
                _currentSession.value?.let { _duration.value = it.duration }
                delay(1000)
            }
        }
    }

    // MARK: - Foreground service

    private fun startRecordingService() {
        val intent = Intent(getApplication(), RecordingService::class.java)
        ContextCompat.startForegroundService(getApplication(), intent)
    }

    private fun stopRecordingService() {
        getApplication<Application>().stopService(Intent(getApplication(), RecordingService::class.java))
    }

    // MARK: - Haptics

    @Suppress("DEPRECATION")
    private fun vibrate(strong: Boolean) {
        val app = getApplication<Application>()
        val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (app.getSystemService(Application.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            app.getSystemService(Application.VIBRATOR_SERVICE) as? Vibrator
        }
        vibrator ?: return
        val timings = if (strong) longArrayOf(0, 120, 60, 120) else longArrayOf(0, 80)
        val amplitudes = if (strong) intArrayOf(0, 255, 0, 255) else intArrayOf(0, 200)
        vibrator.vibrate(VibrationEffect.createWaveform(timings, amplitudes, -1))
    }

    override fun onCleared() {
        super.onCleared()
        timerJob = false
        analysisExecutor.shutdown()
    }
}
