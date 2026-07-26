#!/bin/bash

# 1. Create the necessary directory structure
mkdir -p app/src/main/java/com/example/runningtracker
mkdir -p app/src/main/res/layout
mkdir -p app/src/main/res/values

# 2. Create the root settings.gradle.kts
cat << 'EOF' > settings.gradle.kts
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "Running Tracker"
include(":app")
EOF

# 3. Create gradle.properties (CRITICAL FIX FOR ANDROIDX)
cat << 'EOF' > gradle.properties
android.useAndroidX=true
android.nonTransitiveRClass=true
EOF

# 4. Create the root build.gradle.kts (Updated Versions)
cat << 'EOF' > build.gradle.kts
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
EOF

# 5. Create the app-level build.gradle.kts
cat << 'EOF' > app/build.gradle.kts
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("kotlin-kapt")
}

android {
    namespace = "com.example.runningtracker"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.example.runningtracker"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")

    // Room Database for offline coordinate/metric storage
    val roomVersion = "2.6.1"
    implementation("androidx.room:room-runtime:$roomVersion")
    implementation("androidx.room:room-ktx:$roomVersion")
    kapt("androidx.room:room-compiler:$roomVersion")

    // MapLibre for offline vector map rendering
    implementation("org.maplibre.gl:android-sdk:10.2.0")
}
EOF

# 6. Create AndroidManifest.xml
cat << 'EOF' > app/src/main/AndroidManifest.xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />

    <application
        android:allowBackup="true"
        android:icon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:roundIcon="@mipmap/ic_launcher_round"
        android:supportsRtl="true"
        android:theme="@style/Theme.AppCompat.Light.NoActionBar">
        
    </application>

</manifest>
EOF

# 7. Create strings.xml
cat << 'EOF' > app/src/main/res/values/strings.xml
<resources>
    <string name="app_name">Running Tracker</string>
</resources>
EOF
