package com.example.runningtracker.service

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.GnssStatus
import android.location.Location
import android.location.LocationManager
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.example.runningtracker.R
import com.example.runningtracker.data.db.AppDatabase
import com.example.runningtracker.data.filter.WeightedMovingAverageFilter
import com.example.runningtracker.data.model.RunEntity
import com.example.runningtracker.data.model.TrackPointEntity
import com.example.runningtracker.sensor.CadenceDetector
import com.example.runningtracker.ui.MainActivity
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

data class LocationDiagnostics(
    val hardwareModel: String = "Detecting...",
    val activeProvider: String = "None",
    val availableProviders: String = "Detecting...",
    val satellitesVisible: Int = 0,
    val satellitesUsed: Int = 0,
    val isDualFrequencySupported: Boolean = false
)

class TrackingService : Service() {

    private val binder = LocalBinder()
    private lateinit var locationManager: LocationManager
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private lateinit var locationCallback: LocationCallback
    private var wakeLock: PowerManager.WakeLock? = null
    private val serviceScope = CoroutineScope(Dispatchers.IO + Job())

    private val filter = WeightedMovingAverageFilter()
    private lateinit var cadenceDetector: CadenceDetector

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

    private val _currentLocation = MutableStateFlow<Location?>(null)
    val currentLocation: StateFlow<Location?> = _currentLocation

    private val _diagnostics = MutableStateFlow(LocationDiagnostics())
    val diagnostics: StateFlow<LocationDiagnostics> = _diagnostics
    private var gnssCallback: GnssStatus.Callback? = null

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
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        cadenceDetector = CadenceDetector(this)
        createNotificationChannel()

        locationCallback = object : LocationCallback() {
            override fun onLocationResult(locationResult: LocationResult) {
                for (location in locationResult.locations) {
                    processLocation(location)
                }
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            gnssCallback = object : GnssStatus.Callback() {
                override fun onSatelliteStatusChanged(status: GnssStatus) {
                    var dualFreq = false
                    var used = 0
                    for (i in 0 until status.satelliteCount) {
                        if (status.usedInFix(i)) used++
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            if (status.hasCarrierFrequencyHz(i)) {
                                val freq = status.getCarrierFrequencyHz(i)
                                if (freq > 1.1e9f && freq < 1.3e9f) {
                                    dualFreq = true
                                }
                            }
                        }
                    }
                    _diagnostics.value = _diagnostics.value.copy(
                        satellitesVisible = status.satelliteCount,
                        satellitesUsed = used,
                        isDualFrequencySupported = _diagnostics.value.isDualFrequencySupported || dualFreq
                    )
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    @SuppressLint("MissingPermission")
    fun startWarmUp() {
        _trackingState.value = TrackingState.ACQUIRING_SIGNAL
        
        val notification = buildNotification("Acquiring Location Signal...")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "RunningTracker::WakeLock").apply {
            acquire(10 * 60 * 1000L)
        }

        // Pull Hardware Info using native LocationManager
        val providers = locationManager.getProviders(true).joinToString(", ")
        var hardware = "Unknown"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            hardware = locationManager.gnssHardwareModelName ?: "Unknown/Not Exposed"
        }
        _diagnostics.value = _diagnostics.value.copy(
            hardwareModel = hardware,
            availableProviders = providers
        )

        // Attach native GNSS listener for diagnostics
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            gnssCallback?.let { locationManager.registerGnssStatusCallback(it, null) }
        }

        // Start Google Fused Location Tracking
        val locationRequest = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
            .setMinUpdateIntervalMillis(1000L)
            .build()
            
        fusedLocationClient.requestLocationUpdates(
            locationRequest,
            locationCallback,
            Looper.getMainLooper()
        )
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
        
        // Unregister both Fused and native listeners
        fusedLocationClient.removeLocationUpdates(locationCallback)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            gnssCallback?.let { locationManager.unregisterGnssStatusCallback(it) }
        }

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
            }
        }
    }

    private fun processLocation(location: Location) {
        _currentAccuracy.value = location.accuracy
        _diagnostics.value = _diagnostics.value.copy(activeProvider = location.provider ?: "fused")

        val filtered = filter.filter(location) ?: return
        _currentLocation.value = filtered

        if (_trackingState.value == TrackingState.RUNNING) {
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
