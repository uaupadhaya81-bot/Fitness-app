package com.example.runningtracker.ui

import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.example.runningtracker.R
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
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
            map.cameraPosition = CameraPosition.Builder().zoom(12.0).build()
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
                offlineRegion.setObserver(object : OfflineRegion.OfflineRegionObserver {
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

                    override fun onError(error: OfflineRegionError) {
                        runOnUiThread {
                            btnDownload.isEnabled = true
                            tvStatus.text = "Download error: ${error.reason}"
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
