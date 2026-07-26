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
