#!/bin/bash

echo "Applying Dual-Download, Satellite Zoom Fix, and Clear Box UI..."

# 1. Update MainActivity to fix the Satellite JSON maxzoom bug
cat << 'EOF' > app/src/main/java/com/example/runningtracker/ui/MainActivity.kt
package com.example.runningtracker.ui

import android.Manifest
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.example.runningtracker.R
import com.example.runningtracker.service.LocationDiagnostics
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
import java.io.File

class MainActivity : AppCompatActivity() {

    private var trackingService: TrackingService? = null
    private var isBound = false

    private lateinit var mapView: MapView
    private var mapLibreMap: MapLibreMap? = null
    private var routeSource: GeoJsonSource? = null
    private val routePoints = mutableListOf<Point>()

    private lateinit var btnGpsAccuracy: TextView
    private lateinit var tvDistance: TextView
    private lateinit var tvTime: TextView
    private lateinit var tvPace: TextView
    private lateinit var tvCadence: TextView
    
    private var infoDialog: AlertDialog? = null
    private var tvDialogContent: TextView? = null

    private lateinit var btnWarmUp: Button
    private lateinit var btnStart: Button
    private lateinit var btnStop: Button
    private lateinit var btnRecenter: FloatingActionButton
    private lateinit var btnMapOptions: FloatingActionButton
    
    private var currentStyleUrl: String = STREET_STYLE

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

        btnGpsAccuracy = findViewById(R.id.btnGpsAccuracy)
        tvDistance = findViewById(R.id.tvDistance)
        tvTime = findViewById(R.id.tvTime)
        tvPace = findViewById(R.id.tvPace)
        tvCadence = findViewById(R.id.tvCadence)

        btnWarmUp = findViewById(R.id.btnWarmUp)
        btnStart = findViewById(R.id.btnStart)
        btnStop = findViewById(R.id.btnStop)
        btnRecenter = findViewById(R.id.btnRecenter)
        btnMapOptions = findViewById(R.id.btnMapOptions)

        mapView = findViewById(R.id.mapView)
        mapView.onCreate(savedInstanceState)

        mapView.getMapAsync { map ->
            mapLibreMap = map
            map.cameraPosition = CameraPosition.Builder().zoom(16.0).build()
            changeMapStyle(currentStyleUrl)
        }

        btnWarmUp.setOnClickListener { checkPermissionsAndRun { startAndBindService() } }

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
            
            btnGpsAccuracy.backgroundTintList = ColorStateList.valueOf(Color.parseColor(COLOR_RED))
            btnGpsAccuracy.text = "--m"
        }

        btnRecenter.setOnClickListener {
            val map = mapLibreMap ?: return@setOnClickListener
            val loc = trackingService?.currentLocation?.value ?: map.locationComponent.lastKnownLocation
            if (loc != null) {
                map.animateCamera(CameraUpdateFactory.newLatLngZoom(LatLng(loc.latitude, loc.longitude), 16.5), 1000)
                map.locationComponent.cameraMode = CameraMode.TRACKING
            }
        }

        btnMapOptions.setOnClickListener { showMapOptionsDialog() }
        
        btnGpsAccuracy.setOnClickListener { openDiagnosticDialog() }
        btnGpsAccuracy.backgroundTintList = ColorStateList.valueOf(Color.parseColor(COLOR_RED))
    }
    
    private fun showMapOptionsDialog() {
        val options = arrayOf("🗺️ Street Map", "🛰️ Satellite Map", "⬇️ Download Offline Region")
        AlertDialog.Builder(this)
            .setTitle("Map Options")
            .setItems(options) { _, which ->
                when (which) {
                    0 -> changeMapStyle(STREET_STYLE)
                    1 -> changeMapStyle(getSatelliteStyleUrl(this))
                    2 -> launchOfflineMapActivity()
                }
            }
            .show()
    }
    
    private fun changeMapStyle(url: String) {
        currentStyleUrl = url
        mapLibreMap?.setStyle(Style.Builder().fromUri(url)) { style ->
            setupRouteLayer(style)
        }
    }
    
    private fun launchOfflineMapActivity() {
        val intent = Intent(this, OfflineMapActivity::class.java)
        mapLibreMap?.cameraPosition?.let {
            intent.putExtra("LAT", it.target?.latitude ?: 0.0)
            intent.putExtra("LNG", it.target?.longitude ?: 0.0)
            intent.putExtra("ZOOM", it.zoom)
        }
        intent.putExtra("STYLE_URL", currentStyleUrl)
        startActivity(intent)
    }
    
    private fun openDiagnosticDialog() {
        val builder = AlertDialog.Builder(this)
        builder.setTitle("GNSS & Hardware Diagnostics")
        
        val tv = TextView(this)
        tv.setPadding(50, 40, 50, 40)
        tv.setTextColor(Color.parseColor("#333333"))
        tv.textSize = 15f
        tvDialogContent = tv
        
        builder.setView(tv)
        builder.setPositiveButton("Close", null)
        builder.setNeutralButton("Copy") { _, _ ->
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newPlainText("GNSS Stats", tv.text)
            clipboard.setPrimaryClip(clip)
            Toast.makeText(this, "Copied to clipboard", Toast.LENGTH_SHORT).show()
        }
        
        infoDialog = builder.create()
        infoDialog?.setOnDismissListener {
            infoDialog = null
            tvDialogContent = null
        }
        infoDialog?.show()
        
        updateDialogContent(trackingService?.diagnostics?.value)
    }
    
    private fun updateDialogContent(diag: LocationDiagnostics?) {
        if (diag == null) return
        val text = """
            Location Engine: Google Fused Location API
            Hardware Model: ${diag.hardwareModel}
            Active Provider Stream: ${diag.activeProvider.uppercase()}
            System Enabled Providers: ${diag.availableProviders}
            
            Satellites Visible: ${diag.satellitesVisible}
            Satellites Used: ${diag.satellitesUsed}
            Dual-Frequency (L5): ${if (diag.isDualFrequencySupported) "Supported & Detected" else "Not Detected / Single-Freq"}
        """.trimIndent()
        tvDialogContent?.text = text
    }

    private fun setupRouteLayer(style: Style) {
        if (style.getSource("route-source") == null) {
            routeSource = GeoJsonSource("route-source", Feature.fromGeometry(LineString.fromLngLats(routePoints)))
            style.addSource(routeSource!!)
        } else {
            routeSource = style.getSourceAs("route-source")
            updatePolyline()
        }

        if (style.getLayer("route-layer") == null) {
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

    private fun updatePolyline() { routeSource?.setGeoJson(Feature.fromGeometry(LineString.fromLngLats(routePoints))) }

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
                btnStart.isEnabled = (state == TrackingState.ACQUIRING_SIGNAL && service.currentAccuracy.value <= 30.0f) || state == TrackingState.RUNNING || state == TrackingState.PAUSED
                btnStart.text = if (state == TrackingState.RUNNING) "Pause Run" else "Start Run"
                btnStop.isEnabled = state == TrackingState.RUNNING || state == TrackingState.PAUSED
                
                val statusColor = if (state == TrackingState.IDLE || state == TrackingState.STOPPED) COLOR_RED else COLOR_GREEN
                btnGpsAccuracy.backgroundTintList = ColorStateList.valueOf(Color.parseColor(statusColor))
            }
        }

        lifecycleScope.launch {
            service.currentAccuracy.collectLatest { accuracy ->
                btnGpsAccuracy.text = "${accuracy.toInt()}m"
                if (service.trackingState.value == TrackingState.ACQUIRING_SIGNAL) {
                    btnStart.isEnabled = accuracy <= 30.0f
                }
            }
        }
        
        lifecycleScope.launch {
            service.diagnostics.collectLatest { diag -> updateDialogContent(diag) }
        }

        lifecycleScope.launch { service.totalDistanceMeters.collectLatest { tvDistance.text = String.format("%.2f km", it / 1000.0) } }
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
                tvPace.text = if (secPerKm <= 0.0 || secPerKm > 3600.0) "--:--" else String.format("%d:%02d", (secPerKm / 60).toInt(), (secPerKm % 60).toInt())
            }
        }
        lifecycleScope.launch { service.currentCadence.collectLatest { tvCadence.text = "$it spm" } }
        lifecycleScope.launch {
            service.currentLocation.collectLatest { loc ->
                loc?.let {
                    if (service.trackingState.value == TrackingState.RUNNING) {
                        routePoints.add(Point.fromLngLat(it.longitude, it.latitude))
                        updatePolyline()
                    }
                }
            }
        }
    }

    private fun checkPermissionsAndRun(onGranted: () -> Unit) {
        val permissions = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        if (permissions.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }.isEmpty()) onGranted() 
        else permissionLauncher.launch(permissions.toTypedArray())
    }

    override fun onStart() { super.onStart(); mapView.onStart() }
    override fun onResume() { super.onResume(); mapView.onResume() }
    override fun onPause() { super.onPause(); mapView.onPause() }
    override fun onStop() { super.onStop(); mapView.onStop() }
    override fun onLowMemory() { super.onLowMemory(); mapView.onLowMemory() }
    override fun onDestroy() {
        super.onDestroy()
        mapView.onDestroy()
        if (isBound) { unbindService(serviceConnection); isBound = false }
    }
    override fun onSaveInstanceState(outState: Bundle) { super.onSaveInstanceState(outState); mapView.onSaveInstanceState(outState) }

    companion object {
        const val STREET_STYLE = "https://tiles.openfreemap.org/styles/bright"
        const val COLOR_RED = "#DC2626"
        const val COLOR_GREEN = "#16A34A"

        fun getSatelliteStyleUrl(context: Context): String {
            val file = File(context.cacheDir, "satellite_style.json")
            if (!file.exists()) {
                // FIX: Added "maxzoom": 18 to the esri-satellite source so it stops requesting dead tiles
                file.writeText("""
                    {
                      "version": 8,
                      "sources": {
                        "esri-satellite": {
                          "type": "raster",
                          "tiles": ["https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"],
                          "tileSize": 256,
                          "maxzoom": 18
                        }
                      },
                      "layers": [{
                        "id": "satellite-layer",
                        "type": "raster",
                        "source": "esri-satellite",
                        "minzoom": 0,
                        "maxzoom": 22
                      }]
                    }
                """.trimIndent())
            }
            return "file://${file.absolutePath}"
        }
    }
}
EOF

echo "Updated MainActivity.kt (Maxzoom fix applied)"

# 2. Update OfflineMapActivity to handle queued dual-downloads and the Clear Box UI
cat << 'EOF' > app/src/main/java/com/example/runningtracker/ui/OfflineMapActivity.kt
package com.example.runningtracker.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.ColorStateList
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
import androidx.core.content.ContextCompat
import com.example.runningtracker.R
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.location.LocationComponentActivationOptions
import org.maplibre.android.location.modes.RenderMode
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
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
    private var passedStyleUrl: String = ""
    
    // Queue to hold the map styles we want to download
    private val downloadQueue = mutableListOf<String>()

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
        
        passedStyleUrl = intent.getStringExtra("STYLE_URL") ?: MainActivity.STREET_STYLE

        selectionView = SelectionView(this)
        val mapParent = mapView.parent as ViewGroup
        val index = mapParent.indexOfChild(mapView)
        mapParent.addView(selectionView, index + 1, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        mapView.getMapAsync { map ->
            mapLibreMap = map
            val lat = intent.getDoubleExtra("LAT", 0.0)
            val lng = intent.getDoubleExtra("LNG", 0.0)
            val zoom = intent.getDoubleExtra("ZOOM", 12.0)
            val cameraBuilder = CameraPosition.Builder().zoom(zoom)
            if (lat != 0.0 || lng != 0.0) cameraBuilder.target(LatLng(lat, lng))
            map.cameraPosition = cameraBuilder.build()
            
            map.setStyle(Style.Builder().fromUri(passedStyleUrl)) { style ->
                enableLocationComponent(style)
            }
        }

        btnDrawMode.setOnClickListener {
            if (btnDrawMode.text == "Draw Box") {
                isDrawingMode = true
                btnDrawMode.text = "Cancel"
                btnDrawMode.backgroundTintList = ColorStateList.valueOf(Color.parseColor("#DC2626")) // Red
                tvStatus.text = "Drag your finger to draw a box."
                selectionView.startX = -1f
                selectionView.endX = -1f
                selectionView.invalidate()
                btnDownload.isEnabled = false
            } else {
                resetDrawMode()
            }
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
                    // Check if they actually drew a box, not just a tap
                    if (Math.abs(selectionView.startX - selectionView.endX) > 20) {
                        isDrawingMode = false // Release the map back to the user so they can pan!
                        btnDrawMode.text = "Clear Box"
                        btnDrawMode.backgroundTintList = ColorStateList.valueOf(Color.parseColor("#F59E0B")) // Amber
                        
                        val map = mapLibreMap
                        if (map != null) {
                            val pt1 = map.projection.fromScreenLocation(PointF(selectionView.startX, selectionView.startY))
                            val pt2 = map.projection.fromScreenLocation(PointF(selectionView.endX, selectionView.endY))
                            selectionBounds = LatLngBounds.Builder().include(pt1).include(pt2).build()
                            tvStatus.text = "Region mapped! Press Download to save both maps."
                            btnDownload.isEnabled = true
                        }
                    } else {
                        resetDrawMode()
                    }
                }
            }
            true
        }

        btnDownload.setOnClickListener { startDualDownload() }
    }
    
    private fun resetDrawMode() {
        isDrawingMode = false
        selectionBounds = null
        selectionView.startX = -1f
        selectionView.endX = -1f
        selectionView.invalidate()
        btnDrawMode.text = "Draw Box"
        btnDrawMode.backgroundTintList = ColorStateList.valueOf(Color.parseColor("#475569")) // Gray
        btnDownload.isEnabled = false
        tvStatus.text = "Tap 'Draw Box' then drag your finger on the map."
    }

    private fun startDualDownload() {
        val map = mapLibreMap ?: return
        val bounds = selectionBounds ?: return
        
        btnDownload.isEnabled = false
        btnDrawMode.isEnabled = false
        progressDownload.visibility = View.VISIBLE
        
        val minZoom = map.cameraPosition.zoom.coerceAtMost(12.0)
        val maxZoom = 16.0
        val pixelRatio = resources.displayMetrics.density

        // Queue both the street map and the satellite map
        downloadQueue.clear()
        downloadQueue.add(MainActivity.STREET_STYLE)
        downloadQueue.add(MainActivity.getSatelliteStyleUrl(this))
        
        downloadNextInQueue(minZoom, maxZoom, pixelRatio, bounds)
    }

    private fun downloadNextInQueue(minZoom: Double, maxZoom: Double, pixelRatio: Float, bounds: LatLngBounds) {
        if (downloadQueue.isEmpty()) {
            runOnUiThread {
                progressDownload.visibility = View.GONE
                tvStatus.text = "Both maps saved successfully!"
                Toast.makeText(this@OfflineMapActivity, "Saved for Offline", Toast.LENGTH_LONG).show()
                resetDrawMode()
                btnDrawMode.isEnabled = true
            }
            return
        }

        val currentStyle = downloadQueue.removeAt(0)
        val mapTypeName = if(currentStyle.contains("satellite")) "Satellite" else "Street"
        
        val definition = OfflineTilePyramidRegionDefinition(
            currentStyle, bounds, minZoom, maxZoom, pixelRatio
        )

        val metadata = "$mapTypeName Region".toByteArray(Charsets.UTF_8)
        tvStatus.text = "Downloading $mapTypeName..."

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
                            tvStatus.text = "Downloading $mapTypeName: $percentage%"
                        }

                        if (status.isComplete) {
                            // When one map finishes, move on to the next map in the queue!
                            runOnUiThread {
                                downloadNextInQueue(minZoom, maxZoom, pixelRatio, bounds)
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
}
EOF

echo "Updated OfflineMapActivity.kt (Dual Download & Clear Box UI applied)"
