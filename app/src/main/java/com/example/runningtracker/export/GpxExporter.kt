package com.example.runningtracker.export

import com.example.runningtracker.data.model.RunEntity
import com.example.runningtracker.data.model.TrackPointEntity
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

object GpxExporter {

    fun generateGpx(run: RunEntity, points: List<TrackPointEntity>): String {
        val isoFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }

        val sb = StringBuilder()
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        sb.append("<gpx version=\"1.1\" creator=\"RunningTrackerApp\"\n")
        sb.append("  xmlns=\"http://www.topografix.com/GPX/1/1\">\n")
        sb.append("  <metadata>\n")
        sb.append("    <time>").append(isoFormat.format(Date(run.startTimeStamp))).append("</time>\n")
        sb.append("  </metadata>\n")
        sb.append("  <trk>\n")
        sb.append("    <name>Run ").append(run.id).append("</name>\n")
        sb.append("    <trkseg>\n")

        for (pt in points) {
            sb.append("      <trkpt lat=\"").append(pt.latitude)
                .append("\" lon=\"").append(pt.longitude).append("\">\n")
            sb.append("        <ele>").append(pt.altitude).append("</ele>\n")
            sb.append("        <time>").append(isoFormat.format(Date(pt.timestamp))).append("</time>\n")
            sb.append("      </trkpt>\n")
        }

        sb.append("    </trkseg>\n")
        sb.append("  </trk>\n")
        sb.append("</gpx>")

        return sb.toString()
    }
}
