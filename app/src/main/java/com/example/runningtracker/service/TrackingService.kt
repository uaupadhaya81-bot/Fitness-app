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
import com.example.runningtracker.data.db.AppDatabase
import com.example.runningtracker.data.filter.WeightedMovingAverageFilter
import com.example.runningtracker.data.model.RunEntity
import com.example.runningtracker.data.model.TrackPointEntity
import com.example.runningtracker.sensor.BarometerElevationTracker
import com.example.runningtracker.sensor.CadenceDetector
import com.example.runningtracker.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class TrackingService : Service(), LocationListener {

    private val binder = LocalBinder()
    private lateinit var locationManager: LocationManager
    private var wakeLock: PowerManager.WakeLock? = null
    private val serviceScope = CoroutineScope(Dispatchers.IO + Job())

    private val filter = WeightedMovingAverageFilter()
    private lateinit var cadenceDetector: CadenceDetector
    private lateinit var barometerTracker: BarometerElevationTracker

    private val _trackingState = MutableStateFlow(TrackingState.IDLE)
    val trackingState: StateFlow<TrackingState> = _trackingState

    private val _currentAccuracy = MutableStateFlow(100.0f)
    val currentAccuracy: StateFlow<Float> = _currentAccuracy

    private val _totalDistanceMeters = MutableStateFlow(0.0)
    val totalDistanceMeters: StateFlow<Double> = _totalDistanceMeters

    private val _durationMillis = MutableStateFlow(0L)
    val durationMillis: StateFlow<Long> = _durationMillis

    private val _currentPaceSecPerKm = MutableStateFlow(0.0)
    val currentPaceSecPerKm: StateFlow<Double> = _currentPaceSecPerKm

    private val _currentCadence = MutableStateFlow(0)
    val currentCadence: StateFlow<Int> = _currentCadence

    private val _currentElevation = MutableStateFlow(0.0)
    val currentElevation: StateFlow<Double> = _currentElevation

    private val _currentLocation = MutableStateFlow<Location?>(null)
    val currentLocation: StateFlow<Location?> = _currentLocation

    private val recordedTrackPoints = mutableListOf<TrackPointEntity>()
    private var lastLocation: Location? = null
    private var timerJob: Job? = null
    private var currentRunId: Long = 0L

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
            if (_trackingState.value == TrackingState.ACQUIRING_SIGNAL) {
                _durationMillis.value = 0L
                _totalDistanceMeters.value = 0.0
                recordedTrackPoints.clear()
                serviceScope.launch {
                    val run = RunEntity(startTimeStamp = System.currentTimeMillis())
                    currentRunId = AppDatabase.getInstance(applicationContext).runDao().insertRun(run)
                }
            }

            _trackingState.value = TrackingState.RUNNING
            cadenceDetector.start()
            barometerTracker.start()
            startTimer()
            updateNotification("Run in Progress")
        }
    }

    fun pauseRun() {
        if (_trackingState.value == TrackingState.RUNNING) {
            _trackingState.value = TrackingState.PAUSED
            timerJob?.cancel()
            updateNotification("Run Paused")
        }
    }

    fun stopRun() {
        _trackingState.value = TrackingState.STOPPED
        timerJob?.cancel()
        cadenceDetector.stop()
        barometerTracker.stop()
        locationManager.removeUpdates(this)

        serviceScope.launch {
            if (currentRunId != 0L) {
                val db = AppDatabase.getInstance(applicationContext)
                db.trackPointDao().insertTrackPoints(recordedTrackPoints)

                val run = db.runDao().getRunById(currentRunId)
                run?.let {
                    it.endTimeStamp = System.currentTimeMillis()
                    it.distanceMeters = _totalDistanceMeters.value
                    it.durationMillis = _durationMillis.value
                    it.avgCadenceSpm = if (recordedTrackPoints.isNotEmpty()) recordedTrackPoints.map { pt -> pt.cadence }.average().toInt() else 0
                    db.runDao().updateRun(it)
                }
            }
        }

        filter.reset()
        wakeLock?.let { if (it.isHeld) it.release() }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startTimer() {
        timerJob?.cancel()
        timerJob = serviceScope.launch {
            while (_trackingState.value == TrackingState.RUNNING) {
                delay(1000L)
                _durationMillis.value += 1000L
                _currentCadence.value = cadenceDetector.currentCadenceSpm
                _currentElevation.value = barometerTracker.currentRelativeElevationMeters
            }
        }
    }

    override fun onLocationChanged(location: Location) {
        _currentAccuracy.value = location.accuracy

        if (_trackingState.value == TrackingState.RUNNING) {
            val filtered = filter.filter(location) ?: return
            _currentLocation.value = filtered

            if (filtered.hasSpeed() && filtered.speed < 0.5f) {
                return
            }

            if (filtered.hasSpeed() && filtered.speed >= 0.5f) {
                val speedMps = filtered.speed
                _currentPaceSecPerKm.value = 1000.0 / speedMps
            }

            lastLocation?.let { prev ->
                val distance = prev.distanceTo(filtered)
                if (distance > 0.5) {
                    _totalDistanceMeters.value += distance
                }
            }
            lastLocation = filtered

            if (currentRunId != 0L) {
                recordedTrackPoints.add(
                    TrackPointEntity(
                        runId = currentRunId,
                        timestamp = System.currentTimeMillis(),
                        latitude = filtered.latitude,
                        longitude = filtered.longitude,
                        altitude = filtered.altitude,
                        accuracy = filtered.accuracy,
                        speed = filtered.speed,
                        relativeElevation = barometerTracker.currentRelativeElevationMeters,
                        cadence = cadenceDetector.currentCadenceSpm
                    )
                )
            }
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
