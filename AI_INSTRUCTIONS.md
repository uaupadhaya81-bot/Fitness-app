# High-Precision Offline Running Tracker Architecture

This repository contains a lightweight, 100% offline, high-precision Android running tracker application.

## Core Architectural Modules
1. **Data Layer (`data`)**: Room entities (`RunEntity`, `TrackPointEntity`), DAOs (`RunDao`, `TrackPointDao`), and database instance (`AppDatabase`).
2. **Signal Filtering (`data/filter`)**: `WeightedMovingAverageFilter` to filter raw satellite coordinates based on accuracy weights.
3. **Hardware Sensors (`sensor`)**: `CadenceDetector` for step peak detection (120-210 spm range) and `BarometerElevationTracker` for relative altitude tracking via barometric pressure.
4. **Foreground Tracking Service (`service`)**: `TrackingService` managing GPS sampling (1Hz), auto-pause detection (<0.5 m/s), CPU WakeLock, and foreground state notifications with API 34 compliance.
5. **Data Export (`export`)**: `GpxExporter` and `TcxExporter` to export recorded workouts.
6. **User Interface (`ui`)**: `MainActivity` providing live stats dashboard, GPS warm-up indicator, and tracking controls.
