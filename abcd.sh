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

    // Lifecycle & Activity KTX for Coroutine Flow collection & permission contracts
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.activity:activity-ktx:1.8.2")

    // Room Database for offline storage
    val roomVersion = "2.6.1"
    implementation("androidx.room:room-runtime:$roomVersion")
    implementation("androidx.room:room-ktx:$roomVersion")
    kapt("androidx.room:room-compiler:$roomVersion")

    // MapLibre for offline vector rendering
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
4. **Foreground Tracking Service (`service`)**: `TrackingService` managing GPS sampling (1Hz), auto-pause detection (<0.5 m/s), CPU WakeLock, and foreground state notifications with API 34 compliance.
5. **Data Export (`export`)**: `GpxExporter` and `TcxExporter` to export recorded workouts.
6. **User Interface (`ui`)**: `MainActivity` providing live stats dashboard, GPS warm-up indicator, and tracking controls.
EOF

cat << 'EOF' > AI_CHANGELOG.md
- Initialized modular running tracker baseline: Room entities & DAOs, WMA GPS filter, Cadence/Barometer trackers, Android 14 location foreground service, GPX/TCX exporters, and UI shell.
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

# 7. Tracking Service & State (With Android 14 Location Foreground Service Support)
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

# 9. UI Layout & Activity
cat << 'EOF' > app/src/main/res/drawable/ic_notification.xml
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
  <path
      android:fillColor="#FF000000"
      android:pathData="M12,2A10,10 0 1,0 22,12A10,10 0 0,0 12,2Z"/>
</vector>
EOF

cat << 'EOF' > app/src/main/res/layout/activity_main.xml
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:padding="16dp"
    android:gravity="center_horizontal">

    <TextView
        android:id="@+id/tvStatus"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="Status: Idle"
        android:textSize="18sp"
        android:textStyle="bold"
        android:layout_marginBottom="16dp" />

    <TextView
        android:id="@+id/tvAccuracy"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="GPS Accuracy: -- m"
        android:textSize="14sp"
        android:layout_marginBottom="8dp" />

    <TextView
        android:id="@+id/tvDistance"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="0.00 km"
        android:textSize="36sp"
        android:textStyle="bold"
        android:layout_marginBottom="24dp" />

    <Button
        android:id="@+id/btnWarmUp"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:text="Acquire GPS Warmup" />

    <Button
        android:id="@+id/btnStart"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:enabled="false"
        android:text="Start Run" />

    <Button
        android:id="@+id/btnStop"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:enabled="false"
        android:text="Stop Run" />

</LinearLayout>
EOF

cat << 'EOF' > app/src/main/java/com/example/runningtracker/ui/MainActivity.kt
package com.example.runningtracker.ui

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
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
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    private var trackingService: TrackingService? = null
    private var isBound = false

    private lateinit var tvStatus: TextView
    private lateinit var tvAccuracy: TextView
    private lateinit var tvDistance: TextView
    private lateinit var btnWarmUp: Button
    private lateinit var btnStart: Button
    private lateinit var btnStop: Button

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
        setContentView(R.layout.activity_main)

        tvStatus = findViewById(R.id.tvStatus)
        tvAccuracy = findViewById(R.id.tvAccuracy)
        tvDistance = findViewById(R.id.tvDistance)
        btnWarmUp = findViewById(R.id.btnWarmUp)
        btnStart = findViewById(R.id.btnStart)
        btnStop = findViewById(R.id.btnStop)

        btnWarmUp.setOnClickListener {
            checkPermissionsAndRun {
                startAndBindService()
            }
        }

        btnStart.setOnClickListener {
            trackingService?.startRun()
        }

        btnStop.setOnClickListener {
            trackingService?.stopRun()
            if (isBound) {
                unbindService(serviceConnection)
                isBound = false
            }
        }
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
                tvStatus.text = "Status: ${state.name}"
                btnStart.isEnabled = (state == TrackingState.ACQUIRING_SIGNAL && service.currentAccuracy.value < 10.0f) || state == TrackingState.PAUSED
                btnStop.isEnabled = state == TrackingState.RUNNING || state == TrackingState.PAUSED
            }
        }

        lifecycleScope.launch {
            service.currentAccuracy.collectLatest { accuracy ->
                tvAccuracy.text = String.format("GPS Accuracy: %.1fm", accuracy)
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

    override fun onDestroy() {
        super.onDestroy()
        if (isBound) {
            unbindService(serviceConnection)
            isBound = false
        }
    }
}
EOF

# 10. Update AndroidManifest.xml
cat << 'EOF' > app/src/main/AndroidManifest.xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

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

        <service
            android:name=".service.TrackingService"
            android:foregroundServiceType="location"
            android:exported="false" />

    </application>

</manifest>
EOF

echo "Modular architectural baseline created successfully!"
