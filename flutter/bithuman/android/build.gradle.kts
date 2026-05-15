group = "ai.bithuman.flutter"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        // mavenLocal first so dev iteration (e.g. SDK 1.16.0 unreleased)
        // resolves against ~/.m2 before falling through to Central.
        mavenLocal()
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "ai.bithuman.flutter"

    compileSdk = 35

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 29   // ai.bithuman:sdk requires android-29+
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

dependencies {
    implementation("ai.bithuman:sdk:1.16.0")

    // libwebrtc Java bindings (the same lib flutter_webrtc depends on).
    // We need `org.webrtc.AudioTrack` + `AudioTrackSink` at compile
    // time to attach a remote-audio tap → avatar lipsync. `compileOnly`
    // keeps it out of the runtime classpath of apps that don't already
    // pull libwebrtc — the bridge feature simply no-ops in those apps
    // (we resolve `FlutterWebRTCPlugin.sharedSingleton` reflectively).
    compileOnly("io.github.webrtc-sdk:android:144.7559.01")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
