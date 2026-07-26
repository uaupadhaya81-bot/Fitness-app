#!/bin/bash

echo "Starting AI Patch Script..."

# 1. Update outdated "GPS" terminology to "LOC" / "Location"
sed -i 's/android:text="GPS: --m"/android:text="LOC: --m"/g' app/src/main/res/layout/activity_main.xml
sed -i 's/android:text="Acquire GPS Warmup"/android:text="Acquire Location Warmup"/g' app/src/main/res/layout/activity_main.xml
sed -i 's/String.format("GPS: %.1fm"/String.format("LOC: %.1fm"/g' app/src/main/java/com/example/runningtracker/ui/MainActivity.kt
sed -i 's/"Acquiring GPS Signal..."/"Acquiring Location Signal..."/g' app/src/main/java/com/example/runningtracker/service/TrackingService.kt

# 2. Modify MainActivity to extract map state and pass it to OfflineMapActivity
perl -0777 -pi -e 's/btnOfflineMaps.setOnClickListener \{ startActivity\(Intent\(this, OfflineMapActivity::class.java\)\) \}/btnOfflineMaps.setOnClickListener \{\n            val intent = Intent(this, OfflineMapActivity::class.java)\n            mapLibreMap?.cameraPosition?.let \{\n                intent.putExtra("LAT", it.target.latitude)\n                intent.putExtra("LNG", it.target.longitude)\n                intent.putExtra("ZOOM", it.zoom)\n            \}\n            startActivity(intent)\n        \}/g' app/src/main/java/com/example/runningtracker/ui/MainActivity.kt

# 3. Enhance Recenter button to smoothly animate and set proper zoom (16.5) and tracking mode
perl -0777 -pi -e 's/btnRecenter.setOnClickListener \{\s*val map = mapLibreMap \?\: return\@setOnClickListener\s*val loc = trackingService\?\.currentLocation\?\.value \?\: map.locationComponent.lastKnownLocation\s*if \(loc \!\= null\) \{\s*map.animateCamera\(CameraUpdateFactory.newLatLngZoom\(LatLng\(loc.latitude, loc.longitude\), 16\.0\)\)\s*map.locationComponent.cameraMode = CameraMode.TRACKING\s*\}\s*\}/btnRecenter.setOnClickListener \{\n            val map = mapLibreMap ?: return\@setOnClickListener\n            val loc = trackingService?.currentLocation?.value ?: map.locationComponent.lastKnownLocation\n            if (loc != null) {\n                map.animateCamera(CameraUpdateFactory.newLatLngZoom(LatLng(loc.latitude, loc.longitude), 16.5), 1000)\n                map.locationComponent.cameraMode = CameraMode.TRACKING\n            }\n        \}/g' app/src/main/java/com/example/runningtracker/ui/MainActivity.kt

# 4. Add required MapLibre LocationComponent imports to OfflineMapActivity
perl -pi -e 's/(import org.maplibre.android.offline.OfflineTilePyramidRegionDefinition)/$1\nimport org.maplibre.android.geometry.LatLng\nimport android.Manifest\nimport android.content.pm.PackageManager\nimport androidx.core.content.ContextCompat\nimport org.maplibre.android.location.LocationComponentActivationOptions\nimport org.maplibre.android.location.modes.RenderMode/g' app/src/main/java/com/example/runningtracker/ui/OfflineMapActivity.kt

# 5. Consume Intent extras and set up the map style callback to enable the blue dot in OfflineMapActivity
perl -0777 -pi -e 's/map.cameraPosition = CameraPosition.Builder\(\).zoom\(12.0\).build\(\)\n\s*map.setStyle\(Style.Builder\(\).fromUri\("https:\/\/tiles.openfreemap.org\/styles\/bright"\)\)/val lat = intent.getDoubleExtra("LAT", 0.0)\n            val lng = intent.getDoubleExtra("LNG", 0.0)\n            val zoom = intent.getDoubleExtra("ZOOM", 12.0)\n            val cameraBuilder = CameraPosition.Builder().zoom(zoom)\n            if (lat != 0.0 || lng != 0.0) cameraBuilder.target(LatLng(lat, lng))\n            map.cameraPosition = cameraBuilder.build()\n            map.setStyle(Style.Builder().fromUri("https:\/\/tiles.openfreemap.org\/styles\/bright")) { style ->\n                enableLocationComponent(style)\n            }/g' app/src/main/java/com/example/runningtracker/ui/OfflineMapActivity.kt

# 6. Inject the enableLocationComponent function safely at the bottom of the OfflineMapActivity class
sed -i '$ d' app/src/main/java/com/example/runningtracker/ui/OfflineMapActivity.kt

cat << 'APPENDEOF' >> app/src/main/java/com/example/runningtracker/ui/OfflineMapActivity.kt

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
APPENDEOF

echo "Patch complete: GPS terms updated, offline map synced with position/blue dot, and recenter zoom optimized."
