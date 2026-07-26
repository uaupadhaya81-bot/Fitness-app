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
