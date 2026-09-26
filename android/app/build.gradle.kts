plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

fun getKeystoreProp(key: String, default: String = ""): String {
    val file = rootProject.file("key.properties")
    if (!file.exists()) return default
    var result = default
    file.forEachLine { line ->
        val parts = line.split("=", limit = 2)
        if (parts.size == 2 && parts[0].trim() == key) {
            result = parts[1].trim()
        }
    }
    return result
}

android {
    namespace = "com.matech.medisense"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.matech.medisense"
        // Keep the existing Android 8.0+ deployment baseline.
        // Keep API 26+ for the on-device OCR/runtime dependencies.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // Keep the baseline ML Kit scanner available on older ARMv7
            // phones as well as arm64-v8a devices.
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    packaging {
        jniLibs {
            // x86 is not a supported deployment target for this app.
            excludes += setOf(
                "lib/x86/**",
                "lib/x86_64/**",
            )
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = getKeystoreProp("keyAlias", "medisense")
            keyPassword = getKeystoreProp("keyPassword", "medisense2026")
            storeFile = file(getKeystoreProp("storeFile", "upload-keystore.jks"))
            storePassword = getKeystoreProp("storePassword", "medisense2026")
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                file("proguard-rules.pro")
            )
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
