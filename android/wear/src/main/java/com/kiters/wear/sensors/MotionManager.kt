package com.kiters.wear.sensors

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import com.kiters.wear.model.ImuSample
import com.kiters.wear.model.Vector3

/**
 * Manages IMU sensor data (linear acceleration + gyroscope + gravity) at ~50 Hz
 * plus barometric pressure. Faithful port of the watchOS MotionManager.
 *
 * Unit conversions to match the engine's watch-native contract:
 *   linear accel  : m/s^2 -> g  (divide by 9.81; gravity already removed)
 *   gyroscope     : rad/s (Android native — no conversion)
 *   gravity       : m/s^2 -> g  (divide by 9.81; ~unit vector)
 *   pressure      : hPa (Android native)
 */
class MotionManager(context: Context) : SensorEventListener {

    private val appContext = context.applicationContext
    private val sensorManager =
        appContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    private val linearAccel: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
    private val gyroscope: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val gravitySensor: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_GRAVITY)
    private val pressureSensor: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_PRESSURE)

    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    @Volatile var isTracking = false
        private set

    val isDeviceMotionAvailable: Boolean get() = linearAccel != null && gyroscope != null
    val isBarometerAvailable: Boolean get() = pressureSensor != null

    private val sampleRateHz = 50.0
    private val samplingPeriodUs = (1_000_000.0 / sampleRateHz).toInt()  // 20000 us

    private val bufferSize = 250
    private val sampleBuffer = ArrayList<ImuSample>(bufferSize)

    // Latest values held between events (different sensors fire at different rates)
    @Volatile private var gyroX = 0.0
    @Volatile private var gyroY = 0.0
    @Volatile private var gyroZ = 0.0
    @Volatile private var gravX = 0.0
    @Volatile private var gravY = 0.0
    @Volatile private var gravZ = -1.0
    @Volatile private var pressureHPa: Double? = null

    var onImuSample: ((ImuSample) -> Unit)? = null
    var onImuBatch: ((List<ImuSample>) -> Unit)? = null

    fun startTracking() {
        if (isTracking) return
        if (!isDeviceMotionAvailable) return
        val t = HandlerThread("motion-sensors").also { it.start() }
        thread = t
        handler = Handler(t.looper)
        sensorManager.registerListener(this, linearAccel, samplingPeriodUs, handler)
        sensorManager.registerListener(this, gyroscope, samplingPeriodUs, handler)
        gravitySensor?.let { sensorManager.registerListener(this, it, samplingPeriodUs, handler) }
        pressureSensor?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL, handler)
        }
        isTracking = true
    }

    fun stopTracking() {
        if (!isTracking) return
        sensorManager.unregisterListener(this)
        isTracking = false
        if (sampleBuffer.isNotEmpty()) {
            onImuBatch?.invoke(ArrayList(sampleBuffer))
            sampleBuffer.clear()
        }
        pressureHPa = null
        thread?.quitSafely()
        thread = null
        handler = null
    }

    fun pauseTracking() = stopTracking()
    fun resumeTracking() = startTracking()

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_GYROSCOPE -> {
                gyroX = event.values[0].toDouble()
                gyroY = event.values[1].toDouble()
                gyroZ = event.values[2].toDouble()
            }
            Sensor.TYPE_GRAVITY -> {
                gravX = event.values[0].toDouble() / 9.81
                gravY = event.values[1].toDouble() / 9.81
                gravZ = event.values[2].toDouble() / 9.81
            }
            Sensor.TYPE_PRESSURE -> {
                pressureHPa = event.values[0].toDouble()
            }
            Sensor.TYPE_LINEAR_ACCELERATION -> emitSample(event)
        }
    }

    private fun emitSample(event: SensorEvent) {
        val sample = ImuSample(
            timestamp = event.timestamp / 1_000_000_000.0,   // ns -> s (monotonic)
            accelerationX = event.values[0].toDouble() / 9.81,
            accelerationY = event.values[1].toDouble() / 9.81,
            accelerationZ = event.values[2].toDouble() / 9.81,
            rotationX = gyroX, rotationY = gyroY, rotationZ = gyroZ,
            gravity = Vector3(gravX, gravY, gravZ),
            pressure = pressureHPa,
        )
        onImuSample?.invoke(sample)
        sampleBuffer.add(sample)
        if (sampleBuffer.size >= bufferSize) {
            onImuBatch?.invoke(ArrayList(sampleBuffer))
            sampleBuffer.clear()
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
