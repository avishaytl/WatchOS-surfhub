package com.spoteq.wear.sensors

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.health.services.client.HealthServices
import androidx.health.services.client.MeasureCallback
import androidx.health.services.client.data.Availability
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.DeltaDataType

/**
 * Live heart-rate via Wear OS Health Services MeasureClient. Pragmatic
 * mapping of the watchOS WorkoutManager — Android's MeasureClient delivers
 * live BPM directly (the watchOS app's calories metric is not shown in the
 * UI, so it is omitted here).
 *
 * Requires BODY_SENSORS permission at runtime.
 */
class WorkoutManager(context: Context) {

    private val appContext = context.applicationContext
    private val measureClient = try {
        HealthServices.getClient(appContext).measureClient
    } catch (e: Throwable) {
        Log.w(TAG, "Health Services unavailable", e); null
    }

    @Volatile var heartRate: Double = 0.0
        private set
    @Volatile var activeCalories: Double = 0.0
        private set

    var onHeartRate: ((Double) -> Unit)? = null

    private var registered = false

    private val callback = object : MeasureCallback {
        override fun onAvailabilityChanged(dataType: DeltaDataType<*, *>, availability: Availability) {}

        override fun onDataReceived(data: DataPointContainer) {
            val points = data.getData(DataType.HEART_RATE_BPM)
            val bpm = points.lastOrNull()?.value ?: return
            if (bpm > 0) {
                heartRate = bpm
                onHeartRate?.invoke(bpm)
            }
        }
    }

    private fun hasBodySensors(): Boolean =
        ContextCompat.checkSelfPermission(appContext, Manifest.permission.BODY_SENSORS) ==
            PackageManager.PERMISSION_GRANTED

    fun startWorkout() {
        val client = measureClient ?: return
        if (registered || !hasBodySensors()) return
        try {
            client.registerMeasureCallback(DataType.HEART_RATE_BPM, callback)
            registered = true
            Log.d(TAG, "Heart-rate measure callback registered")
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to register HR callback", e)
        }
    }

    fun pauseWorkout() {}
    fun resumeWorkout() {}

    fun endWorkout() {
        val client = measureClient ?: return
        if (!registered) return
        try {
            client.unregisterMeasureCallbackAsync(DataType.HEART_RATE_BPM, callback)
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to unregister HR callback", e)
        }
        registered = false
        heartRate = 0.0
        activeCalories = 0.0
    }

    companion object {
        private const val TAG = "WorkoutManager"
    }
}
