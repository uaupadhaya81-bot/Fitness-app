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
