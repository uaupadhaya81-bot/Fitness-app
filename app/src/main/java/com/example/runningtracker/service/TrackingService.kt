package com.example.runningtracker.service

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.example.runningtracker.R
import com.example.runningtracker.data.filter.WeightedMovingAverageFilter
import com.example.runningtracker.sensor.BarometerElevationTracker
import com.example.runningtracker.sensor.CadenceDetector
import com.example.runningtracker.ui.MainActivity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class TrackingService : Service(), LocationListener {

    private val binder = LocalBinder()
    private lateinit var locationManager: LocationManager
    private var wakeLock: PowerManager.WakeLock? = null

    private val filter = WeightedMovingAverageFilter()
    private lateinit var cadenceDetector: CadenceDetector
    private lateinit var barometerTracker: BarometerElevationTracker

    private val _trackingState = MutableStateFlow(TrackingState.IDLE)
    val trackingState: StateFlow<TrackingState> = _trackingState

    private val _currentAccuracy = MutableStateFlow(100.0f)
    val currentAccuracy: StateFlow<Float> = _currentAccuracy

    private val _totalDistanceMeters = MutableStateFlow(0.0)
    val totalDistanceMeters: StateFlow<Double> = _totalDistanceMeters

    private var lastLocation: Location? = null

    inner class LocalBinder : Binder() {
        fun getService(): TrackingService = this@TrackingService
    }

    override fun onCreate() {
        super.onCreate()
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        cadenceDetector = CadenceDetector(this)
        barometerTracker = BarometerElevationTracker(this)
        createNotificationChannel()
    }

    override fun onBind(intent: Intent?): IBinder = binder

    @SuppressLint("MissingPermission")
    fun startWarmUp() {
        _trackingState.value = TrackingState.ACQUIRING_SIGNAL
        
        val notification = buildNotification("Acquiring GPS Signal...")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "RunningTracker::WakeLock").apply {
            acquire(10 * 60 * 1000L)
        }

        if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            locationManager.requestLocationUpdates(
                LocationManager.GPS_PROVIDER,
                1000L,
                0f,
                this
            )
        }
    }

    fun startRun() {
        if (_trackingState.value == TrackingState.ACQUIRING_SIGNAL || _trackingState.value == TrackingState.PAUSED) {
            _trackingState.value = TrackingState.RUNNING
            cadenceDetector.start()
            barometerTracker.start()
            updateNotification("Run in Progress")
        }
    }

    fun pauseRun() {
        if (_trackingState.value == TrackingState.RUNNING) {
            _trackingState.value = TrackingState.PAUSED
            updateNotification("Run Paused")
        }
    }

    fun stopRun() {
        _trackingState.value = TrackingState.STOPPED
        cadenceDetector.stop()
        barometerTracker.stop()
        locationManager.removeUpdates(this)
        filter.reset()
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onLocationChanged(location: Location) {
        _currentAccuracy.value = location.accuracy

        if (_trackingState.value == TrackingState.ACQUIRING_SIGNAL) {
            return
        }

        if (_trackingState.value == TrackingState.RUNNING) {
            val filtered = filter.filter(location) ?: return

            if (filtered.hasSpeed() && filtered.speed < 0.5f) {
                return
            }

            lastLocation?.let { prev ->
                val distance = prev.distanceTo(filtered)
                if (distance > 0.5) {
                    _totalDistanceMeters.value += distance
                }
            }
            lastLocation = filtered
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Running Tracker Service",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(contentText: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Running Tracker")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        private const val CHANNEL_ID = "running_tracker_channel"
        private const val NOTIFICATION_ID = 1001
    }
}
