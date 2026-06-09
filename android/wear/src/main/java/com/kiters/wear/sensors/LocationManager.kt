package com.kiters.wear.sensors

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Looper
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.kiters.wear.model.GpsPoint

/**
 * GPS location tracking via FusedLocationProviderClient. Faithful port of the
 * watchOS LocationManager: best-accuracy, every fix, filtering out fixes with
 * horizontal accuracy >= 20 m (the same gate as the Swift processLocation).
 */
class LocationManager(context: Context) {

    private val appContext = context.applicationContext
    private val client: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(appContext)

    @Volatile var isTracking = false
        private set

    var onLocationUpdate: ((GpsPoint) -> Unit)? = null

    private val request: LocationRequest =
        LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
            .setMinUpdateIntervalMillis(500L)
            .build()

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            val loc = result.lastLocation ?: return
            // Mirror the Swift gate: reject invalid / inaccurate fixes (>= 20 m).
            if (!loc.hasAccuracy() || loc.accuracy <= 0f || loc.accuracy >= 20f) return
            val point = GpsPoint(
                timestampMs = if (loc.time > 0) loc.time else System.currentTimeMillis(),
                latitude = loc.latitude,
                longitude = loc.longitude,
                altitude = if (loc.hasAltitude()) loc.altitude else 0.0,
                speed = if (loc.hasSpeed()) maxOf(0.0, loc.speed.toDouble()) else 0.0,
                course = if (loc.hasBearing()) loc.bearing.toDouble() else -1.0,
                horizontalAccuracy = loc.accuracy.toDouble(),
                verticalAccuracy = if (loc.hasVerticalAccuracy())
                    loc.verticalAccuracyMeters.toDouble() else 0.0,
            )
            onLocationUpdate?.invoke(point)
        }
    }

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    fun startTracking() {
        if (isTracking || !hasPermission()) return
        client.requestLocationUpdates(request, callback, Looper.getMainLooper())
        isTracking = true
    }

    fun stopTracking() {
        if (!isTracking) return
        client.removeLocationUpdates(callback)
        isTracking = false
    }

    fun pauseTracking() = stopTracking()
    fun resumeTracking() = startTracking()
}
