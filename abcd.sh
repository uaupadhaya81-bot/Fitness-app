#!/bin/bash

echo "Starting AI patching process..."

# 1. Remove Barometer Sensor Code
rm -f app/src/main/java/com/example/runningtracker/sensor/BarometerElevationTracker.kt

# 2. Update RunEntity
cat << 'EOF' > app/src/main/java/com/example/runningtracker/data/model/RunEntity.kt
package com.example.runningtracker.data.model

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "runs")
data class RunEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val startTimeStamp: Long,
    var endTimeStamp: Long = 0,
    var distanceMeters: Double = 0.0,
    var durationMillis: Long = 0,
    var avgPaceSecPerKm: Double = 0.0,
    var maxPaceSecPerKm: Double = 0.0,
    var avgCadenceSpm: Int = 0
)
EOF

# 3. Update TrackPointEntity
cat << 'EOF' > app/src/main/java/com/example/runningtracker/data/model/TrackPointEntity.kt
package com.example.runningtracker.data.model

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "track_points",
    foreignKeys = [
        ForeignKey(
            entity = RunEntity::class,
            parentColumns = ["id"],
            childColumns = ["runId"],
            onDelete = ForeignKey.CASCADE
        )
    ],
    indices = [Index(value = ["runId"])]
)
data class TrackPointEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val runId: Long,
    val timestamp: Long,
    val latitude: Double,
    val longitude: Double,
    val altitude: Double,
    val accuracy: Float,
    val speed: Float,
    val cadence: Int
)
EOF

# 4. Update Database for Destructive Migration
cat << 'EOF' > app/src/main/java/com/example/runningtracker/data/db/AppDatabase.kt
package com.example.runningtracker.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import com.example.runningtracker.data.model.RunEntity
import com.example.runningtracker.data.model.TrackPointEntity

@Database(
    entities = [RunEntity::class, TrackPointEntity::class],
    version = 2,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {

    abstract fun runDao(): RunDao
    abstract fun trackPointDao(): TrackPointDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        fun getInstance(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "running_tracker.db"
                )
                .fallbackToDestructiveMigration()
                .build()
                INSTANCE = instance
                instance
            }
        }
    }
}
EOF

# 5. Fix Moving Average Filter
cat << 'EOF' > app/src/main/java/com/example/runningtracker/data/filter/WeightedMovingAverageFilter.kt
package com.example.runningtracker.data.filter

import android.location.Location
import java.util.LinkedList

class WeightedMovingAverageFilter(private val windowSize: Int = 5) {

    private val window: LinkedList<Location> = LinkedList()

    fun filter(location: Location): Location? {
        if (location.accuracy > 50.0f) {
            return location 
        }

        window.addLast(location)
        if (window.size > windowSize) {
            window.removeFirst()
        }

        var totalWeight = 0.0
        var weightedLat = 0.0
        var weightedLng = 0.0
        var weightedAlt = 0.0

        for (loc in window) {
            val weight = 1.0 / (loc.accuracy * loc.accuracy).coerceAtLeast(0.1f)
            totalWeight += weight
            weightedLat += loc.latitude * weight
            weightedLng += loc.longitude * weight
            weightedAlt += loc.altitude * weight
        }

        if (totalWeight <= 0.0) return location

        val filteredLocation = Location(location)
        filteredLocation.latitude = weightedLat / totalWeight
        filteredLocation.longitude = weightedLng / totalWeight
        filteredLocation.altitude = weightedAlt / totalWeight
        return filteredLocation
    }

    fun reset() {
        window.clear()
    }
}
EOF

# 6. Update TrackingService (WITH updateNotification fix)
cat << 'EOF' > app/src/main/java/com/example/runningtracker/service/TrackingService.kt
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

        if (locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
            locationManager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 1000L, 0f, this)
        }
        
        if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, this)
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
            }
        }
    }

    override fun onLocationChanged(location: Location) {
        _currentAccuracy.value = location.accuracy

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
EOF

# 7. Update Main Activity Layout 
cat << 'EOF' > app/src/main/res/layout/activity_main.xml
<?xml version="1.0" encoding="utf-8"?>
<RelativeLayout xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:app="http://schemas.android.com/apk/res-auto"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="#0F172A">

    <org.maplibre.android.maps.MapView
        android:id="@+id/mapView"
        android:layout_width="match_parent"
        android:layout_height="match_parent" />

    <LinearLayout
        android:id="@+id/topBar"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_alignParentTop="true"
        android:layout_margin="16dp"
        android:background="@drawable/card_background"
        android:elevation="8dp"
        android:orientation="horizontal"
        android:padding="12dp">

        <TextView
            android:id="@+id/tvStatus"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:text="STATUS: IDLE"
            android:textColor="#38BDF8"
            android:textSize="14sp"
            android:textStyle="bold" />

        <TextView
            android:id="@+id/tvAccuracy"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="GPS: --m"
            android:textColor="#94A3B8"
            android:textSize="14sp" />
    </LinearLayout>

    <LinearLayout
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:layout_below="@id/topBar"
        android:layout_alignParentEnd="true"
        android:layout_marginEnd="16dp"
        android:elevation="8dp"
        android:orientation="vertical">

        <com.google.android.material.floatingactionbutton.FloatingActionButton
            android:id="@+id/btnOfflineMaps"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:contentDescription="Download Offline Maps"
            app:backgroundTint="#1E293B"
            app:tint="#FFFFFF"
            app:srcCompat="@android:drawable/ic_menu_mapmode" />

        <com.google.android.material.floatingactionbutton.FloatingActionButton
            android:id="@+id/btnRecenter"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_marginTop="12dp"
            android:contentDescription="Recenter Map"
            app:backgroundTint="#1E293B"
            app:tint="#FFFFFF"
            app:srcCompat="@android:drawable/ic_menu_mylocation" />
    </LinearLayout>

    <LinearLayout
        android:id="@+id/dashboardCard"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_above="@id/controlButtons"
        android:layout_marginHorizontal="16dp"
        android:layout_marginBottom="12dp"
        android:background="@drawable/card_background"
        android:elevation="12dp"
        android:orientation="vertical"
        android:padding="20dp">

        <TextView
            android:id="@+id/tvDistance"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_gravity="center_horizontal"
            android:text="0.00 km"
            android:textColor="#FFFFFF"
            android:textSize="44sp"
            android:textStyle="bold" />

        <LinearLayout
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="16dp"
            android:orientation="horizontal">

            <LinearLayout
                android:layout_width="0dp"
                android:layout_height="wrap_content"
                android:layout_weight="1"
                android:gravity="center"
                android:orientation="vertical">

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="TIME"
                    android:textColor="#94A3B8"
                    android:textSize="11sp" />

                <TextView
                    android:id="@+id/tvTime"
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="00:00"
                    android:textColor="#FFFFFF"
                    android:textSize="18sp"
                    android:textStyle="bold" />
            </LinearLayout>

            <LinearLayout
                android:layout_width="0dp"
                android:layout_height="wrap_content"
                android:layout_weight="1"
                android:gravity="center"
                android:orientation="vertical">

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="PACE"
                    android:textColor="#94A3B8"
                    android:textSize="11sp" />

                <TextView
                    android:id="@+id/tvPace"
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="--:--"
                    android:textColor="#FFFFFF"
                    android:textSize="18sp"
                    android:textStyle="bold" />
            </LinearLayout>

            <LinearLayout
                android:layout_width="0dp"
                android:layout_height="wrap_content"
                android:layout_weight="1"
                android:gravity="center"
                android:orientation="vertical">

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="CADENCE"
                    android:textColor="#94A3B8"
                    android:textSize="11sp" />

                <TextView
                    android:id="@+id/tvCadence"
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="0 spm"
                    android:textColor="#FFFFFF"
                    android:textSize="18sp"
                    android:textStyle="bold" />
            </LinearLayout>

        </LinearLayout>
    </LinearLayout>

    <LinearLayout
        android:id="@+id/controlButtons"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_alignParentBottom="true"
        android:layout_marginHorizontal="16dp"
        android:layout_marginBottom="20dp"
        android:elevation="12dp"
        android:orientation="vertical">

        <Button
            android:id="@+id/btnWarmUp"
            android:layout_width="match_parent"
            android:layout_height="54dp"
            android:backgroundTint="#0284C7"
            android:text="Acquire GPS Warmup"
            android:textColor="#FFFFFF"
            android:textSize="15sp"
            android:textStyle="bold" />

        <LinearLayout
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="8dp"
            android:orientation="horizontal">

            <Button
                android:id="@+id/btnStart"
                android:layout_width="0dp"
                android:layout_height="54dp"
                android:layout_marginEnd="4dp"
                android:layout_weight="1"
                android:backgroundTint="#16A34A"
                android:enabled="false"
                android:text="Start Run"
                android:textColor="#FFFFFF"
                android:textSize="15sp"
                android:textStyle="bold" />

            <Button
                android:id="@+id/btnStop"
                android:layout_width="0dp"
                android:layout_height="54dp"
                android:layout_marginStart="4dp"
                android:layout_weight="1"
                android:backgroundTint="#DC2626"
                android:enabled="false"
                android:text="Stop Run"
                android:textColor="#FFFFFF"
                android:textSize="15sp"
                android:textStyle="bold" />

        </LinearLayout>
    </LinearLayout>

</RelativeLayout>
EOF

# 8. Update MainActivity.kt
cat << 'EOF' > app/src/main/java/com/example/runningtracker/ui/MainActivity.kt
package com.example.runningtracker.ui

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.widget.Button
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.example.runningtracker.R
import com.example.runningtracker.service.TrackingService
import com.example.runningtracker.service.TrackingState
import com.google.android.material.floatingactionbutton.FloatingActionButton
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.location.LocationComponentActivationOptions
import org.maplibre.android.location.modes.CameraMode
import org.maplibre.android.location.modes.RenderMode
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point

class MainActivity : AppCompatActivity() {

    private var trackingService: TrackingService? = null
    private var isBound = false

    private lateinit var mapView: MapView
    private var mapLibreMap: MapLibreMap? = null
    private var routeSource: GeoJsonSource? = null
    private val routePoints = mutableListOf<Point>()

    private lateinit var tvStatus: TextView
    private lateinit var tvAccuracy: TextView
    private lateinit var tvDistance: TextView
    private lateinit var tvTime: TextView
    private lateinit var tvPace: TextView
    private lateinit var tvCadence: TextView

    private lateinit var btnWarmUp: Button
    private lateinit var btnStart: Button
    private lateinit var btnStop: Button
    private lateinit var btnRecenter: FloatingActionButton
    private lateinit var btnOfflineMaps: FloatingActionButton

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        if (permissions.values.all { it }) {
            startAndBindService()
        }
    }

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as TrackingService.LocalBinder
            trackingService = binder.getService()
            isBound = true
            observeService()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            trackingService = null
            isBound = false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MapLibre.getInstance(this)
        setContentView(R.layout.activity_main)

        tvStatus = findViewById(R.id.tvStatus)
        tvAccuracy = findViewById(R.id.tvAccuracy)
        tvDistance = findViewById(R.id.tvDistance)
        tvTime = findViewById(R.id.tvTime)
        tvPace = findViewById(R.id.tvPace)
        tvCadence = findViewById(R.id.tvCadence)

        btnWarmUp = findViewById(R.id.btnWarmUp)
        btnStart = findViewById(R.id.btnStart)
        btnStop = findViewById(R.id.btnStop)
        btnRecenter = findViewById(R.id.btnRecenter)
        btnOfflineMaps = findViewById(R.id.btnOfflineMaps)

        mapView = findViewById(R.id.mapView)
        mapView.onCreate(savedInstanceState)

        mapView.getMapAsync { map ->
            mapLibreMap = map
            map.cameraPosition = CameraPosition.Builder().zoom(16.0).build()
            map.setStyle(Style.Builder().fromUri("https://tiles.openfreemap.org/styles/bright")) { style ->
                setupRouteLayer(style)
            }
        }

        btnWarmUp.setOnClickListener {
            checkPermissionsAndRun {
                startAndBindService()
            }
        }

        btnStart.setOnClickListener {
            if (trackingService?.trackingState?.value == TrackingState.RUNNING) {
                trackingService?.pauseRun()
            } else {
                trackingService?.startRun()
            }
        }

        btnStop.setOnClickListener {
            trackingService?.stopRun()
            if (isBound) {
                unbindService(serviceConnection)
                isBound = false
            }
            routePoints.clear()
            updatePolyline()
        }

        btnRecenter.setOnClickListener {
            val map = mapLibreMap ?: return@setOnClickListener
            val loc = trackingService?.currentLocation?.value ?: map.locationComponent.lastKnownLocation
            if (loc != null) {
                map.animateCamera(CameraUpdateFactory.newLatLngZoom(LatLng(loc.latitude, loc.longitude), 16.0))
                map.locationComponent.cameraMode = CameraMode.TRACKING
            }
        }

        btnOfflineMaps.setOnClickListener {
            startActivity(Intent(this, OfflineMapActivity::class.java))
        }
    }

    private fun setupRouteLayer(style: Style) {
        routeSource = GeoJsonSource("route-source", Feature.fromGeometry(LineString.fromLngLats(routePoints)))
        style.addSource(routeSource!!)

        val lineLayer = LineLayer("route-layer", "route-source").apply {
            setProperties(
                PropertyFactory.lineColor(Color.parseColor("#0284C7")),
                PropertyFactory.lineWidth(7f),
                PropertyFactory.lineCap(Property.LINE_CAP_ROUND),
                PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND)
            )
        }
        style.addLayer(lineLayer)
        
        enableLocationComponent(style)
    }

    private fun enableLocationComponent(style: Style) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
            mapLibreMap?.locationComponent?.let { locationComponent ->
                val options = LocationComponentActivationOptions.builder(this, style).build()
                locationComponent.activateLocationComponent(options)
                locationComponent.isLocationComponentEnabled = true
                locationComponent.renderMode = RenderMode.COMPASS
            }
        }
    }

    private fun updatePolyline() {
        routeSource?.setGeoJson(Feature.fromGeometry(LineString.fromLngLats(routePoints)))
    }

    private fun startAndBindService() {
        val intent = Intent(this, TrackingService::class.java)
        startService(intent)
        bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
        trackingService?.startWarmUp()
        
        mapLibreMap?.style?.let { enableLocationComponent(it) }
    }

    private fun observeService() {
        val service = trackingService ?: return

        lifecycleScope.launch {
            service.trackingState.collectLatest { state ->
                tvStatus.text = "STATUS: ${state.name}"
                btnStart.isEnabled = (state == TrackingState.ACQUIRING_SIGNAL && service.currentAccuracy.value <= 30.0f) || state == TrackingState.RUNNING || state == TrackingState.PAUSED
                btnStart.text = if (state == TrackingState.RUNNING) "Pause Run" else "Start Run"
                btnStop.isEnabled = state == TrackingState.RUNNING || state == TrackingState.PAUSED
            }
        }

        lifecycleScope.launch {
            service.currentAccuracy.collectLatest { accuracy ->
                tvAccuracy.text = String.format("GPS: %.1fm", accuracy)
                if (service.trackingState.value == TrackingState.ACQUIRING_SIGNAL) {
                    btnStart.isEnabled = accuracy <= 30.0f
                }
            }
        }

        lifecycleScope.launch {
            service.totalDistanceMeters.collectLatest { dist ->
                tvDistance.text = String.format("%.2f km", dist / 1000.0)
            }
        }

        lifecycleScope.launch {
            service.durationMillis.collectLatest { millis ->
                val sec = (millis / 1000) % 60
                val min = (millis / (1000 * 60)) % 60
                val hr = millis / (1000 * 60 * 60)
                tvTime.text = if (hr > 0) String.format("%02d:%02d:%02d", hr, min, sec) else String.format("%02d:%02d", min, sec)
            }
        }

        lifecycleScope.launch {
            service.currentPaceSecPerKm.collectLatest { secPerKm ->
                if (secPerKm <= 0.0 || secPerKm > 3600.0) {
                    tvPace.text = "--:--"
                } else {
                    val min = (secPerKm / 60).toInt()
                    val sec = (secPerKm % 60).toInt()
                    tvPace.text = String.format("%d:%02d", min, sec)
                }
            }
        }

        lifecycleScope.launch {
            service.currentCadence.collectLatest { spm ->
                tvCadence.text = "$spm spm"
            }
        }

        lifecycleScope.launch {
            service.currentLocation.collectLatest { loc ->
                loc?.let {
                    if (service.trackingState.value == TrackingState.RUNNING) {
                        val point = Point.fromLngLat(it.longitude, it.latitude)
                        routePoints.add(point)
                        updatePolyline()
                    }
                }
            }
        }
    }

    private fun checkPermissionsAndRun(onGranted: () -> Unit) {
        val permissions = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        val notGranted = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (notGranted.isEmpty()) {
            onGranted()
        } else {
            permissionLauncher.launch(permissions.toTypedArray())
        }
    }

    override fun onStart() { super.onStart(); mapView.onStart() }
    override fun onResume() { super.onResume(); mapView.onResume() }
    override fun onPause() { super.onPause(); mapView.onPause() }
    override fun onStop() { super.onStop(); mapView.onStop() }
    override fun onLowMemory() { super.onLowMemory(); mapView.onLowMemory() }
    override fun onDestroy() {
        super.onDestroy()
        mapView.onDestroy()
        if (isBound) {
            unbindService(serviceConnection)
            isBound = false
        }
    }
    override fun onSaveInstanceState(outState: Bundle) { super.onSaveInstanceState(outState); mapView.onSaveInstanceState(outState) }
}
EOF

# 9. Update OfflineMapActivity XML
cat << 'EOF' > app/src/main/res/layout/activity_offline_map.xml
<?xml version="1.0" encoding="utf-8"?>
<RelativeLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="#0F172A">

    <org.maplibre.android.maps.MapView
        android:id="@+id/offlineMapView"
        android:layout_width="match_parent"
        android:layout_height="match_parent" />

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_alignParentBottom="true"
        android:layout_margin="16dp"
        android:background="@drawable/card_background"
        android:elevation="12dp"
        android:orientation="vertical"
        android:padding="20dp">

        <TextView
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="Offline Region Download"
            android:textColor="#FFFFFF"
            android:textSize="18sp"
            android:textStyle="bold" />

        <TextView
            android:id="@+id/tvDownloadStatus"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_marginTop="4dp"
            android:text="Tap 'Draw Box' then drag your finger on the map."
            android:textColor="#94A3B8"
            android:textSize="13sp" />

        <ProgressBar
            android:id="@+id/downloadProgress"
            style="?android:attr/progressBarStyleHorizontal"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="12dp"
            android:visibility="gone" />

        <LinearLayout
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="16dp"
            android:orientation="horizontal">

            <Button
                android:id="@+id/btnDrawMode"
                android:layout_width="0dp"
                android:layout_height="50dp"
                android:layout_marginEnd="4dp"
                android:layout_weight="1"
                android:backgroundTint="#475569"
                android:text="Draw Box"
                android:textColor="#FFFFFF"
                android:textStyle="bold" />

            <Button
                android:id="@+id/btnDownloadRegion"
                android:layout_width="0dp"
                android:layout_height="50dp"
                android:layout_marginStart="4dp"
                android:layout_weight="1"
                android:backgroundTint="#0284C7"
                android:enabled="false"
                android:text="Download"
                android:textColor="#FFFFFF"
                android:textStyle="bold" />
        </LinearLayout>
    </LinearLayout>

</RelativeLayout>
EOF

# 10. Update OfflineMapActivity Kotlin
cat << 'EOF' > app/src/main/java/com/example/runningtracker/ui/OfflineMapActivity.kt
package com.example.runningtracker.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PointF
import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.example.runningtracker.R
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import org.maplibre.android.offline.OfflineManager
import org.maplibre.android.offline.OfflineRegion
import org.maplibre.android.offline.OfflineRegionError
import org.maplibre.android.offline.OfflineRegionStatus
import org.maplibre.android.offline.OfflineTilePyramidRegionDefinition

class OfflineMapActivity : AppCompatActivity() {

    private lateinit var mapView: MapView
    private var mapLibreMap: MapLibreMap? = null
    private lateinit var btnDownload: Button
    private lateinit var btnDrawMode: Button
    private lateinit var progressDownload: ProgressBar
    private lateinit var tvStatus: TextView
    private lateinit var selectionView: SelectionView

    private var selectionBounds: LatLngBounds? = null
    private var isDrawingMode = false

    inner class SelectionView(context: Context) : View(context) {
        var startX = -1f
        var startY = -1f
        var endX = -1f
        var endY = -1f
        private val fillPaint = Paint().apply {
            color = Color.parseColor("#440284C7")
            style = Paint.Style.FILL
        }
        private val borderPaint = Paint().apply {
            color = Color.parseColor("#0284C7")
            style = Paint.Style.STROKE
            strokeWidth = 5f
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            if (startX != -1f && endX != -1f) {
                val left = Math.min(startX, endX)
                val top = Math.min(startY, endY)
                val right = Math.max(startX, endX)
                val bottom = Math.max(startY, endY)
                canvas.drawRect(left, top, right, bottom, fillPaint)
                canvas.drawRect(left, top, right, bottom, borderPaint)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MapLibre.getInstance(this)
        setContentView(R.layout.activity_offline_map)

        btnDownload = findViewById(R.id.btnDownloadRegion)
        btnDrawMode = findViewById(R.id.btnDrawMode)
        progressDownload = findViewById(R.id.downloadProgress)
        tvStatus = findViewById(R.id.tvDownloadStatus)

        mapView = findViewById(R.id.offlineMapView)
        mapView.onCreate(savedInstanceState)

        selectionView = SelectionView(this)
        val mapParent = mapView.parent as ViewGroup
        val index = mapParent.indexOfChild(mapView)
        mapParent.addView(selectionView, index + 1, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        mapView.getMapAsync { map ->
            mapLibreMap = map
            map.cameraPosition = CameraPosition.Builder().zoom(12.0).build()
            map.setStyle(Style.Builder().fromUri("https://tiles.openfreemap.org/styles/bright"))
        }

        btnDrawMode.setOnClickListener {
            isDrawingMode = true
            tvStatus.text = "Drag your finger to draw a box."
            selectionView.startX = -1f
            selectionView.endX = -1f
            selectionView.invalidate()
            btnDownload.isEnabled = false
        }

        selectionView.setOnTouchListener { _, event ->
            if (!isDrawingMode) return@setOnTouchListener false
            
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    selectionView.startX = event.x
                    selectionView.startY = event.y
                    selectionView.endX = event.x
                    selectionView.endY = event.y
                    selectionView.invalidate()
                }
                MotionEvent.ACTION_MOVE -> {
                    selectionView.endX = event.x
                    selectionView.endY = event.y
                    selectionView.invalidate()
                }
                MotionEvent.ACTION_UP -> {
                    isDrawingMode = false
                    val map = mapLibreMap
                    if (map != null) {
                        val pt1 = map.projection.fromScreenLocation(PointF(selectionView.startX, selectionView.startY))
                        val pt2 = map.projection.fromScreenLocation(PointF(selectionView.endX, selectionView.endY))
                        selectionBounds = LatLngBounds.Builder().include(pt1).include(pt2).build()
                        tvStatus.text = "Region mapped! Press Download."
                        btnDownload.isEnabled = true
                    }
                }
            }
            true
        }

        btnDownload.setOnClickListener { downloadVisibleRegion() }
    }

    private fun downloadVisibleRegion() {
        val map = mapLibreMap ?: return
        val bounds = selectionBounds ?: return
        
        val minZoom = map.cameraPosition.zoom.coerceAtMost(12.0)
        val maxZoom = 16.0
        val pixelRatio = resources.displayMetrics.density
        val styleUrl = "https://tiles.openfreemap.org/styles/bright"

        val definition = OfflineTilePyramidRegionDefinition(
            styleUrl, bounds, minZoom, maxZoom, pixelRatio
        )

        val metadata = "Custom Box Region".toByteArray(Charsets.UTF_8)

        btnDownload.isEnabled = false
        btnDrawMode.isEnabled = false
        progressDownload.visibility = View.VISIBLE
        tvStatus.text = "Downloading tiles..."

        val offlineManager = OfflineManager.getInstance(this)
        offlineManager.createOfflineRegion(definition, metadata, object : OfflineManager.CreateOfflineRegionCallback {
            override fun onCreate(offlineRegion: OfflineRegion) {
                offlineRegion.setObserver(object : OfflineRegion.OfflineRegionObserver {
                    override fun onStatusChanged(status: OfflineRegionStatus) {
                        val percentage = if (status.requiredResourceCount > 0) {
                            (100.0 * status.completedResourceCount / status.requiredResourceCount).toInt()
                        } else 0

                        runOnUiThread {
                            progressDownload.progress = percentage
                            tvStatus.text = "Downloading: $percentage% (${status.completedResourceCount}/${status.requiredResourceCount})"
                        }

                        if (status.isComplete) {
                            runOnUiThread {
                                progressDownload.visibility = View.GONE
                                btnDownload.isEnabled = true
                                btnDrawMode.isEnabled = true
                                tvStatus.text = "Map saved successfully!"
                                Toast.makeText(this@OfflineMapActivity, "Saved for Offline", Toast.LENGTH_SHORT).show()
                            }
                        }
                    }
                    override fun onError(error: OfflineRegionError) {
                        runOnUiThread {
                            btnDownload.isEnabled = true
                            btnDrawMode.isEnabled = true
                            tvStatus.text = "Error: ${error.reason}"
                        }
                    }
                    override fun mapboxTileCountLimitExceeded(limit: Long) {
                        runOnUiThread {
                            tvStatus.text = "Tile limit exceeded. Draw a smaller box."
                            btnDownload.isEnabled = true
                            btnDrawMode.isEnabled = true
                        }
                    }
                })
                offlineRegion.setDownloadState(OfflineRegion.STATE_ACTIVE)
            }
            override fun onError(error: String) {
                runOnUiThread {
                    btnDownload.isEnabled = true
                    btnDrawMode.isEnabled = true
                    tvStatus.text = "Creation Error: $error"
                }
            }
        })
    }

    override fun onStart() { super.onStart(); mapView.onStart() }
    override fun onResume() { super.onResume(); mapView.onResume() }
    override fun onPause() { super.onPause(); mapView.onPause() }
    override fun onStop() { super.onStop(); mapView.onStop() }
    override fun onLowMemory() { super.onLowMemory(); mapView.onLowMemory() }
    override fun onDestroy() { super.onDestroy(); mapView.onDestroy() }
    override fun onSaveInstanceState(outState: Bundle) { super.onSaveInstanceState(outState); mapView.onSaveInstanceState(outState) }
}
EOF

# 11. Log the fixes to the Changelog
echo "- Refactored Offline Maps with custom touch bounding-box logic." >> AI_CHANGELOG.md
echo "- Enabled MapLibre LocationComponent for live blue dot representation and auto-tracking." >> AI_CHANGELOG.md
echo "- Sped up GPS lock utilizing fallback Network_Provider & tuned tracking thresholds." >> AI_CHANGELOG.md
echo "- Removed Barometer dependency and UI (optimized for hardware like Redmi Note 10S) and applied Room Destructive Migration." >> AI_CHANGELOG.md
echo "- Fixed unresolved reference updateNotification compilation error." >> AI_CHANGELOG.md

echo "All AI patches applied successfully!"
