package com.example.runningtracker.data.filter

import android.location.Location
import java.util.LinkedList

class WeightedMovingAverageFilter(private val windowSize: Int = 2) {

    private val window: LinkedList<Location> = LinkedList()

    fun filter(location: Location): Location? {
        if (location.accuracy > 50.0f) {
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
