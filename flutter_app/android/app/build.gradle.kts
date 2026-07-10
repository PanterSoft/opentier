import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Reuse the original app's secrets.properties + JKS pattern. Falls back to the
// debug keystore when secrets are absent so `flutter build` works anywhere.
val signingProps = Properties().apply {
    val f = rootProject.file("secrets.properties")
    if (f.exists()) load(FileInputStream(f))
}

android {
    namespace = "com.andrerinas.opentier"
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
        applicationId = "com.andrerinas.opentier"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (signingProps.getProperty("KEYSTORE_PASSWORD") != null) {
                storeFile = rootProject.file("opentier-release-key.jks")
                keyAlias = "opentier"
                storePassword = signingProps.getProperty("KEYSTORE_PASSWORD")
                keyPassword = signingProps.getProperty("KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Use the release keystore when secrets.properties is present, else debug.
            signingConfig = if (signingProps.getProperty("KEYSTORE_PASSWORD") != null)
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
