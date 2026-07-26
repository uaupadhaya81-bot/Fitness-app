#!/usr/bin/env bash
set -e

echo "Creating package directory structure..."
mkdir -p app/src/main/java/com/example/runningtracker/data/model
mkdir -p app/src/main/java/com/example/runningtracker/data/db
mkdir -p app/src/main/java/com/example/runningtracker/data/filter
mkdir -p app/src/main/java/com/example/runningtracker/sensor
mkdir -p app/src/main/java/com/example/runningtracker/service
mkdir -p app/src/main/java/com/example/runningtracker/export
mkdir -p app/src/main/java/com/example/runningtracker/ui
mkdir -p app/src/main/res/drawable
mkdir -p app/src/main/res/layout
mkdir -p app/src/main/res/values

# 1. Update Gradle Build Configuration
cat << 'EOF' > app/build.gradle.kts
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("kotlin-kapt")
}

android {
    namespace = "com.example.runningtracker"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.example.runningtracker"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"

        ndk {
            abiFilters.add("arm64-v8a")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")

    // Lifecycle & Activity KTX
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.activity:activity-ktx:1.8.2")

    // Room Database
    val roomVersion = "2.6.1"
    implementation("androidx.room:room-runtime:$roomVersion")
    implementation("androidx.room:room-ktx:$roomVersion")
    kapt("androidx.room:room-compiler:$roomVersion")

    // MapLibre Vector Map Engine
    implementation("org.maplibre.gl:android-sdk:10.2.0")
}
EOF

# 2. AI Instructions & History Documentation
cat << 'EOF' > AI_INSTRUCTIONS.md
# High-Precision Offline Running Tracker Architecture

This repository contains a lightweight, 100% offline, high-precision Android running tracker application.

## Core Architectural Modules
1. **Data Layer (`data`)**: Room entities (`RunEntity`, `TrackPointEntity`), DAOs (`RunDao`, `TrackPointDao`), and database instance (`AppDatabase`).
2. **Signal Filtering (`data/filter`)**: `WeightedMovingAverageFilter` to filter raw satellite coordinates based on accuracy weights.
3. **Hardware Sensors (`sensor`)**: `CadenceDetector` for step peak detection (120-210 spm range) and `BarometerElevationTracker` for relative altitude tracking via barometric pressure.
4. **Foreground Tracking Service (`service`)**: `TrackingService` managing GPS sampling (1Hz), auto-pause detection (<0.5 m/s), CPU WakeLock, live telemetry flows, and foreground state notifications with API 34 compliance.
5. **Data Export (`export`)**: `GpxExporter` and `TcxExporter` to export recorded workouts.
6. **User Interface (`ui`)**: 
   - `MainActivity`: Modern floating telemetry dashboard, live map polyline, and run controls.
   - `OfflineMapActivity`: Dedicated offline map downloader UI using MapLibre `OfflineManager`.
EOF

cat << 'EOF' > AI_CHANGELOG.md
- Implemented Offline Map Downloader UI (`OfflineMapActivity`) with MapLibre `OfflineManager` region downloader up to zoom 16.
- Overhauled UI to modern floating card layout with live Pace, Duration, Cadence, Elevation, and Route Polyline updates.
EOF

# 3. Room Entities
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
    var avgCadenceSpm: Int = 0,
    var elevationGainMeters: Double = 0.0,
    var elevationLossMeters: Double = 0.0
)
EOF

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
    val relativeElevation: Double,
    val cadence: Int
)
EOF

# 4. DAOs & Database Instance
cat << 'EOF' > app/src/main/java/com/example/runningtracker/data/db/RunDao.kt
package com.example.runningtracker.data.db

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.example.runningtracker.data.model.RunEntity

@Dao
interface RunDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertRun(run: RunEntity): Long

    @Update
    suspend fun updateRun(run: RunEntity)

    @Delete
    suspend fun deleteRun(run: RunEntity)

    @Query("SELECT * FROM runs ORDER BY startTimeStamp DESC")
    suspend fun getAllRuns(): List<RunEntity>

    @Query("SELECT * FROM runs WHERE id = :id")
    suspend fun getRunById(id: Long): RunEntity?
}
EOF

cat << 'EOF' > app/src/main/java/com/example/runningtracker/data/db/TrackPointDao.kt
package com.example.runningtracker.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.example.runningtracker.data.model.TrackPointEntity

@Dao
interface TrackPointDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertTrackPoint(trackPoint: TrackPointEntity): Long

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertTrackPoints(trackPoints: List<TrackPointEntity>)

    @Query("SELECT * FROM track_points WHERE runId = :runId ORDER BY timestamp ASC")
    suspend fun getTrackPointsForRun(runId: Long): List<TrackPointEntity>

    @Query("DELETE FROM track_points WHERE runId = :runId")
    suspend fun deletePointsForRun(runId: Long)
}
EOF

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
    version = 1,
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
                ).build()
                INSTANCE = instance
                instance
            }
        }
    }
}
EOF

# 5. GPS Noise Reduction Filter
cat << 'EOF' > app/src/main/java/com/example/runningtracker/data/filter/WeightedMovingAverageFilter.kt
package com.example.runningtracker.data.filter

import android.location.Location
import java.util.LinkedList

class WeightedMovingAverageFilter(private val windowSize: Int = 5) {

    private val window: LinkedList<Location> = LinkedList()

    fun filter(location: Location): Location? {
        if (location.accuracy > 30.0f) {
            return null
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

# 6. Hardware Sensor Trackers
cat << 'EOF' > app/src/main/java/com/example/runningtracker/sensor/CadenceDetector.kt
package com.example.runningtracker.sensor

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import kotlin.math.sqrt

class CadenceDetector(context: Context) : SensorEventListener {

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

    private val timestamps = ArrayList<Long>()
    private var lastPeakTimeMs: Long = 0L
    private var smoothedMagnitude: Double = 9.81
    private val alpha = 0.15

    var currentCadenceSpm: Int = 0
        private set

    fun start() {
        accelerometer?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
    }

    fun stop() {
        sensorManager?.unregisterListener(this)
        timestamps.clear()
        currentCadenceSpm = 0
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type != Sensor.TYPE_ACCELEROMETER) return

        val x = event.values[0]
        val y = event.values[1]
        val z = event.values[2]

        val mag = sqrt((x * x + y * y + z * z).toDouble())
        smoothedMagnitude = alpha * mag + (1.0 - alpha) * smoothedMagnitude

        val nowMs = System.currentTimeMillis()
        val deltaMag = mag - smoothedMagnitude

        if (deltaMag > 2.5 && (nowMs - lastPeakTimeMs) > 280) {
            lastPeakTimeMs = nowMs
            timestamps.add(nowMs)
            calculateCadence(nowMs)
        }
    }

    private fun calculateCadence(nowMs: Long) {
        val windowMs = 10000L
        timestamps.removeAll { nowMs - it > windowMs }

        if (timestamps.size >= 2) {
            val estimatedSpm = (timestamps.size * 60000L / windowMs).toInt()
            currentCadenceSpm = estimatedSpm.coerceIn(120, 210)
        } else {
            currentCadenceSpm = 0
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
EOF

cat << 'EOF' > app/src/main/java/com/example/runningtracker/sensor/BarometerElevationTracker.kt
package com.example.runningtracker.sensor

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager

class BarometerElevationTracker(context: Context) : SensorEventListener {

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val pressureSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_PRESSURE)

    private var initialPressure: Float? = null
    var currentRelativeElevationMeters: Double = 0.0
        private set

    val isSupported: Boolean
        get() = pressureSensor != null

    fun start() {
        pressureSensor?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
    }

    fun stop() {
        sensorManager?.unregisterListener(this)
        initialPressure = null
        currentRelativeElevationMeters = 0.0
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type != Sensor.TYPE_PRESSURE) return

        val pressureHpa = event.values[0]
        if (initialPressure == null) {
            initialPressure = pressureHpa
        }

        val base = initialPressure ?: return
        currentRelativeElevationMeters = SensorManager.getAltitude(
            SensorManager.PRESSURE_STANDARD_ATMOSPHERE,
            pressureHpa
        ) - SensorManager.getAltitude(
            SensorManager.PRESSURE_STANDARD_ATMOSPHERE,
            base
        ).toDouble()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
EOF

# 7. Tracking Service
cat << 'EOF' > app/src/main/java/com/example/runningtracker/service/TrackingState.kt
package com.example.runningtracker.service

enum class TrackingState {
    IDLE,
    ACQUIRING_SIGNAL,
    RUNNING,
    PAUSED,
    STOPPED
}
EOF

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
EOF

# 8. GPX & TCX Exporters
cat << 'EOF' > app/src/main/java/com/example/runningtracker/export/GpxExporter.kt
package com.example.runningtracker.export

import com.example.runningtracker.data.model.RunEntity
import com.example.runningtracker.data.model.TrackPointEntity
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

object GpxExporter {

    fun generateGpx(run: RunEntity, points: List<TrackPointEntity>): String {
        val isoFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }

        val sb = StringBuilder()
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        sb.append("<gpx version=\"1.1\" creator=\"RunningTrackerApp\"\n")
        sb.append("  xmlns=\"http://www.topografix.com/GPX/1/1\">\n")
        sb.append("  <metadata>\n")
        sb.append("    <time>").append(isoFormat.format(Date(run.startTimeStamp))).append("</time>\n")
        sb.append("  </metadata>\n")
        sb.append("  <trk>\n")
        sb.append("    <name>Run ").append(run.id).append("</name>\n")
        sb.append("    <trkseg>\n")

        for (pt in points) {
            sb.append("      <trkpt lat=\"").append(pt.latitude)
                .append("\" lon=\"").append(pt.longitude).append("\">\n")
            sb.append("        <ele>").append(pt.altitude).append("</ele>\n")
            sb.append("        <time>").append(isoFormat.format(Date(pt.timestamp))).append("</time>\n")
            sb.append("      </trkpt>\n")
        }

        sb.append("    </trkseg>\n")
        sb.append("  </trk>\n")
        sb.append("</gpx>")

        return sb.toString()
    }
}
EOF

cat << 'EOF' > app/src/main/java/com/example/runningtracker/export/TcxExporter.kt
package com.example.runningtracker.export

import com.example.runningtracker.data.model.RunEntity
import com.example.runningtracker.data.model.TrackPointEntity
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

object TcxExporter {

    fun generateTcx(run: RunEntity, points: List<TrackPointEntity>): String {
        val isoFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }

        val startTime = isoFormat.format(Date(run.startTimeStamp))
        val sb = StringBuilder()

        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        sb.append("<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\">\n")
        sb.append("  <Activities>\n")
        sb.append("    <Activity Sport=\"Running\">\n")
        sb.append("      <Id>").append(startTime).append("</Id>\n")
        sb.append("      <Lap StartTime=\"").append(startTime).append("\">\n")
        sb.append("        <TotalTimeSeconds>").append(run.durationMillis / 1000.0).append("</TotalTimeSeconds>\n")
        sb.append("        <DistanceMeters>").append(run.distanceMeters).append("</DistanceMeters>\n")
        sb.append("        <Track>\n")

        for (pt in points) {
            sb.append("          <Trackpoint>\n")
            sb.append("            <Time>").append(isoFormat.format(Date(pt.timestamp))).append("</Time>\n")
            sb.append("            <Position>\n")
            sb.append("              <LatitudeDegrees>").append(pt.latitude).append("</LatitudeDegrees>\n")
            sb.append("              <LongitudeDegrees>").append(pt.longitude).append("</LongitudeDegrees>\n")
            sb.append("            </Position>\n")
            sb.append("            <AltitudeMeters>").append(pt.altitude).append("</AltitudeMeters>\n")
            sb.append("            <DistanceMeters>0.0</DistanceMeters>\n")
            sb.append("            <Cadence>").append(pt.cadence).append("</Cadence>\n")
            sb.append("          </Trackpoint>\n")
        }

        sb.append("        </Track>\n")
        sb.append("      </Lap>\n")
        sb.append("    </Activity>\n")
        sb.append("  </Activities>\n")
        sb.append("</TrainingCenterDatabase>")

        return sb.toString()
    }
}
EOF

# 9. UI Layouts & Resources
cat << 'EOF' > app/src/main/res/drawable/ic_notification.xml
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
  <path
      android:fillColor="#FF007AFF"
      android:pathData="M12,2A10,10 0 1,0 22,12A10,10 0 0,0 12,2Z"/>
</vector>
EOF

cat << 'EOF' > app/src/main/res/drawable/card_background.xml
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android">
    <solid android:color="#F21E293B" />
    <corners android:radius="20dp" />
    <stroke android:width="1dp" android:color="#33FFFFFF" />
</shape>
EOF

cat << 'EOF' > app/src/main/res/layout/activity_main.xml
<?xml version="1.0" encoding="utf-8"?>
<RelativeLayout xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:mapbox="http://schemas.android.com/apk/res-auto"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="#0F172A">

    <!-- Map Canvas -->
    <org.maplibre.gl.maps.MapView
        android:id="@+id/mapView"
        android:layout_width="match_parent"
        android:layout_height="match_parent"
        mapbox:mapbox_cameraZoom="16" />

    <!-- Top Status Bar Overlay -->
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

    <!-- Floating Top Action Buttons -->
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
            mapbox:backgroundTint="#1E293B"
            mapbox:tint="#FFFFFF"
            mapbox:srcCompat="@android:drawable/ic_menu_mapmode" />

        <com.google.android.material.floatingactionbutton.FloatingActionButton
            android:id="@+id/btnRecenter"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_marginTop="12dp"
            android:contentDescription="Recenter Map"
            mapbox:backgroundTint="#1E293B"
            mapbox:tint="#FFFFFF"
            mapbox:srcCompat="@android:drawable/ic_menu_mylocation" />
    </LinearLayout>

    <!-- Floating Telemetry Glassmorphism Card -->
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

            <LinearLayout
                android:layout_width="0dp"
                android:layout_height="wrap_content"
                android:layout_weight="1"
                android:gravity="center"
                android:orientation="vertical">

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="ELEV GAIN"
                    android:textColor="#94A3B8"
                    android:textSize="11sp" />

                <TextView
                    android:id="@+id/tvElevation"
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="+0m"
                    android:textColor="#FFFFFF"
                    android:textSize="18sp"
                    android:textStyle="bold" />
            </LinearLayout>

        </LinearLayout>

    </LinearLayout>

    <!-- Bottom Controls -->
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

cat << 'EOF' > app/src/main/res/layout/activity_offline_map.xml
<?xml version="1.0" encoding="utf-8"?>
<RelativeLayout xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:mapbox="http://schemas.android.com/apk/res-auto"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="#0F172A">

    <org.maplibre.gl.maps.MapView
        android:id="@+id/offlineMapView"
        android:layout_width="match_parent"
        android:layout_height="match_parent"
        mapbox:mapbox_cameraZoom="12" />

    <!-- Center Region Bounding Box Overlay -->
    <View
        android:layout_width="260dp"
        android:layout_height="260dp"
        android:layout_centerInParent="true"
        android:background="#1A0284C7"
        android:foreground="@drawable/card_background" />

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
            android:text="Download Offline City Region"
            android:textColor="#FFFFFF"
            android:textSize="18sp"
            android:textStyle="bold" />

        <TextView
            android:id="@+id/tvDownloadStatus"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_marginTop="4dp"
            android:text="Pan/zoom map to position your target city area inside the central bounding box."
            android:textColor="#94A3B8"
            android:textSize="13sp" />

        <ProgressBar
            android:id="@+id/downloadProgress"
            style="?android:attr/progressBarStyleHorizontal"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="12dp"
            android:visibility="gone" />

        <Button
            android:id="@+id/btnDownloadRegion"
            android:layout_width="match_parent"
            android:layout_height="50dp"
            android:layout_marginTop="16dp"
            android:backgroundTint="#0284C7"
            android:text="Download Region Tiles"
            android:textColor="#FFFFFF"
            android:textStyle="bold" />
    </LinearLayout>

</RelativeLayout>
EOF

# 10. UI Activities
cat << 'EOF' > app/src/main/java/com/example/runningtracker/ui/OfflineMapActivity.kt
package com.example.runningtracker.ui

import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.example.runningtracker.R
import org.maplibre.gl.MapLibre
import org.maplibre.gl.maps.MapView
import org.maplibre.gl.maps.MapLibreMap
import org.maplibre.gl.maps.Style
import org.maplibre.gl.offline.OfflineManager
import org.maplibre.gl.offline.OfflineRegion
import org.maplibre.gl.offline.OfflineRegionObserver
import org.maplibre.gl.offline.OfflineRegionStatus
import org.maplibre.gl.offline.OfflineTilePyramidRegionDefinition

class OfflineMapActivity : AppCompatActivity() {

    private lateinit var mapView: MapView
    private var mapLibreMap: MapLibreMap? = null
    private lateinit var btnDownload: Button
    private lateinit var progressDownload: ProgressBar
    private lateinit var tvStatus: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MapLibre.getInstance(this)
        setContentView(R.layout.activity_offline_map)

        btnDownload = findViewById(R.id.btnDownloadRegion)
        progressDownload = findViewById(R.id.downloadProgress)
        tvStatus = findViewById(R.id.tvDownloadStatus)

        mapView = findViewById(R.id.offlineMapView)
        mapView.onCreate(savedInstanceState)

        mapView.getMapAsync { map ->
            mapLibreMap = map
            map.setStyle(Style.Builder().fromUri("https://tiles.openfreemap.org/styles/bright"))
        }

        btnDownload.setOnClickListener {
            downloadVisibleRegion()
        }
    }

    private fun downloadVisibleRegion() {
        val map = mapLibreMap ?: return
        val bounds = map.projection.visibleRegion.latLngBounds
        val minZoom = map.cameraPosition.zoom
        val maxZoom = 16.0
        val pixelRatio = resources.displayMetrics.density
        val styleUrl = "https://tiles.openfreemap.org/styles/bright"

        val definition = OfflineTilePyramidRegionDefinition(
            styleUrl,
            bounds,
            minZoom,
            maxZoom,
            pixelRatio
        )

        val metadata = "Offline City Map".toByteArray(Charsets.UTF_8)

        btnDownload.isEnabled = false
        progressDownload.visibility = View.VISIBLE
        tvStatus.text = "Downloading offline vector tiles..."

        val offlineManager = OfflineManager.getInstance(this)
        offlineManager.createOfflineRegion(definition, metadata, object : OfflineManager.CreateOfflineRegionCallback {
            override fun onCreate(offlineRegion: OfflineRegion) {
                offlineRegion.setObserver(object : OfflineRegionObserver {
                    override fun onStatusChanged(status: OfflineRegionStatus) {
                        val percentage = if (status.requiredResourceCount > 0) {
                            (100.0 * status.completedResourceCount / status.requiredResourceCount).toInt()
                        } else 0

                        runOnUiThread {
                            progressDownload.progress = percentage
                            tvStatus.text = "Downloading: $percentage%"
                        }

                        if (status.isComplete) {
                            runOnUiThread {
                                progressDownload.visibility = View.GONE
                                btnDownload.isEnabled = true
                                tvStatus.text = "Region downloaded successfully!"
                                Toast.makeText(this@OfflineMapActivity, "Offline Map Saved!", Toast.LENGTH_SHORT).show()
                            }
                        }
                    }

                    override fun onError(error: org.maplibre.gl.offline.OfflineRegionError) {
                        runOnUiThread {
                            btnDownload.isEnabled = true
                            tvStatus.text = "Download error: ${error.message}"
                        }
                    }

                    override fun mapboxTileCountLimitExceeded(limit: Long) {
                        runOnUiThread {
                            tvStatus.text = "Tile limit exceeded ($limit). Zoom in further."
                        }
                    }
                })

                offlineRegion.setDownloadState(OfflineRegion.STATE_ACTIVE)
            }

            override fun onError(error: String) {
                runOnUiThread {
                    btnDownload.isEnabled = true
                    tvStatus.text = "Error: $error"
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
import org.maplibre.gl.MapLibre
import org.maplibre.gl.camera.CameraUpdateFactory
import org.maplibre.gl.geometry.LatLng
import org.maplibre.gl.maps.MapView
import org.maplibre.gl.maps.MapLibreMap
import org.maplibre.gl.maps.Style
import org.maplibre.gl.style.layers.LineLayer
import org.maplibre.gl.style.layers.Property
import org.maplibre.gl.style.layers.PropertyFactory
import org.maplibre.gl.style.sources.GeoJsonSource
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
    private lateinit var tvElevation: TextView

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
        tvElevation = findViewById(R.id.tvElevation)

        btnWarmUp = findViewById(R.id.btnWarmUp)
        btnStart = findViewById(R.id.btnStart)
        btnStop = findViewById(R.id.btnStop)
        btnRecenter = findViewById(R.id.btnRecenter)
        btnOfflineMaps = findViewById(R.id.btnOfflineMaps)

        mapView = findViewById(R.id.mapView)
        mapView.onCreate(savedInstanceState)

        mapView.getMapAsync { map ->
            mapLibreMap = map
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
            trackingService?.currentLocation?.value?.let { loc ->
                mapLibreMap?.animateCamera(CameraUpdateFactory.newLatLngZoom(LatLng(loc.latitude, loc.longitude), 16.0))
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
    }

    private fun updatePolyline() {
        routeSource?.setGeoJson(Feature.fromGeometry(LineString.fromLngLats(routePoints)))
    }

    private fun startAndBindService() {
        val intent = Intent(this, TrackingService::class.java)
        startService(intent)
        bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
        trackingService?.startWarmUp()
    }

    private fun observeService() {
        val service = trackingService ?: return

        lifecycleScope.launch {
            service.trackingState.collectLatest { state ->
                tvStatus.text = "STATUS: ${state.name}"
                btnStart.isEnabled = (state == TrackingState.ACQUIRING_SIGNAL && service.currentAccuracy.value < 10.0f) || state == TrackingState.RUNNING || state == TrackingState.PAUSED
                btnStart.text = if (state == TrackingState.RUNNING) "Pause Run" else "Start Run"
                btnStop.isEnabled = state == TrackingState.RUNNING || state == TrackingState.PAUSED
            }
        }

        lifecycleScope.launch {
            service.currentAccuracy.collectLatest { accuracy ->
                tvAccuracy.text = String.format("GPS: %.1fm", accuracy)
                if (service.trackingState.value == TrackingState.ACQUIRING_SIGNAL) {
                    btnStart.isEnabled = accuracy < 10.0f
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
            service.currentElevation.collectLatest { elev ->
                tvElevation.text = String.format("%+.0fm", elev)
            }
        }

        lifecycleScope.launch {
            service.currentLocation.collectLatest { loc ->
                loc?.let {
                    val point = Point.fromLngLat(it.longitude, it.latitude)
                    routePoints.add(point)
                    updatePolyline()
                    mapLibreMap?.animateCamera(CameraUpdateFactory.newLatLng(LatLng(it.latitude, it.longitude)))
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

# 11. Update AndroidManifest.xml
cat << 'EOF' > app/src/main/AndroidManifest.xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.INTERNET" />

    <application
        android:allowBackup="true"
        android:label="@string/app_name"
        android:supportsRtl="true"
        android:theme="@style/Theme.AppCompat.Light.NoActionBar">

        <activity
            android:name=".ui.MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <activity
            android:name=".ui.OfflineMapActivity"
            android:exported="false"
            android:label="Offline Map Downloader" />

        <service
            android:name=".service.TrackingService"
            android:foregroundServiceType="location"
            android:exported="false" />

    </application>

</manifest>
EOF

echo "Full UI modernization & Offline Map Downloader integrated successfully!"
