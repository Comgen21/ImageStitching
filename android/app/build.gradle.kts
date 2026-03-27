import java.util.Properties

// ── Read local.properties ─────────────────────────────────────────────────────
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}

// Resolve OpenCV SDK path: prefer local.properties, fall back to a sibling dir
val opencvSdkPath: String =
    (localProperties.getProperty("opencv.sdk.path")
        ?: "${rootDir}/../OpenCV-android-sdk")
        .replace("\\", "/")  // normalise Windows back-slashes

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.simplr.shelf_monitor_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.simplr.shelf_monitor_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ── NDK ABI filter ──────────────────────────────────────────────────
        ndk {
            abiFilters += listOf("arm64-v8a")
        }

        // ── CMake / NDK build arguments ─────────────────────────────────────
        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17", "-frtti", "-fexceptions")
                arguments(
                    "-DOPENCV_SDK_PATH=$opencvSdkPath"
                )
            }
        }
    }

    // ── Point to the CMakeLists.txt ───────────────────────────────────────────
    externalNativeBuild {
        cmake {
            path = file("CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.exifinterface:exifinterface:1.3.7")
}
