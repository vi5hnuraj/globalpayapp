import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.globalpay.app"
    compileSdk = flutter.compileSdkVersion
    // No NDK: every plugin here is Dart or Kotlin, and a declared ndkVersion makes AGP require one.

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.globalpay.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 24: androidx.biometric and biometric-bound keystore keys both need it.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // A release build is signed with the project's own keystore when android/keystore.properties
    // exists. Without it the debug key is used so local `--release` runs still work; that build must
    // never be published.
    val keystoreProperties = rootProject.file("keystore.properties")
    signingConfigs {
        if (keystoreProperties.exists()) {
            create("release") {
                val props = Properties()
                keystoreProperties.inputStream().use { props.load(it) }
                storeFile = rootProject.file(props.getProperty("storeFile"))
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreProperties.exists()) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("keystore.properties is missing: signing the release build with the debug key")
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // The fingerprint prompt that unlocks the keystore key.
    implementation("androidx.biometric:biometric:1.1.0")
}

flutter {
    source = "../.."
}
