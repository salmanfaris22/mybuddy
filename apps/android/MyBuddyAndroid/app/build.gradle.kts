import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "app.mybuddy.android"
    compileSdk = 37

    defaultConfig {
        applicationId = "app.mybuddy.android"
        minSdk = 31
        // Stays at 36 until the ACCESS_LOCAL_NETWORK runtime flow (required when targeting 37) is built and
        // tested; apps targeting < 37 keep LAN access on Android 17.
        // https://developer.android.com/privacy-and-security/local-network-permission
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        // The Vivo X300 and Android emulators on Apple silicon are arm64; shipping only that ABI keeps
        // libwebrtc's other native builds (~33 MB) out of the APK.
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    // Release signing comes from a properties file OUTSIDE the repository, named by MYBUDDY_KEYSTORE_PROPERTIES
    // (storeFile, storePassword, keyAlias, keyPassword). Without it, assembleRelease builds an unsigned APK.
    // Never commit keystores or passwords (docs/RELEASE.md).
    val signingProps = System.getenv("MYBUDDY_KEYSTORE_PROPERTIES")?.let { file(it) }?.takeIf { it.isFile }?.let { f ->
        Properties().apply { f.inputStream().use(::load) }
    }
    signingConfigs {
        if (signingProps != null) {
            create("release") {
                storeFile = file(signingProps.getProperty("storeFile"))
                storePassword = signingProps.getProperty("storePassword")
                keyAlias = signingProps.getProperty("keyAlias")
                keyPassword = signingProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    lint {
        // ChromeOS (x86_64) is not a target device; the app ships arm64 only (see abiFilters above).
        disable += "ChromeOsAbiSupport"
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.zxing.core)
    implementation(libs.webrtc.android)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
