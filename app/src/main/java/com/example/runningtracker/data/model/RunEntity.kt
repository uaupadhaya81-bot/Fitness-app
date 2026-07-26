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
