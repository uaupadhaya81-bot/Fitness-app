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
