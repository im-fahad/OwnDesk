plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.prc.controller"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.prc.controller"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.2.0-dev"
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main") { java.srcDirs("src/main/kotlin") }
        getByName("test") { java.srcDirs("src/test/kotlin") }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

// The unit tests run the protocol's shared vectors, so they need to find them.
tasks.withType<Test>().configureEach {
    systemProperty("prc.vectors", rootProject.file("../../packages/protocol/vectors").absolutePath)
    systemProperty("prc.frames.out", layout.buildDirectory.file("frames.json").get().asFile.absolutePath)
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // Camera preview and frame analysis for scanning the Mac's pairing code.
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")
    // Reads the QR itself, offline: no Play Services, nothing sent anywhere.
    implementation("com.google.zxing:core:3.5.3")
    // A maintained build of libwebrtc for Android; the Macs use the equivalent for Apple platforms.
    implementation("io.github.webrtc-sdk:android:125.6422.07")
    testImplementation("junit:junit:4.13.2")
    // android.jar's org.json is a stub that returns null; the real one lets the frame test run.
    testImplementation("org.json:json:20240303")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
}
