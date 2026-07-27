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
